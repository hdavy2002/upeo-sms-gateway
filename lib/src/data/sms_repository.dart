import 'package:sqflite_sqlcipher/sqflite.dart';

import '../core/app_log.dart';
import 'database.dart';
import 'sms_message.dart';

/// Counts surfaced on the dashboard.
class QueueCounts {
  final int pending;
  final int synced;
  final int failed;
  final int permanentlyFailed;
  const QueueCounts(this.pending, this.synced, this.failed, this.permanentlyFailed);
  int get total => pending + synced + failed;
}

/// Data-access object over the encrypted `messages` table.
class SmsRepository {
  SmsRepository(this._appDb);
  final AppDatabase _appDb;
  Database get _db => _appDb.db;

  static const _tag = 'SmsRepo';

  /// Run a DB operation, transparently reopening + retrying once if the shared
  /// connection was closed by another isolate. Without this, a single stray
  /// close stranded the gateway with `database_closed` until an app restart and
  /// silently stopped capturing incoming SMS.
  Future<T> _guard<T>(Future<T> Function() op) async {
    try {
      return await op();
    } on DatabaseException catch (e) {
      if (_isClosed(e)) {
        AppLog.w(_tag, 'database_closed — reopening and retrying once');
        await _appDb.reopen();
        return await op();
      }
      rethrow;
    }
  }

  static bool _isClosed(DatabaseException e) =>
      e.toString().toLowerCase().contains('database_closed');

  /// Insert a captured SMS. Returns the row id, or null if it was a duplicate
  /// (unique `message_hash` conflict) — which is the intended dedup behaviour.
  Future<int?> insert(SmsRecord r) {
    return _guard(() async {
      try {
        final id = await _db.insert(
          AppDatabase.table,
          r.toMap(),
          conflictAlgorithm: ConflictAlgorithm.abort,
        );
        return id;
      } on DatabaseException catch (e) {
        if (e.isUniqueConstraintError()) {
          AppLog.i(_tag, 'Duplicate SMS dropped (hash=${_short(r.messageHash)})');
          return null;
        }
        rethrow; // closed-connection errors bubble up to _guard for retry
      }
    });
  }

  /// Does an allowlisted message with this exact sender + body already exist?
  /// Used by the device-inbox backfill to avoid re-ingesting a message the live
  /// path already captured, even if the inbox timestamp differs slightly from
  /// the PDU timestamp (which would otherwise yield a different message_hash).
  Future<bool> existsByContent(String sender, String message) {
    return _guard(() async {
      final r = await _db.rawQuery(
        'SELECT 1 FROM ${AppDatabase.table} WHERE sender = ? AND message = ? LIMIT 1',
        [sender, message],
      );
      return r.isNotEmpty;
    });
  }

  /// Rows due for a send attempt: pending, or failed-and-not-exhausted whose
  /// backoff window has elapsed.
  Future<List<SmsRecord>> dueForSend(int maxRetries, int limit) {
    return _guard(() async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final rows = await _db.query(
        AppDatabase.table,
        where:
            "status = ? OR (status = ? AND retry_count < ? AND next_attempt_at <= ?)",
        whereArgs: [SmsStatus.pending.value, SmsStatus.failed.value, maxRetries, now],
        orderBy: 'created_at ASC',
        limit: limit,
      );
      return rows.map(SmsRecord.fromMap).toList();
    });
  }

  Future<void> markSynced(int id) {
    return _guard(() async {
      await _db.update(
        AppDatabase.table,
        {
          'status': SmsStatus.synced.value,
          'synced_at': DateTime.now().millisecondsSinceEpoch,
          'last_error': null,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
    });
  }

  Future<void> markFailed(int id, int retryCount, int nextAttemptAt, String error) {
    return _guard(() async {
      await _db.update(
        AppDatabase.table,
        {
          'status': SmsStatus.failed.value,
          'retry_count': retryCount,
          'next_attempt_at': nextAttemptAt,
          'last_error': error,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
    });
  }

  /// Manual retry from the UI: reset a failed row so it is picked up immediately.
  Future<void> resetForRetry(int id) {
    return _guard(() async {
      await _db.update(
        AppDatabase.table,
        {
          'status': SmsStatus.pending.value,
          'next_attempt_at': 0,
          'last_error': null,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
    });
  }

  Future<QueueCounts> counts(int maxRetries) {
    return _guard(() async {
      Future<int> count(String where, List<Object?> args) async {
        final r = await _db.rawQuery(
          'SELECT COUNT(*) c FROM ${AppDatabase.table} WHERE $where',
          args,
        );
        return (r.first['c'] as int?) ?? 0;
      }

      final pending = await count('status = ?', [SmsStatus.pending.value]);
      final synced = await count('status = ?', [SmsStatus.synced.value]);
      final failed = await count('status = ?', [SmsStatus.failed.value]);
      final permanent = await count(
        'status = ? AND retry_count >= ?',
        [SmsStatus.failed.value, maxRetries],
      );
      return QueueCounts(pending, synced, failed, permanent);
    });
  }

  Future<List<SmsRecord>> recent({int limit = 100}) {
    return _guard(() async {
      final rows = await _db.query(
        AppDatabase.table,
        orderBy: 'created_at DESC',
        limit: limit,
      );
      return rows.map(SmsRecord.fromMap).toList();
    });
  }

  Future<SmsRecord?> lastReceived() {
    return _guard(() async {
      final rows = await _db.query(
        AppDatabase.table,
        orderBy: 'created_at DESC',
        limit: 1,
      );
      if (rows.isEmpty) return null;
      return SmsRecord.fromMap(rows.first);
    });
  }

  /// Auto-purge synced rows older than the retention window.
  Future<int> purgeSyncedOlderThan(Duration retention) {
    return _guard(() async {
      final cutoff =
          DateTime.now().subtract(retention).millisecondsSinceEpoch;
      final n = await _db.delete(
        AppDatabase.table,
        where: 'status = ? AND synced_at IS NOT NULL AND synced_at < ?',
        whereArgs: [SmsStatus.synced.value, cutoff],
      );
      if (n > 0) AppLog.i(_tag, 'Purged $n synced rows older than ${retention.inDays}d');
      return n;
    });
  }

  /// "Clear synced logs" from settings.
  Future<int> deleteSynced() {
    return _guard(() async {
      return _db.delete(
        AppDatabase.table,
        where: 'status = ?',
        whereArgs: [SmsStatus.synced.value],
      );
    });
  }

  // ----- meta KV (runtime status shared across isolates) -----

  Future<void> setMeta(String key, String value) {
    return _guard(() async {
      await _db.insert(
        AppDatabase.metaTable,
        {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  Future<String?> getMeta(String key) {
    return _guard(() async {
      final rows = await _db.query(
        AppDatabase.metaTable,
        where: 'key = ?',
        whereArgs: [key],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      return rows.first['value'] as String?;
    });
  }

  static String _short(String s) => s.length <= 8 ? s : s.substring(0, 8);
}

/// Keys for the meta KV table.
class MetaKeys {
  MetaKeys._();
  static const lastHeartbeatAt = 'last_heartbeat_at';
  static const lastHeartbeatOk = 'last_heartbeat_ok';
  static const lastSyncAt = 'last_sync_at';

  /// High-water mark (epoch ms) of the newest inbox message the device-inbox
  /// backfill has already scanned, so subsequent scans only look at newer SMS.
  static const lastInboxScanAt = 'last_inbox_scan_at';
}
