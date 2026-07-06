import 'dart:math';

import '../config/app_config.dart';
import '../core/app_log.dart';
import '../core/canonical.dart';
import '../core/constants.dart';
import '../core/time_utils.dart';
import '../data/sms_message.dart';
import '../data/sms_repository.dart';
import 'api_client.dart';
import 'device_status.dart';

/// Result of a sweep, for UI feedback.
class SweepResult {
  final int sent;
  final int failed;
  final int skipped;
  const SweepResult(this.sent, this.failed, this.skipped);
}

/// Owns the capture → persist → send lifecycle, retry/backoff, heartbeat and
/// retention purge. Shared by the foreground-service isolate, the WorkManager
/// backstop, and the UI (manual sync). Concurrent sweeps from two isolates are
/// safe: the server dedups on `message_hash`/`nonce`, so a double-send returns
/// "duplicate" = success.
class SyncService {
  SyncService({
    required this.repo,
    required this.config,
    DeviceStatus? deviceStatus,
  }) : _device = deviceStatus ?? DeviceStatus();

  final SmsRepository repo;
  final AppConfig config;
  final DeviceStatus _device;
  final Random _rng = Random();

  static const _tag = 'Sync';

  /// Apply the allowlist and, if allowed, persist a captured SMS.
  /// Returns the inserted row id, or null if dropped/duplicate.
  Future<int?> captureIncoming({
    required String sender,
    required String body,
    required int pduTimestampMillis,
    required int simSlot,
    required int subscriptionId,
  }) async {
    if (!config.senderAllowed(sender)) {
      // Privacy: non-allowlisted messages are never stored or transmitted.
      AppLog.d(_tag, 'Dropped non-allowlisted SMS from "$sender"');
      return null;
    }

    final receivedAt = TimeUtils.iso8601Eat(
      pduTimestampMillis > 0
          ? pduTimestampMillis
          : DateTime.now().millisecondsSinceEpoch,
    );
    final hash = Canonical.messageHash(
      sender: sender,
      message: body,
      receivedAt: receivedAt,
    );
    final record = SmsRecord(
      sender: sender,
      message: body,
      receivedAt: receivedAt,
      simSlot: simSlot,
      subscriptionId: subscriptionId,
      deviceId: config.deviceId,
      status: SmsStatus.pending,
      retryCount: 0,
      lastError: null,
      nextAttemptAt: 0,
      messageHash: hash,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      syncedAt: null,
    );
    final id = await repo.insert(record);
    if (id != null) {
      AppLog.i(_tag, 'Captured allowlisted SMS from "$sender" (id=$id)');
    }
    return id;
  }

  /// Ingest messages read from the device SMS inbox (the backfill path).
  ///
  /// Each entry is `{sender, body, dateMillis, subId}`. Unlike the live path we
  /// dedup on exact sender+body (not just the message_hash) so a message the
  /// receiver already captured is never re-inserted even if the inbox timestamp
  /// differs from the original PDU timestamp. Returns the number newly stored.
  Future<int> ingestInboxBatch(List<Map<String, dynamic>> messages) async {
    var added = 0;
    for (final m in messages) {
      final sender = (m['sender'] ?? '').toString();
      final body = (m['body'] ?? '').toString();
      if (sender.isEmpty || body.isEmpty) continue;
      if (!config.senderAllowed(sender)) continue;
      // Already captured by the live path or an earlier scan?
      if (await repo.existsByContent(sender, body)) continue;

      final id = await captureIncoming(
        sender: sender,
        body: body,
        pduTimestampMillis: (m['dateMillis'] as num?)?.toInt() ?? 0,
        simSlot: -1,
        subscriptionId: (m['subId'] as num?)?.toInt() ?? -1,
      );
      if (id != null) {
        added++;
        AppLog.i(_tag, 'Backfilled missed SMS from "$sender" (id=$id)');
      }
    }
    return added;
  }

  /// Send everything currently due. No-op (skipped) if config is incomplete.
  Future<SweepResult> sweep() async {
    if (!config.isComplete) {
      AppLog.w(_tag, 'Sweep skipped: configuration incomplete');
      return const SweepResult(0, 0, 0);
    }
    if (!await _device.hasConnectivity()) {
      AppLog.d(_tag, 'Sweep skipped: no connectivity');
      return const SweepResult(0, 0, 0);
    }

    final api = ApiClient(config);
    final due = await repo.dueForSend(K.maxRetries, K.syncBatchSize);
    if (due.isEmpty) return const SweepResult(0, 0, 0);

    var sent = 0, failed = 0;
    for (final r in due) {
      final res = await api.sendIncoming(r);
      switch (res.outcome) {
        case SendOutcome.success:
          await repo.markSynced(r.id!);
          sent++;
          AppLog.i(_tag, 'Synced id=${r.id} (${res.detail})');
          break;
        case SendOutcome.transient:
        case SendOutcome.permanent:
          final nextRetry = r.retryCount + 1;
          final delay = _backoff(nextRetry);
          final nextAt = DateTime.now().add(delay).millisecondsSinceEpoch;
          await repo.markFailed(r.id!, nextRetry, nextAt, res.detail);
          failed++;
          final permanent = nextRetry >= K.maxRetries;
          AppLog.w(
            _tag,
            'Send failed id=${r.id} retry=$nextRetry'
            '${permanent ? ' (PERMANENT)' : ' next in ${delay.inSeconds}s'}: ${res.detail}',
          );
          break;
      }
    }
    await repo.setMeta(
      MetaKeys.lastSyncAt,
      '${DateTime.now().millisecondsSinceEpoch}',
    );
    return SweepResult(sent, failed, 0);
  }

  /// Exponential backoff with full jitter, capped.
  Duration _backoff(int attempt) {
    final exp = K.baseBackoff.inMilliseconds * pow(2, attempt - 1);
    final capped = min(exp.toDouble(), K.maxBackoff.inMilliseconds.toDouble());
    final jittered = _rng.nextDouble() * capped; // full jitter
    return Duration(milliseconds: jittered.toInt());
  }

  /// Gather health + send a signed heartbeat.
  Future<SendResult> sendHeartbeat() async {
    if (!config.isComplete) {
      return const SendResult(SendOutcome.permanent, 'config incomplete');
    }
    final api = ApiClient(config);
    final counts = await repo.counts(K.maxRetries);
    final last = await repo.lastReceived();
    final health = {
      'app_version': await _device.appVersion(),
      'pending': counts.pending,
      'failed': counts.failed,
      'synced': counts.synced,
      'last_sms_at': last?.receivedAt,
      'battery': await _device.batteryLevel(),
      'charging': await _device.isCharging(),
      'connectivity': await _device.connectivityLabel(),
      'sent_at_local': TimeUtils.nowEat(),
    };
    final res = await api.sendHeartbeat(health);
    AppLog.i(_tag, 'Heartbeat ${res.outcome.name}: ${res.detail}');
    await repo.setMeta(
      MetaKeys.lastHeartbeatAt,
      '${DateTime.now().millisecondsSinceEpoch}',
    );
    await repo.setMeta(
      MetaKeys.lastHeartbeatOk,
      '${res.outcome == SendOutcome.success}',
    );
    return res;
  }

  Future<void> purgeRetention() async {
    await repo.purgeSyncedOlderThan(Duration(days: config.retentionDays));
  }
}
