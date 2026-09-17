package com.upeo.upeo_sms_gateway

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import androidx.core.app.NotificationCompat
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * The persistent foreground service that *is* the gateway.
 *
 * Responsibilities:
 *  - Run in the foreground with an ongoing notification so the OS keeps the
 *    process alive (Doze / aggressive OEM battery managers).
 *  - Host a long-lived Flutter background isolate (entrypoint `backgroundMain`)
 *    so that ALL persistence (encrypted DB), allowlist filtering, signing and
 *    HTTP sync stays in one Dart code path — no logic is duplicated in Kotlin.
 *  - Deliver incoming SMS to that isolate over the [SMS_CHANNEL] MethodChannel.
 *  - Publish a "last alive" heartbeat timestamp so the UI watchdog can tell the
 *    operator if the service was ever killed.
 *
 * Durability note: an incoming SMS is held in an in-memory queue only for the
 * brief window before the Dart isolate signals `backgroundReady` (a one-time
 * warm-up of ~1s after the service first starts). Once warm, delivery is
 * immediate and the Dart side persists to the encrypted DB before attempting to
 * send.
 */
class SmsForegroundService : Service() {

    private val mainHandler = Handler(Looper.getMainLooper())

    private var flutterEngine: FlutterEngine? = null
    private var methodChannel: MethodChannel? = null

    @Volatile private var backgroundReady = false
    private val pending = ArrayDeque<Map<String, Any?>>()

    // Periodic "I'm alive" ticker for the watchdog.
    private val aliveTicker = object : Runnable {
        override fun run() {
            writeAlive()
            mainHandler.postDelayed(this, ALIVE_INTERVAL_MS)
        }
    }

    override fun onCreate() {
        super.onCreate()
        isRunning = true
        createNotificationChannel()
        startForegroundSafely()
        startBackgroundEngine()
        mainHandler.post(aliveTicker)
        Log.i(TAG, "Foreground service created")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                Log.i(TAG, "Stop requested")
                stopForegroundCompat()
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_INCOMING_SMS -> handleIncoming(intent)
            else -> {
                // ACTION_START or a sticky restart: just keep running. Ask the
                // Dart side (once ready) to do an opportunistic sweep.
                requestSweep()
            }
        }
        // START_STICKY: the OS will recreate us after a low-memory kill.
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onTaskRemoved(rootIntent: Intent?) {
        // stopWithTask=false in the manifest already keeps us running when the
        // task is swiped away; log for diagnostics.
        Log.i(TAG, "Task removed — service continues running")
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        Log.w(TAG, "Foreground service destroyed")
        isRunning = false
        mainHandler.removeCallbacksAndMessages(null)
        methodChannel?.setMethodCallHandler(null)
        flutterEngine?.destroy()
        flutterEngine = null
        methodChannel = null
        super.onDestroy()
    }

    // ----------------------------------------------------------------- engine

    private fun startBackgroundEngine() {
        if (flutterEngine != null) return
        try {
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(applicationContext)
            loader.ensureInitializationComplete(applicationContext, null)

            val engine = FlutterEngine(applicationContext)
            val entrypoint = DartExecutor.DartEntrypoint(
                loader.findAppBundlePath(),
                BACKGROUND_ENTRYPOINT,
            )
            engine.dartExecutor.executeDartEntrypoint(entrypoint)

            // Make pub plugins (sqflite, secure storage, dio's deps, …) available
            // to the background isolate.
            try {
                io.flutter.plugins.GeneratedPluginRegistrant.registerWith(engine)
            } catch (e: Throwable) {
                Log.e(TAG, "GeneratedPluginRegistrant failed", e)
            }

            val channel = MethodChannel(engine.dartExecutor.binaryMessenger, SMS_CHANNEL)
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "backgroundReady" -> {
                        backgroundReady = true
                        flushPending()
                        result.success(true)
                    }
                    "updateNotification" -> {
                        updateNotification(call.argument<String>("text"))
                        result.success(true)
                    }
                    "readInbox" -> {
                        val since = (call.argument<Number>("sinceMillis"))?.toLong() ?: 0L
                        val limit = (call.argument<Number>("limit"))?.toInt() ?: 200
                        result.success(SmsInbox.read(applicationContext, since, limit))
                    }
                    "stopService" -> {
                        result.success(true)
                        stopForegroundCompat()
                        stopSelf()
                    }
                    else -> result.notImplemented()
                }
            }
            methodChannel = channel
            flutterEngine = engine
            Log.i(TAG, "Background Flutter engine started")
        } catch (e: Throwable) {
            Log.e(TAG, "Failed to start background engine", e)
        }
    }

    // --------------------------------------------------------------- delivery

    private fun handleIncoming(intent: Intent) {
        val map = mapOf(
            "sender" to intent.getStringExtra(EXTRA_SENDER),
            "body" to intent.getStringExtra(EXTRA_BODY),
            "timestampMillis" to intent.getLongExtra(EXTRA_TS, 0L),
            "subscriptionId" to intent.getIntExtra(EXTRA_SUB_ID, -1),
            "simSlot" to intent.getIntExtra(EXTRA_SLOT, -1),
        )
        if (backgroundReady && methodChannel != null) {
            invokeOnMain("onSmsReceived", map)
        } else {
            synchronized(pending) { pending.add(map) }
            Log.i(TAG, "SMS queued (engine warming up); queue=${pending.size}")
        }
    }

    private fun flushPending() {
        val drained: List<Map<String, Any?>>
        synchronized(pending) {
            drained = pending.toList()
            pending.clear()
        }
        drained.forEach { invokeOnMain("onSmsReceived", it) }
        if (drained.isNotEmpty()) Log.i(TAG, "Flushed ${drained.size} queued SMS")
    }

    private fun requestSweep() {
        if (backgroundReady) invokeOnMain("onSweep", null)
    }

    private fun invokeOnMain(method: String, args: Any?) {
        mainHandler.post {
            try {
                methodChannel?.invokeMethod(method, args)
            } catch (e: Exception) {
                Log.e(TAG, "invokeMethod $method failed", e)
            }
        }
    }

    // ----------------------------------------------------------- notification

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "SMS Gateway",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Keeps the SMS gateway running"
                setShowBadge(false)
            }
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(text: String?): Notification {
        val launch = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pi = PendingIntent.getActivity(
            this, 0, launch ?: Intent(),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("AvaTOK SMS · Staging")
            .setContentText(text ?: "Gateway running — HDFC payment alerts to staging")
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(pi)
            .build()
    }

    private fun startForegroundSafely() {
        val notif = buildNotification(null)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIF_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            } else {
                startForeground(NOTIF_ID, notif)
            }
        } catch (e: Exception) {
            Log.e(TAG, "startForeground failed", e)
        }
    }

    private fun updateNotification(text: String?) {
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.notify(NOTIF_ID, buildNotification(text))
        } catch (e: Exception) {
            Log.e(TAG, "updateNotification failed", e)
        }
    }

    @Suppress("DEPRECATION")
    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            stopForeground(true)
        }
    }

    // -------------------------------------------------------------- watchdog

    private fun writeAlive() {
        // Written to the same SharedPreferences file the Flutter side / MainActivity
        // reads, so the dashboard watchdog can detect a killed service.
        getSharedPreferences(WATCHDOG_PREFS, Context.MODE_PRIVATE)
            .edit()
            .putLong(KEY_LAST_ALIVE, System.currentTimeMillis())
            .putLong(KEY_LAST_ALIVE_ELAPSED, SystemClock.elapsedRealtime())
            .apply()
    }

    companion object {
        private const val TAG = "UpeoFgService"

        /** Set true while the service is alive; read by the native channel. */
        @Volatile var isRunning = false

        const val ACTION_START = "com.upeo.action.START"
        const val ACTION_STOP = "com.upeo.action.STOP"
        const val ACTION_INCOMING_SMS = "com.upeo.action.INCOMING_SMS"

        const val EXTRA_SENDER = "sender"
        const val EXTRA_BODY = "body"
        const val EXTRA_TS = "ts"
        const val EXTRA_SUB_ID = "subId"
        const val EXTRA_SLOT = "slot"

        const val CHANNEL_ID = "upeo_gateway_channel"
        const val NOTIF_ID = 1001

        /** MethodChannel name shared with `backgroundMain` in Dart. */
        const val SMS_CHANNEL = "upeo/sms_events"
        const val BACKGROUND_ENTRYPOINT = "backgroundMain"

        private const val ALIVE_INTERVAL_MS = 60_000L

        const val WATCHDOG_PREFS = "upeo_watchdog"
        const val KEY_LAST_ALIVE = "last_alive_wall"
        const val KEY_LAST_ALIVE_ELAPSED = "last_alive_elapsed"
    }
}
