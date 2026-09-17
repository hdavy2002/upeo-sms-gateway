import 'package:sqflite_sqlcipher/sqflite.dart';

import '../core/app_log.dart';
import 'database.dart';
import 'sms_message.dart';
import '../services/api_client.dart';
import '../services/inbox_backfill.dart';

/// Counts surfaced on the dashboard.
class QueueCounts {
  final int pending;
  final int synced;
  final int failed;
  final int permanentlyFailed;
  final int accepted, confirmed, review;
  const QueueCounts(this.pending, this.synced, this.failed, this.permanentlyFailed,
      {this.accepted = 0, this.confirmed = 0, this.review = 0});
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

  /// Insert a captured SMS. Hash or exact referenced-content duplicates return
  /// null, whether the provider scan or the PDU receiver arrived first.
  Future<int?> insert(SmsRecord r) {
    return _guard(() async {
      try {
        return await _db.transaction((txn) async {
          if (await _hasReferencedCopy(txn, r)) return null;
          return txn.insert(AppDatabase.table, r.toMap(),
            conflictAlgorithm: ConflictAlgorithm.abort);
        });
      } on DatabaseException catch (e) {
        if (e.isUniqueConstraintError()) {
          AppLog.i(_tag, 'Duplicate SMS dropped (hash=${_short(r.messageHash)})');
          return null;
        }
        rethrow; // closed-connection errors bubble up to _guard for retry
      }
    });
  }

  /// Only exact content carrying a supported bank reference can bridge differing
  /// provider/PDU timestamps. Changed content is retained for server conflict checks.
  static Future<bool> _hasReferencedCopy(DatabaseExecutor db, SmsRecord record) async {
    if (!RegExp(
      r'(?:\(\s*UPI\s+\d{12}\s*\)|\b(?:UTR|UPI\s*(?:REF(?:ERENCE)?)|REF(?:ERENCE)?(?:\s*NO)?)\s*[:#-]?\s*\d{12}\b)',
      caseSensitive: false,
    ).hasMatch(record.message)) return false;
    final rows = await db.query(AppDatabase.table, columns: ['id'],
      where: 'sender=? AND message=? AND device_id=?',
      whereArgs: [record.sender, record.message, record.deviceId], limit: 1);
    return rows.isNotEmpty;
  }

  /// Rows due for a send attempt: pending, or failed-and-not-exhausted whose
  /// backoff window has elapsed.
  Future<List<SmsRecord>> dueForSend(int maxRetries, int limit) {
    return _guard(() async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final rows = await _db.query(
        AppDatabase.table,
        where:
            "status = ? OR (status = ? AND retry_count < ? AND next_attempt_at <= ? AND permanent_failure=0)",
        whereArgs: [SmsStatus.pending.value, SmsStatus.failed.value, maxRetries, now],
        orderBy: 'created_at ASC',
        limit: limit,
      );
      return rows.map(SmsRecord.fromMap).toList();
    });
  }

  Future<void> markAcknowledged(int id, SendResult result) => _guard(() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.transaction((txn) async {
      await txn.rawUpdate("UPDATE messages SET status='synced', synced_at=?, acknowledged_at=?, last_error=NULL, receipt_state=?, match_state=?, receipt_id=?, reason_code=?, server_time=?, permanent_failure=0 WHERE id=?",
        [now, now, result.receiptState, result.matchState, result.receiptId,
         result.reasonCode, result.serverTime, id]);
      await txn.rawUpdate('UPDATE messages SET lifetime_attempts=lifetime_attempts+1 WHERE id=?', [id]);
      await txn.insert('retry_history', {'message_id': id, 'attempted_at': now,
        'outcome': 'acknowledged', 'detail': result.detail, 'retry_count': 0});
      await txn.insert(AppDatabase.metaTable,
        {'key': MetaKeys.lastSyncAt, 'value': '$now'},
        conflictAlgorithm: ConflictAlgorithm.replace);
    });
  });

  Future<void> markFailed(int id, int retryCount, int nextAttemptAt, String error,
      {bool permanent = false}) => _guard(() async {
    await _db.transaction((txn) async {
      // A concurrent successful delivery wins over a late failed request.
      await txn.rawUpdate("UPDATE messages SET status='failed', retry_count=MAX(retry_count,?), next_attempt_at=?, last_error=?, permanent_failure=MAX(permanent_failure,?) WHERE id=? AND status!='synced'",
        [retryCount, nextAttemptAt, error, permanent ? 1 : 0, id]);
      await txn.rawUpdate('UPDATE messages SET lifetime_attempts=lifetime_attempts+1 WHERE id=?', [id]);
      await txn.insert('retry_history', {'message_id': id,
        'attempted_at': DateTime.now().millisecondsSinceEpoch,
        'outcome': permanent ? 'permanent' : 'transient', 'detail': error,
        'retry_count': retryCount});
    });
  });

  /// Explicit retry starts a fresh budget but retains outcome and attempt history.
  Future<void> resetForRetry(int id) => _guard(() async {
    await _db.transaction((txn) async {
      final changed = await txn.rawUpdate("UPDATE messages SET status='pending', retry_count=0, next_attempt_at=0, last_error=NULL, permanent_failure=0, manual_retries=manual_retries+1 WHERE id=? AND match_state!='confirmed'", [id]);
      if (changed == 1) await txn.insert('retry_history', {'message_id': id,
        'attempted_at': DateTime.now().millisecondsSinceEpoch,
        'outcome': 'manual_reset', 'detail': 'Operator requested retry', 'retry_count': 0});
    });
  });

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
        'status = ? AND (retry_count >= ? OR permanent_failure=1)',
        [SmsStatus.failed.value, maxRetries],
      );
      return QueueCounts(pending, synced, failed, permanent,
        accepted: await count("receipt_state='accepted'", []),
        confirmed: await count("match_state='confirmed'", []),
        review: await count("status='synced' AND match_state!='confirmed'", []));
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

  /// Retention is disabled pending owner approval; transport acknowledgements
  /// and review evidence must never be erased by a convenience log purge.
  Future<int> purgeSyncedOlderThan(Duration retention) async => 0;
  Future<int> deleteSynced() async => 0;

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
  static const lastSyncAt = 'last_acknowledgement_at_v2';
  static const lastSweepAt = 'last_sweep_at';

  /// High-water mark (epoch ms) of the newest inbox message the device-inbox
  /// backfill has already scanned, so subsequent scans only look at newer SMS.
  static const lastInboxScanAt = 'last_inbox_scan_at';
}

/// The lease and checkpoint share the encrypted queue's database. Every page
/// persists eligible rows and progress atomically; a killed/replaced scanner
/// cannot advance the watermark after its lease has expired.
class RepositoryInboxStore implements InboxStore {
  final SmsRepository repo;
  final SmsRecord? Function(Map<String, dynamic>) recordFromInbox;
  RepositoryInboxStore(this.repo, this.recordFromInbox);
  static const _checkpoint = 'inbox_v2_checkpoint';
  static const _completed = 'inbox_v2_completed';
  static const _leaseMs = 120000;

  @override
  Future<bool> acquireInboxLease(String owner, int now) => repo._guard(() async {
    await repo._db.rawInsert(
      'INSERT INTO inbox_lease(id,owner,expires_at) VALUES(1,?,?) ON CONFLICT(id) DO UPDATE SET owner=excluded.owner, expires_at=excluded.expires_at WHERE inbox_lease.expires_at <= ?',
      [owner, now + _leaseMs, now]);
    // rawInsert's last id is not an affected-row count; reread ownership.
    final rows = await repo._db.query('inbox_lease', where: 'id=1 AND owner=? AND expires_at>?', whereArgs: [owner, now]);
    return rows.isNotEmpty;
  });

  @override
  Future<InboxCheckpoint?> inboxCheckpoint() async {
    final value = await repo.getMeta(_checkpoint);
    return value == null ? null : InboxCheckpoint.decode(value);
  }
  @override
  Future<int?> inboxCompletedAt() async => int.tryParse(await repo.getMeta(_completed) ?? '');

  @override
  Future<void> commitInboxPage(String owner, List<Map<String, dynamic>> rows,
      InboxCheckpoint checkpoint, bool completed, int now) => repo._guard(() async {
    final records = rows.map(recordFromInbox).whereType<SmsRecord>().toList();
    await repo._db.transaction((txn) async {
      final held = await txn.rawUpdate('UPDATE inbox_lease SET expires_at=? WHERE id=1 AND owner=? AND expires_at>?', [now + _leaseMs, owner, now]);
      if (held != 1) throw StateError('Inbox scanner lease lost; page retained');
      for (final record in records) {
        // PDU and inbox timestamps can differ. Preserve content dedup for
        // reference-bearing alerts, within the same transaction as the cursor.
        // Reference-less equal credits are distinct uncertain evidence.
        if (await SmsRepository._hasReferencedCopy(txn, record)) continue;
        final existingHash = await txn.query(AppDatabase.table, columns: ['id'],
          where: 'message_hash=?', whereArgs: [record.messageHash], limit: 1);
        if (existingHash.isNotEmpty) continue;
        await txn.insert(AppDatabase.table, record.toMap(), conflictAlgorithm: ConflictAlgorithm.abort);
      }
      if (completed) {
        await txn.delete(AppDatabase.metaTable, where: 'key=?', whereArgs: [_checkpoint]);
        await txn.insert(AppDatabase.metaTable, {'key': _completed, 'value': '${checkpoint.upperDate}'}, conflictAlgorithm: ConflictAlgorithm.replace);
      } else {
        await txn.insert(AppDatabase.metaTable, {'key': _checkpoint, 'value': checkpoint.encode()}, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  });

  @override
  Future<void> releaseInboxLease(String owner) => repo._guard(() async {
    await repo._db.delete('inbox_lease', where: 'id=1 AND owner=?', whereArgs: [owner]);
  });
}
