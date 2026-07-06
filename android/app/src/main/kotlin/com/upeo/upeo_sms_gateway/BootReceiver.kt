package com.upeo.upeo_sms_gateway

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * Restarts the gateway after a reboot or an app update so the operator never has
 * to remember to reopen the app.
 */
class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            "android.intent.action.QUICKBOOT_POWERON",
            "com.htc.intent.action.QUICKBOOT_POWERON",
            Intent.ACTION_MY_PACKAGE_REPLACED -> {
                Log.i(TAG, "Boot/update detected (${intent.action}) — starting gateway service")
                val svc = Intent(context, SmsForegroundService::class.java).apply {
                    action = SmsForegroundService.ACTION_START
                }
                try {
                    ContextCompat.startForegroundService(context, svc)
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to start service on boot", e)
                }
            }
        }
    }

    companion object {
        private const val TAG = "UpeoBootReceiver"
    }
}
