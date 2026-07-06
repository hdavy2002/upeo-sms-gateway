package com.upeo.upeo_sms_gateway

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * Manifest-registered receiver for `SMS_RECEIVED`.
 *
 * Per the design notes, a receiver alone is unreliable, so its only job is to
 * parse + reassemble the SMS and hand it to the [SmsForegroundService] (starting
 * the service if it is not already up). The service owns persistence, the
 * allowlist, and sync — keeping a single code path.
 *
 * Note: after an OEM *force-stop* this receiver will NOT fire until the app is
 * reopened. That is an Android-wide limitation; it is mitigated by the always-on
 * foreground service, the boot receiver, and the battery/autostart exemptions.
 */
class SmsReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return

        val sms = SmsParser.fromIntent(context, intent)
        if (sms == null) {
            Log.w(TAG, "SMS_RECEIVED but no parsable message")
            return
        }

        // We deliberately do NOT apply the allowlist here. The allowlist config
        // lives in the Dart/secure layer; the service forwards the raw message to
        // the Dart isolate which drops non-allowlisted senders BEFORE any
        // persistence or transmission. The body only transiently crosses an
        // in-process channel.
        val svc = Intent(context, SmsForegroundService::class.java).apply {
            action = SmsForegroundService.ACTION_INCOMING_SMS
            putExtra(SmsForegroundService.EXTRA_SENDER, sms.sender)
            putExtra(SmsForegroundService.EXTRA_BODY, sms.body)
            putExtra(SmsForegroundService.EXTRA_TS, sms.timestampMillis)
            putExtra(SmsForegroundService.EXTRA_SUB_ID, sms.subscriptionId)
            putExtra(SmsForegroundService.EXTRA_SLOT, sms.simSlot)
        }
        try {
            ContextCompat.startForegroundService(context, svc)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start foreground service for incoming SMS", e)
        }
    }

    companion object {
        private const val TAG = "UpeoSmsReceiver"
    }
}
