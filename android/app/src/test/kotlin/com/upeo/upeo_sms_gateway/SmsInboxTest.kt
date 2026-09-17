package com.upeo.upeo_sms_gateway

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowContentResolver

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class SmsInboxTest {
    class InboxProvider : ContentProvider() {
        var fail = false
        var absentCursor = false
        override fun onCreate() = true
        override fun query(uri: Uri, projection: Array<out String>?, selection: String?,
            selectionArgs: Array<out String>?, sortOrder: String?): Cursor? {
            if (fail) throw SecurityException("permission denied")
            if (absentCursor) return null
            assertEquals("date ASC, _id ASC", sortOrder)
            assertFalse(sortOrder!!.contains("LIMIT"))
            val a = selectionArgs!!
            val date = a[0].toLong(); val id = a[2].toLong(); val upper = a[3].toLong()
            val c = MatrixCursor(arrayOf("_id", "address", "body", "date", "sub_id"))
            for (row in 1L..501L) {
                if (500L <= upper && (500L > date || (500L == date && row > id)))
                    c.addRow(arrayOf(row, "TEST-HDFCBK", "synthetic", 500L, 1))
            }
            // A future row must not leak into this scan's frozen window.
            if (2000L <= upper && 2000L > date) c.addRow(arrayOf(900L,"TEST","future",2000L,1))
            return c
        }
        override fun getType(uri: Uri): String? = null
        override fun insert(uri: Uri, values: ContentValues?): Uri? = null
        override fun delete(uri: Uri, selection: String?, args: Array<out String>?) = 0
        override fun update(uri: Uri, values: ContentValues?, selection: String?, args: Array<out String>?) = 0
    }

    @Test fun equalTimestampPagesKeepAllIdsAndUpperBound() {
        ShadowContentResolver.registerProviderInternal("sms", InboxProvider())
        val context = RuntimeEnvironment.getApplication()
        var date = 0L; var id = -1L
        val seen = mutableSetOf<Long>()
        while (true) {
            val page = SmsInbox.read(context, date, id, 1000L, 200)
            if (page.isEmpty()) break
            assertTrue(page.size <= 200)
            for (row in page) assertTrue(seen.add(row["id"] as Long))
            date = page.last()["date"] as Long; id = page.last()["id"] as Long
        }
        assertEquals(501, seen.size)
        assertFalse(seen.contains(900L))
    }

    @Test fun providerFailuresAreNotEmptySuccess() {
        val provider = InboxProvider()
        ShadowContentResolver.registerProviderInternal("sms", provider)
        val context = RuntimeEnvironment.getApplication()
        provider.fail = true
        assertThrows(SecurityException::class.java) { SmsInbox.read(context, 0, -1, 1000, 200) }
        provider.fail = false; provider.absentCursor = true
        assertThrows(IllegalStateException::class.java) { SmsInbox.read(context, 0, -1, 1000, 200) }
    }
}
