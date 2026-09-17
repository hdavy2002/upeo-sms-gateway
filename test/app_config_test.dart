import 'package:flutter_test/flutter_test.dart';
import 'package:upeo_sms_gateway/src/config/app_config.dart';
import 'package:upeo_sms_gateway/src/core/constants.dart';

import 'fixtures.dart';

void main() {
  group('staging boundary', () {
    test('defaults have no credentials or account and cannot forward', () {
      expect(AppConfig.empty.apiBaseUrl, K.stagingBaseUrl);
      expect(AppConfig.empty.deviceId, isEmpty);
      expect(AppConfig.empty.secretKey, isEmpty);
      expect(AppConfig.empty.accountSuffix, isEmpty);
      expect(AppConfig.empty.isComplete, isFalse);
      expect(stagingConfig.isComplete, isTrue);
    });

    test('only the pinned HTTPS root is valid', () {
      for (final url in [K.stagingBaseUrl, '${K.stagingBaseUrl}/', '${K.stagingBaseUrl}:443']) {
        expect(AppConfig.validateBaseUrl(url), isNull, reason: url);
      }
      for (final url in [
        '', 'https://example.invalid', 'http://api-staging.avatok.ai',
        '${K.stagingBaseUrl}.example.invalid', '${K.stagingBaseUrl}:444',
        '${K.stagingBaseUrl}/api', '${K.stagingBaseUrl}?next=elsewhere',
        '${K.stagingBaseUrl}#fragment',
        'https://user@api-staging.avatok.ai',
      ]) {
        expect(AppConfig.validateBaseUrl(url), isNotNull, reason: url);
      }
      expect(stagingConfig.copyWith(allowInsecureHttp: true).isComplete, isFalse);
    });

    test('invalid fields fail closed outside the UI too', () {
      for (final cfg in [
        stagingConfig.copyWith(deviceId: 'device\nother'),
        stagingConfig.copyWith(secretKey: 'short'),
        stagingConfig.copyWith(secretKey: '${stagingConfig.secretKey}\n'),
        stagingConfig.copyWith(accountSuffix: ''),
        stagingConfig.copyWith(accountSuffix: '12345'),
        stagingConfig.copyWith(allowlist: []),
        stagingConfig.copyWith(allowlist: ['HDFC*']),
        stagingConfig.copyWith(allowlist: ['MPESA']),
        stagingConfig.copyWith(retentionDays: 2),
        stagingConfig.copyWith(retentionDays: 91),
      ]) {
        expect(cfg.isComplete, isFalse);
        expect(cfg.paymentSmsAllowed('HDFCBK', paymentBody), isFalse);
      }
    });
  });

  group('HDFC capture filter', () {
    test('exact bank header with DLT prefix/category is accepted', () {
      for (final sender in ['HDFCBK', 'ad-hdfcbk', 'VM-HDFCBK-S', 'HDFCBN-T']) {
        expect(stagingConfig.senderAllowed(sender), isTrue, reason: sender);
        expect(stagingConfig.paymentSmsAllowed(sender, paymentBody), isTrue);
      }
      for (final sender in ['NOTHDFCBK', 'HDFCBKSCAM', 'MPESA', '12345', 'HDFC', 'AD-HDFCBK-OTHER']) {
        expect(stagingConfig.senderAllowed(sender), isFalse, reason: sender);
      }
    });

    test('masked, full, and differently labelled account tokens', () {
      for (final token in ['A/c XX1234', 'a/c **1234', 'Account No. 001234', 'Acct: 1234', 'A/C XXXX1234']) {
        expect(stagingConfig.paymentSmsAllowed('HDFCBK',
            'INR 100 received in $token.'), isTrue, reason: token);
      }
    });

    test('suffix must belong to an account token and be its ending', () {
      for (final body in [
        'Rs 1234 credited to A/c XX9999. Ref 1234.',
        'INR 100 received. Phone 1234.',
        'INR 100 received in A/c XX12345.',
        'INR 100 received in A/c XX1234ABC.',
        'INR 100 received in A/c XX9999. UTR 1234.',
      ]) {
        expect(stagingConfig.paymentSmsAllowed('HDFCBK', body), isFalse, reason: body);
      }
    });

    test('OTP, debit and irrelevant alerts never enter the queue', () {
      for (final body in [
        'OTP 456789. $paymentBody',
        'One-time code 456789. $paymentBody',
        'Password reset. $paymentBody',
        'PIN verification. $paymentBody',
        'Rs 100 debited from A/c XX1234; beneficiary credited.',
        'Get a credit card for Account XX1234. Rs 100 cashback.',
        'A/c XX1234 balance is Rs 100.',
        'Your payment is received in A/c XX1234.',
        '',
      ]) {
        expect(stagingConfig.paymentSmsAllowed('HDFCBK', body), isFalse, reason: body);
      }
      expect(stagingConfig.paymentSmsAllowed('HDFCBK', '$paymentBody${'x' * 8192}'), isFalse);
      expect(stagingConfig.copyWith(accountSuffix: '9999')
          .paymentSmsAllowed('HDFCBK', paymentBody), isFalse);
    });
  });
}
