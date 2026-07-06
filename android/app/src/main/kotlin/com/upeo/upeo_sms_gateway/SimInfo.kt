package com.upeo.upeo_sms_gateway

import android.content.Context
import android.telephony.SubscriptionManager

/**
 * Best-effort SIM / subscription lookups. Everything is wrapped in try/catch
 * because [SubscriptionManager] throws [SecurityException] when READ_PHONE_STATE
 * has not been granted, and some OEM ROMs throw odd exceptions of their own.
 */
object SimInfo {

    /** Resolve a subscription id to its physical SIM slot index (or -1). */
    fun slotForSubId(context: Context, subId: Int): Int {
        if (subId < 0) return -1
        return try {
            val sm = context.getSystemService(Context.TELEPHONY_SUBSCRIPTION_SERVICE)
                as SubscriptionManager
            sm.getActiveSubscriptionInfo(subId)?.simSlotIndex ?: -1
        } catch (e: Exception) {
            -1
        }
    }

    /** List active subscriptions for the Setup/About screens. */
    fun activeSubscriptions(context: Context): List<Map<String, Any?>> {
        return try {
            val sm = context.getSystemService(Context.TELEPHONY_SUBSCRIPTION_SERVICE)
                as SubscriptionManager
            sm.activeSubscriptionInfoList?.map {
                mapOf(
                    "subscriptionId" to it.subscriptionId,
                    "simSlot" to it.simSlotIndex,
                    "carrier" to (it.carrierName?.toString() ?: ""),
                    "displayName" to (it.displayName?.toString() ?: ""),
                    "number" to (it.number ?: ""),
                )
            } ?: emptyList()
        } catch (e: Exception) {
            emptyList()
        }
    }
}
