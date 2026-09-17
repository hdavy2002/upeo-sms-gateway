import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import '../config/app_config.dart';
import '../core/app_log.dart';
import '../core/canonical.dart';
import '../core/constants.dart';
import '../core/time_utils.dart';
import '../data/sms_message.dart';

/// Outcome of a single send attempt.
enum SendOutcome {
  /// Valid transport acknowledgement; receipt and match outcomes are separate.
  success,

  /// Transient (network/5xx/timeout) — keep in queue, back off, retry.
  transient,

  /// Permanent (4xx other than duplicate, e.g. bad signature/config) — keep but
  /// the operator must fix configuration.
  permanent,
}

class SendResult {
  final SendOutcome outcome;
  final String detail;
  final String receiptState, matchState;
  final String? receiptId, reasonCode;
  final int? serverTime;
  const SendResult(this.outcome, this.detail, {
    this.receiptState = 'unknown', this.matchState = 'unknown',
    this.receiptId, this.reasonCode, this.serverTime,
  });

  /// Legacy acknowledgements never imply receipt acceptance or payment success.
  static SendResult acknowledgement(dynamic data) {
    if (data is! Map) {
      return const SendResult(SendOutcome.transient, 'invalid acknowledgement');
    }
    if (data['protocol_version'] == 2) {
      const receiptStates = {'accepted', 'ignored', 'review_pending'};
      const matchStates = {'unmatched', 'awaiting_reference', 'confirmed'};
      final receipt = data['receipt_state'];
      final match = data['match_state'];
      final time = data['server_time'];
      final id = data['receipt_id'];
      if (data['ok'] != true || !receiptStates.contains(receipt) ||
          !matchStates.contains(match) ||
          (time != null && (time is! int || time <= 0)) ||
          (id != null && (id is! String || id.isEmpty)) ||
          (receipt == 'accepted' && id == null) ||
          (match != 'unmatched' && (receipt != 'accepted' || id == null))) {
        return const SendResult(SendOutcome.transient, 'invalid v2 acknowledgement');
      }
      final reason = data['reason_code'];
      return SendResult(SendOutcome.success, 'acknowledged',
        receiptState: receipt as String, matchState: match as String,
        receiptId: id as String?, serverTime: time as int?,
        reasonCode: reason is String && RegExp(r'^[a-z0-9_:-]{1,80}$').hasMatch(reason)
          ? reason : null);
    }
    if (data['protocol_version'] != null && data['protocol_version'] != 1) {
      return const SendResult(SendOutcome.transient, 'unsupported acknowledgement protocol');
    }
    final status = data['status'] ?? data['result'];
    if (data['ok'] == true || status == 'accepted' || status == 'duplicate' ||
        status == 'review_pending' || status == 'confirmed') {
      return const SendResult(SendOutcome.success, 'legacy acknowledgement; outcome unknown',
        reasonCode: 'acknowledged_legacy');
    }
    return const SendResult(SendOutcome.transient, 'unrecognized acknowledgement');
  }
}

/// Signs payloads and talks to the backend over HTTPS. The [AppConfig.secretKey]
/// is used only to compute the HMAC; it is never sent or logged.
class ApiClient {
  ApiClient(this._cfg, {HttpClientAdapter? adapter}) : _dio = _build(_cfg) {
    if (adapter != null) _dio.httpClientAdapter = adapter;
  }

  final AppConfig _cfg;
  final Dio _dio;
  static const _uuid = Uuid();
  static const _tag = 'ApiClient';

  static Dio _build(AppConfig cfg) {
    final dio = Dio(BaseOptions(
      // Runtime configuration must validate too; using the pinned origin here
      // prevents even an accidentally bypassed validator reaching another host.
      baseUrl: K.productionBaseUrl,
      followRedirects: false,
      maxRedirects: 0,
      connectTimeout: const Duration(seconds: 15),
      sendTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 20),
      // We treat any status < 500 as a non-throwing response so we can inspect it.
      validateStatus: (s) => s != null && s < 600,
      headers: {'Content-Type': 'application/json'},
    ));
    return dio;
  }

  /// Build the full, signed incoming-SMS payload for [r].
  Map<String, dynamic> buildIncomingPayload(SmsRecord r) {
    final nonce = _uuid.v4();
    final sentAt = TimeUtils.nowEat();
    final stringToSign = Canonical.incomingStringToSign(
      deviceId: r.deviceId,
      sender: r.sender,
      message: r.message,
      receivedAt: r.receivedAt,
      simSlot: r.simSlot,
      messageHash: r.messageHash,
      nonce: nonce,
      sentAt: sentAt,
    );
    final signature = Canonical.sign(stringToSign: stringToSign, secret: _cfg.secretKey);
    return {
      'device_id': r.deviceId,
      'sender': r.sender,
      'message': r.message,
      'received_at': r.receivedAt,
      'sim_slot': r.simSlot,
      'message_hash': r.messageHash,
      'nonce': nonce,
      'sent_at': sentAt,
      'signature': signature,
    };
  }

  Future<SendResult> sendIncoming(SmsRecord r) async {
    if (!_cfg.isComplete) {
      return const SendResult(SendOutcome.permanent, 'invalid production configuration');
    }
    if (r.deviceId != _cfg.deviceId || !_cfg.paymentSmsAllowed(r.sender, r.message)) {
      return const SendResult(SendOutcome.permanent, 'queued SMS does not match current configuration');
    }
    final payload = buildIncomingPayload(r);
    try {
      final res = await _dio.post(K.incomingPath, data: payload);
      final code = res.statusCode ?? 0;
      if (code >= 200 && code < 300) {
        return SendResult.acknowledgement(res.data);
      }
      if (code == 409 && _looksDuplicate(res.data)) {
        // A replay/config conflict must not silently acknowledge a queued SMS.
        return SendResult.acknowledgement(res.data);
      }
      if (code == 408 || code == 429) {
        return SendResult(SendOutcome.transient, 'HTTP $code');
      }
      if (code >= 300 && code < 400) {
        return const SendResult(SendOutcome.permanent, 'redirect refused');
      }
      if (code >= 400 && code < 500) {
        return SendResult(SendOutcome.permanent, 'HTTP $code');
      }
      return SendResult(SendOutcome.transient, 'HTTP $code');
    } on DioException catch (e) {
      return SendResult(SendOutcome.transient, _dioMsg(e));
    } catch (e) {
      return const SendResult(SendOutcome.transient, 'request failed');
    }
  }

  /// Signed heartbeat. Doubles as the "Test Connection" handshake.
  Future<SendResult> sendHeartbeat(Map<String, dynamic> health) async {
    if (!_cfg.isComplete) {
      return const SendResult(SendOutcome.permanent, 'invalid production configuration');
    }
    final nonce = _uuid.v4();
    final sentAt = TimeUtils.nowEat();
    final stringToSign = Canonical.heartbeatStringToSign(
      deviceId: _cfg.deviceId,
      nonce: nonce,
      sentAt: sentAt,
    );
    final signature = Canonical.sign(stringToSign: stringToSign, secret: _cfg.secretKey);
    final payload = {
      ...health,
      'device_id': _cfg.deviceId,
      'nonce': nonce,
      'sent_at': sentAt,
      'signature': signature,
    };
    try {
      final res = await _dio.post(K.heartbeatPath, data: payload);
      final code = res.statusCode ?? 0;
      if (code >= 200 && code < 300) {
        return const SendResult(SendOutcome.success, 'ok');
      }
      if (code == 408 || code == 429) {
        return SendResult(SendOutcome.transient, 'HTTP $code');
      }
      if (code >= 300 && code < 400) {
        return const SendResult(SendOutcome.permanent, 'redirect refused');
      }
      if (code >= 400 && code < 500) {
        return SendResult(SendOutcome.permanent, 'HTTP $code');
      }
      return SendResult(SendOutcome.transient, 'HTTP $code');
    } on DioException catch (e) {
      return SendResult(SendOutcome.transient, _dioMsg(e));
    } catch (e) {
      return const SendResult(SendOutcome.transient, 'request failed');
    }
  }

  /// In-app update check: returns the latest {version, build, url, notes} or null.
  Future<Map<String, dynamic>?> checkLatestVersion() async {
    if (!_cfg.isComplete) return null;
    try {
      final res = await _dio.get(K.versionPath);
      if ((res.statusCode ?? 0) >= 200 && (res.statusCode ?? 0) < 300 && res.data is Map) {
        return (res.data as Map).map((k, v) => MapEntry(k.toString(), v));
      }
    } catch (e) {
      AppLog.w(_tag, 'version check failed');
    }
    return null;
  }

  bool _looksDuplicate(dynamic data) {
    if (data is Map) {
      final s = (data['status'] ?? data['result'] ?? '').toString().toLowerCase();
      return s == 'duplicate';
    }
    return false;
  }

  String _dioMsg(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return 'timeout';
      case DioExceptionType.connectionError:
        return 'connection error';
      default:
        return e.type.name;
    }
  }
}
