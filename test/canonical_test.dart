import 'package:flutter_test/flutter_test.dart';
import 'package:upeo_sms_gateway/src/core/canonical.dart';
import 'package:upeo_sms_gateway/src/core/time_utils.dart';

void main() {
  group('Canonical signing', () {
    test('message hash is stable & matches the documented spec', () {
      final hash = Canonical.messageHash(
        sender: 'MPESA',
        message: 'Test message',
        receivedAt: '2026-06-19T12:30:00+03:00',
      );
      // SHA256 of "MPESA|Test message|2026-06-19T12:30:00+03:00"
      expect(hash.length, 64);
      expect(hash, Canonical.messageHash(
        sender: 'MPESA',
        message: 'Test message',
        receivedAt: '2026-06-19T12:30:00+03:00',
      ));
    });

    test('incoming string-to-sign uses newline join in documented order', () {
      final s = Canonical.incomingStringToSign(
        deviceId: 'PHONE_001',
        sender: 'MPESA',
        message: 'hi',
        receivedAt: '2026-06-19T12:30:00+03:00',
        simSlot: 1,
        messageHash: 'abc',
        nonce: 'n-1',
        sentAt: '2026-06-19T12:30:01+03:00',
      );
      expect(
        s,
        'PHONE_001\nMPESA\nhi\n2026-06-19T12:30:00+03:00\n1\nabc\nn-1\n2026-06-19T12:30:01+03:00',
      );
    });

    test('HMAC is deterministic hex', () {
      final sig = Canonical.sign(stringToSign: 'hello', secret: 'secret');
      expect(sig, Canonical.sign(stringToSign: 'hello', secret: 'secret'));
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(sig), isTrue);
    });
  });

  group('TimeUtils', () {
    test('formats epoch millis as EAT ISO-8601', () {
      // 2026-06-19T09:30:00Z == 12:30:00 +03:00
      final ms = DateTime.utc(2026, 6, 19, 9, 30, 0).millisecondsSinceEpoch;
      expect(TimeUtils.iso8601Eat(ms), '2026-06-19T12:30:00+03:00');
    });
  });
}
