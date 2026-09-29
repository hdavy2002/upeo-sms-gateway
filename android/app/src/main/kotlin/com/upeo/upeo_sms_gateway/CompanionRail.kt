package com.upeo.upeo_sms_gateway

/**
 * [TAKEDOWN-HDFC-DARK-1 2026-09-20] Native-side mirror of the Dart `K.railDisabled`
 * switch. [SmsReceiver] and [BootReceiver] both check this first so the app stays
 * inert (never reads SMS, never starts the foreground service) even if a receiver
 * fires before the Dart engine has run. Flip back to false to restore behaviour.
 */
object CompanionRail {
    const val disabled = false
}
