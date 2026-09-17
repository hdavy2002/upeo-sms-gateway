import 'package:upeo_sms_gateway/src/config/app_config.dart';
import 'package:upeo_sms_gateway/src/core/canonical.dart';
import 'package:upeo_sms_gateway/src/core/constants.dart';
import 'package:upeo_sms_gateway/src/data/sms_message.dart';

// Synthetic data only. This is not a provisioned device or bank account.
const stagingConfig = AppConfig(
  apiBaseUrl: K.productionBaseUrl,
  deviceId: 'TEST_STAGING_DEVICE',
  secretKey: 'synthetic-test-secret-not-a-credential',
  allowlist: K.defaultAllowlist,
  accountSuffix: '1234',
  retentionDays: 14,
  allowInsecureHttp: false,
);

const paymentBody = 'HDFC Bank: Rs. 100.00 credited to A/c XX1234. Ref 999999.';

SmsRecord paymentRecord({String? deviceId, String body = paymentBody}) {
  const sender = 'AD-HDFCBK';
  const receivedAt = '2026-09-17T12:30:00+03:00';
  return SmsRecord(
    id: 1,
    sender: sender,
    message: body,
    receivedAt: receivedAt,
    simSlot: 0,
    subscriptionId: 1,
    deviceId: deviceId ?? stagingConfig.deviceId,
    status: SmsStatus.pending,
    retryCount: 0,
    lastError: null,
    nextAttemptAt: 0,
    messageHash: Canonical.messageHash(
      sender: sender, message: body, receivedAt: receivedAt,
    ),
    createdAt: 1,
    syncedAt: null,
  );
}
