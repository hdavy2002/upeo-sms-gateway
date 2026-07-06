package com.upeo.upeo_sms_gateway

import android.content.Context
import android.content.Intent
import android.provider.Telephony

/**
 * A single, logical (already multipart-reassembled) incoming SMS.
 *
 * The gateway is a *dumb pipe*: [body] is the raw SMS text, never parsed or
 * modified. Business semantics (M-Pesa codes, OTPs, …) belong on the backend.
 */
data class IncomingSms(
    val sender: String,
    val body: String,
    /** PDU / SMSC timestamp in epoch millis (when the network stamped it). */
    val timestampMillis: Long,
    val subscriptionId: Int,
    val simSlot: Int,
)

/** Parses + reassembles multipart SMS out of an `SMS_RECEIVED` broadcast. */
object SmsParser {

    fun fromIntent(context: Context, intent: Intent): IncomingSms? {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return null

        val parts = try {
            Telephony.Sms.Intents.getMessagesFromIntent(intent)
        } catch (e: Exception) {
            null
        } ?: return null
        if (parts.isEmpty()) return null

        // Multipart reassembly: the broadcast carries every segment of one
        // logical message. Concatenate the bodies in order; the sender and the
        // PDU timestamp come from the first segment.
        val first = parts[0]
        val sender = first.displayOriginatingAddress
            ?: first.originatingAddress
            ?: "UNKNOWN"
        val timestamp = first.timestampMillis

        val body = StringBuilder()
        for (part in parts) {
            body.append(part.displayMessageBody ?: part.messageBody ?: "")
        }

        // Subscription id (which SIM received it). Not all OEMs populate this.
        val subId = intent.getIntExtra("subscription", -1)
            .let { if (it >= 0) it else intent.getIntExtra("android.telephony.extra.SUBSCRIPTION_INDEX", -1) }
        val slot = SimInfo.slotForSubId(context, subId)

        return IncomingSms(
            sender = sender,
            body = body.toString(),
            timestampMillis = timestamp,
            subscriptionId = subId,
            simSlot = slot,
        )
    }
}
