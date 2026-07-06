package com.upeo.upeo_sms_gateway

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.annotation.NonNull
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts the foreground UI engine and the `upeo/native` control channel that the
 * Flutter UI uses to drive native concerns: service lifecycle, battery /
 * autostart exemptions, and device/SIM introspection.
 */
class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, NATIVE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startService" -> { startGatewayService(); result.success(true) }
                    "stopService" -> { stopGatewayService(); result.success(true) }
                    "isServiceRunning" -> result.success(SmsForegroundService.isRunning)
                    "getServiceStatus" -> result.success(serviceStatus())

                    "isIgnoringBatteryOptimizations" ->
                        result.success(isIgnoringBatteryOptimizations())
                    "requestIgnoreBatteryOptimizations" ->
                        result.success(requestIgnoreBatteryOptimizations())
                    "openBatteryOptimizationSettings" ->
                        result.success(openBatteryOptimizationSettings())

                    "getManufacturer" -> result.success(Build.MANUFACTURER ?: "")
                    "openAutostartSettings" -> result.success(openAutostartSettings())
                    "openAppDetailsSettings" -> result.success(openAppDetailsSettings())
                    "openNotificationSettings" -> result.success(openNotificationSettings())

                    "getDeviceInfo" -> result.success(deviceInfo())
                    "getSimInfo" -> result.success(SimInfo.activeSubscriptions(this))

                    "readInbox" -> {
                        val since = (call.argument<Number>("sinceMillis"))?.toLong() ?: 0L
                        val limit = (call.argument<Number>("limit"))?.toInt() ?: 200
                        result.success(SmsInbox.read(this, since, limit))
                    }

                    else -> result.notImplemented()
                }
            }
    }

    // ------------------------------------------------------------ service

    private fun startGatewayService() {
        val i = Intent(this, SmsForegroundService::class.java).apply {
            action = SmsForegroundService.ACTION_START
        }
        ContextCompat.startForegroundService(this, i)
    }

    private fun stopGatewayService() {
        val i = Intent(this, SmsForegroundService::class.java).apply {
            action = SmsForegroundService.ACTION_STOP
        }
        // startService so onStartCommand handles the STOP action cleanly.
        try { startService(i) } catch (e: Exception) { stopService(Intent(this, SmsForegroundService::class.java)) }
    }

    private fun serviceStatus(): Map<String, Any?> {
        val prefs = getSharedPreferences(
            SmsForegroundService.WATCHDOG_PREFS, Context.MODE_PRIVATE
        )
        return mapOf(
            "isRunning" to SmsForegroundService.isRunning,
            "lastAliveMillis" to prefs.getLong(SmsForegroundService.KEY_LAST_ALIVE, 0L),
        )
    }

    // ------------------------------------------------------------ battery

    private fun isIgnoringBatteryOptimizations(): Boolean {
        return try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            pm.isIgnoringBatteryOptimizations(packageName)
        } catch (e: Exception) {
            false
        }
    }

    @android.annotation.SuppressLint("BatteryLife")
    private fun requestIgnoreBatteryOptimizations(): Boolean {
        return try {
            if (isIgnoringBatteryOptimizations()) return true
            val i = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                data = Uri.parse("package:$packageName")
            }
            startActivity(i)
            true
        } catch (e: Exception) {
            openBatteryOptimizationSettings()
        }
    }

    private fun openBatteryOptimizationSettings(): Boolean {
        return try {
            startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            true
        } catch (e: Exception) {
            openAppDetailsSettings()
        }
    }

    // ------------------------------------------------------------ OEM autostart

    /**
     * Best-effort deep-link into the OEM "autostart / protected apps" screen.
     * These component names are undocumented and vary by ROM version, so we try a
     * list of candidates and fall back to the app-details settings page.
     */
    private fun openAutostartSettings(): Boolean {
        val candidates = listOf(
            // Xiaomi / MIUI / Redmi / POCO
            ComponentName("com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity"),
            // Oppo / ColorOS / Realme
            ComponentName("com.coloros.safecenter", "com.coloros.safecenter.permission.startup.StartupAppListActivity"),
            ComponentName("com.coloros.safecenter", "com.coloros.safecenter.startupapp.StartupAppListActivity"),
            ComponentName("com.oppo.safe", "com.oppo.safe.permission.startup.StartupAppListActivity"),
            // Vivo / iQOO
            ComponentName("com.vivo.permissionmanager", "com.vivo.permissionmanager.activity.BgStartUpManagerActivity"),
            ComponentName("com.iqoo.secure", "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity"),
            ComponentName("com.iqoo.secure", "com.iqoo.secure.ui.phoneoptimize.BgStartUpManager"),
            // Huawei / Honor
            ComponentName("com.huawei.systemmanager", "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"),
            ComponentName("com.huawei.systemmanager", "com.huawei.systemmanager.optimize.process.ProtectActivity"),
            // Samsung (device care / battery)
            ComponentName("com.samsung.android.lool", "com.samsung.android.sm.ui.battery.BatteryActivity"),
            ComponentName("com.samsung.android.sm_cn", "com.samsung.android.sm.ui.battery.BatteryActivity"),
            // Letv, Asus, Transsion (Tecno/Infinix) often expose no public component;
            // they fall through to app-details below.
            ComponentName("com.asus.mobilemanager", "com.asus.mobilemanager.MainActivity"),
            ComponentName("com.letv.android.letvsafe", "com.letv.android.letvsafe.AutobootManageActivity"),
        )
        for (c in candidates) {
            try {
                val i = Intent().apply {
                    component = c
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK
                }
                if (packageManager.resolveActivity(i, 0) != null) {
                    startActivity(i)
                    return true
                }
            } catch (e: Exception) {
                // try next
            }
        }
        // Fallback: at least open our app's settings so the user can find autostart.
        return openAppDetailsSettings()
    }

    private fun openAppDetailsSettings(): Boolean {
        return try {
            val i = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.parse("package:$packageName")
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
            startActivity(i)
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun openNotificationSettings(): Boolean {
        return try {
            val i = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                    .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
            } else {
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                    .setData(Uri.parse("package:$packageName"))
            }
            startActivity(i)
            true
        } catch (e: Exception) {
            false
        }
    }

    // ------------------------------------------------------------ device info

    private fun deviceInfo(): Map<String, Any?> = mapOf(
        "manufacturer" to (Build.MANUFACTURER ?: ""),
        "brand" to (Build.BRAND ?: ""),
        "model" to (Build.MODEL ?: ""),
        "device" to (Build.DEVICE ?: ""),
        "product" to (Build.PRODUCT ?: ""),
        "androidRelease" to (Build.VERSION.RELEASE ?: ""),
        "sdkInt" to Build.VERSION.SDK_INT,
        "fingerprint" to (Build.FINGERPRINT ?: ""),
    )

    companion object {
        const val NATIVE_CHANNEL = "upeo/native"
    }
}
