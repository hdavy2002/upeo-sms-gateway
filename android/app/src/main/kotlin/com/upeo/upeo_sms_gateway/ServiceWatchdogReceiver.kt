package com.upeo.upeo_sms_gateway

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * [UPI3-REENABLE] Native ~15 min backstop that survives the foreground service
 * being killed. The Dart WorkManager isolate has no native host it can call, so
 * the restart lives here: an AlarmManager alarm (kept by the OS after the
 * process dies) fires this receiver, which re-arms itself and restarts
 * [SmsForegroundService] if it is not running, resuming the 60 s inbox catch-up.
 * Armed by the service on start and by [BootReceiver]; not effective after a
 * user force-stop until the app is opened again (Android limitation).
 */
class ServiceWatchdogReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (CompanionRail.disabled) return
        arm(context)
        if (!SmsForegroundService.isRunning) {
            Log.w(TAG, "Watchdog: service not running — restarting")
            val svc = Intent(context, SmsForegroundService::class.java).apply {
                action = SmsForegroundService.ACTION_START
            }
            try {
                ContextCompat.startForegroundService(context, svc)
            } catch (e: Exception) {
                Log.e(TAG, "Watchdog: failed to restart service", e)
            }
        }
    }

    companion object {
        private const val TAG = "UpeoWatchdog"
        private const val INTERVAL_MS = 15 * 60 * 1000L

        private fun pending(context: Context): PendingIntent {
            val i = Intent(context, ServiceWatchdogReceiver::class.java)
            return PendingIntent.getBroadcast(
                context, 0, i,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }

        fun arm(context: Context) {
            if (CompanionRail.disabled) return
            try {
                val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
                val at = System.currentTimeMillis() + INTERVAL_MS
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending(context))
                } else {
                    am.set(AlarmManager.RTC_WAKEUP, at, pending(context))
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to arm watchdog", e)
            }
        }

        fun cancel(context: Context) {
            try {
                (context.getSystemService(Context.ALARM_SERVICE) as AlarmManager)
                    .cancel(pending(context))
            } catch (_: Exception) {}
        }
    }
}
