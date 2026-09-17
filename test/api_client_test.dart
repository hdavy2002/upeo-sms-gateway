import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upeo_sms_gateway/src/core/canonical.dart';
import 'package:upeo_sms_gateway/src/core/constants.dart';
import 'package:upeo_sms_gateway/src/services/api_client.dart';

import 'fixtures.dart';

class RecordingAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  int status = 200;
  Map<String, dynamic> response = {'status': 'accepted'};

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    return ResponseBody.fromString(jsonEncode(response), status,
        headers: {Headers.contentTypeHeader: ['application/json']});
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('payment payload retains Upeo canonicalization and fresh retry nonce', () {
    final api = ApiClient(stagingConfig);
    final record = paymentRecord();
    final first = api.buildIncomingPayload(record);
    final retry = api.buildIncomingPayload(record);
    expect(first['nonce'], isNot(retry['nonce']));
    expect(first['message_hash'], record.messageHash);
    expect(retry['message_hash'], first['message_hash']);
    expect(first['received_at'], record.receivedAt);
    expect(first['message'], record.message);
    expect(first['signature'], Canonical.sign(
      stringToSign: [record.deviceId, record.sender, record.message,
        record.receivedAt, '${record.simSlot}', record.messageHash,
        first['nonce'], first['sent_at']].join('\n'),
      secret: stagingConfig.secretKey,
    ));
    expect(jsonEncode(first), isNot(contains(stagingConfig.secretKey)));
  });

  test('test heartbeat only posts signed heartbeat to staging; auth cannot be overridden', () async {
    final adapter = RecordingAdapter();
    final api = ApiClient(stagingConfig, adapter: adapter);
    final result = await api.sendHeartbeat({
      'test': true, 'device_id': 'override', 'nonce': 'override',
      'sent_at': 'override', 'signature': 'override',
    });
    expect(result.outcome, SendOutcome.success);
    expect(adapter.requests, hasLength(1));
    final request = adapter.requests.single;
    expect(request.method, 'POST');
    expect(request.uri.toString(), '${K.productionBaseUrl}${K.heartbeatPath}');
    expect(request.followRedirects, isFalse);
    expect(request.maxRedirects, 0);
    final payload = request.data as Map;
    expect(payload['test'], isTrue);
    expect(payload.containsKey('message'), isFalse);
    expect(payload['device_id'], stagingConfig.deviceId);
    expect(payload['nonce'], isNot('override'));
    expect(payload['sent_at'], isNot('override'));
    expect(payload['signature'], Canonical.sign(
      stringToSign: '${payload['device_id']}\n${payload['nonce']}\n${payload['sent_at']}',
      secret: stagingConfig.secretKey,
    ));
  });

  test('invalid config, identity change or filter change sends nothing', () async {
    final adapter = RecordingAdapter();
    for (final cfg in [
      stagingConfig.copyWith(apiBaseUrl: 'https://example.invalid'),
      stagingConfig.copyWith(allowInsecureHttp: true),
      stagingConfig.copyWith(accountSuffix: ''),
    ]) {
      final api = ApiClient(cfg, adapter: adapter);
      expect((await api.sendIncoming(paymentRecord())).outcome, SendOutcome.permanent);
      expect((await api.sendHeartbeat({})).outcome, SendOutcome.permanent);
      expect(await api.checkLatestVersion(), isNull);
    }
    final api = ApiClient(stagingConfig, adapter: adapter);
    expect((await api.sendIncoming(paymentRecord(deviceId: 'OLD_DEVICE'))).outcome,
        SendOutcome.permanent);
    expect((await api.sendIncoming(paymentRecord(body: 'OTP 123456'))).outcome,
        SendOutcome.permanent);
    expect(adapter.requests, isEmpty);
  });

  test('only explicit duplicate conflicts count as delivered', () async {
    final adapter = RecordingAdapter()..status = 409;
    final api = ApiClient(stagingConfig, adapter: adapter);
    for (final response in [
      {'status': 'replay'}, {'status': 'not_duplicate'},
      {'detail': 'duplicate nonce'}, <String, dynamic>{},
    ]) {
      adapter.response = response;
      expect((await api.sendIncoming(paymentRecord())).outcome, SendOutcome.permanent);
    }
    adapter.response = {'status': 'duplicate'};
    expect((await api.sendIncoming(paymentRecord())).outcome, SendOutcome.success);
    adapter.response = {'result': 'duplicate'};
    expect((await api.sendIncoming(paymentRecord())).outcome, SendOutcome.success);
  });

  test('rate limits and server failures retry; redirects and auth failures stay failed', () async {
    final adapter = RecordingAdapter();
    final api = ApiClient(stagingConfig, adapter: adapter);
    for (final code in [408, 429, 500, 503]) {
      adapter.status = code;
      expect((await api.sendIncoming(paymentRecord())).outcome, SendOutcome.transient);
      expect((await api.sendHeartbeat({})).outcome, SendOutcome.transient);
    }
    for (final code in [301, 302, 307, 308, 400, 401, 403]) {
      adapter.status = code;
      adapter.response = {'detail': 'sensitive SMS echoed by a server'};
      final result = await api.sendIncoming(paymentRecord());
      expect(result.outcome, SendOutcome.permanent);
      expect(result.detail, isNot(contains('sensitive')));
      expect((await api.sendHeartbeat({})).outcome, SendOutcome.permanent);
    }
  });
}
