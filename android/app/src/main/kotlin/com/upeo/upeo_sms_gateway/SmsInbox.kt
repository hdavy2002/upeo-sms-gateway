package com.upeo.upeo_sms_gateway

import android.content.Context
import android.provider.Telephony

/** Keyset pagination; errors propagate and must never look like an empty page. */
object SmsInbox {
    fun read(context: Context, afterDate: Long, afterId: Long, upperDate: Long,
             limit: Int): List<Map<String, Any?>> {
        require(limit in 1..500 && afterDate >= 0 && upperDate >= afterDate)
        val projection = arrayOf("_id", Telephony.Sms.ADDRESS, Telephony.Sms.BODY,
            Telephony.Sms.DATE, Telephony.Sms.SUBSCRIPTION_ID)
        // No LIMIT in sortOrder: several OEM providers reject that extension.
        val cursor = context.contentResolver.query(Telephony.Sms.Inbox.CONTENT_URI,
            projection, "(date > ? OR (date = ? AND _id > ?)) AND date <= ?",
            arrayOf(afterDate.toString(), afterDate.toString(), afterId.toString(),
                upperDate.toString()), "date ASC, _id ASC")
            ?: throw IllegalStateException("SMS provider returned no cursor")
        return cursor.use { c ->
            val id = c.getColumnIndexOrThrow("_id")
            val date = c.getColumnIndexOrThrow(Telephony.Sms.DATE)
            val sender = c.getColumnIndexOrThrow(Telephony.Sms.ADDRESS)
            val body = c.getColumnIndexOrThrow(Telephony.Sms.BODY)
            val sub = c.getColumnIndex(Telephony.Sms.SUBSCRIPTION_ID)
            val out = ArrayList<Map<String, Any?>>()
            while (out.size < limit && c.moveToNext()) {
                out.add(mapOf("id" to c.getLong(id), "date" to c.getLong(date),
                    "sender" to c.getString(sender), "body" to c.getString(body),
                    "subId" to if (sub >= 0) c.getInt(sub) else -1))
            }
            out
        }
    }
}
