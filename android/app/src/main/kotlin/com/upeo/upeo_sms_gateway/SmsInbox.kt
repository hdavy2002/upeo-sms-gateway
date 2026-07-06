package com.upeo.upeo_sms_gateway

import android.content.Context
import android.provider.Telephony
import android.util.Log

/**
 * Reads the device SMS inbox (`content://sms/inbox`) so the Dart side can
 * backfill any allowlisted message the live `SMS_RECEIVED` receiver never
 * delivered — e.g. one that arrived while the app's DB was briefly closed or the
 * foreground service had been killed.
 *
 * This is a read-only query gated by the already-requested READ_SMS permission.
 * The allowlist + dedup + persistence all stay on the Dart side; this is a dumb
 * pipe, consistent with [SmsParser].
 */
object SmsInbox {

    private const val TAG = "UpeoSmsInbox"

    /** Returns inbox messages with `date > sinceMillis`, newest first, capped at [limit]. */
    fun read(context: Context, sinceMillis: Long, limit: Int): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        val projection = arrayOf(
            Telephony.Sms.ADDRESS,
            Telephony.Sms.BODY,
            Telephony.Sms.DATE,
            Telephony.Sms.SUBSCRIPTION_ID,
        )
        val selection = "${Telephony.Sms.DATE} > ?"
        val args = arrayOf(sinceMillis.toString())
        val sort = "${Telephony.Sms.DATE} DESC LIMIT $limit"
        try {
            context.contentResolver.query(
                Telephony.Sms.Inbox.CONTENT_URI, projection, selection, args, sort,
            )?.use { c ->
                val iAddr = c.getColumnIndex(Telephony.Sms.ADDRESS)
                val iBody = c.getColumnIndex(Telephony.Sms.BODY)
                val iDate = c.getColumnIndex(Telephony.Sms.DATE)
                val iSub = c.getColumnIndex(Telephony.Sms.SUBSCRIPTION_ID)
                while (c.moveToNext() && out.size < limit) {
                    out.add(
                        mapOf(
                            "sender" to (if (iAddr >= 0) c.getString(iAddr) else null),
                            "body" to (if (iBody >= 0) c.getString(iBody) else null),
                            "date" to (if (iDate >= 0) c.getLong(iDate) else 0L),
                            "subId" to (if (iSub >= 0) c.getInt(iSub) else -1),
                        ),
                    )
                }
            }
        } catch (e: Exception) {
            // Missing permission, OEM provider quirk, or an unsupported LIMIT clause:
            // return what we have (possibly empty); the caller treats it as no-op.
            Log.e(TAG, "readInbox failed", e)
        }
        return out
    }
}
