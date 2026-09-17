import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:upeo_sms_gateway/src/data/database.dart';
import 'package:upeo_sms_gateway/src/data/sms_repository.dart';
import 'package:upeo_sms_gateway/src/data/sms_message.dart';
import 'package:upeo_sms_gateway/src/services/api_client.dart';
import 'package:upeo_sms_gateway/src/services/inbox_backfill.dart';
import 'fixtures.dart';

void main() {
  late Database db;
  late SmsRepository repo;
  setUpAll(sqfliteFfiInit);
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    // Actual v1 schema, seeded before executing the production migration.
    await db.execute('CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, sender TEXT NOT NULL, message TEXT NOT NULL, received_at TEXT NOT NULL, sim_slot INTEGER, subscription_id INTEGER, device_id TEXT NOT NULL, status TEXT NOT NULL, retry_count INTEGER NOT NULL DEFAULT 0, last_error TEXT, next_attempt_at INTEGER NOT NULL DEFAULT 0, message_hash TEXT NOT NULL, created_at INTEGER NOT NULL, synced_at INTEGER)');
    await db.execute('CREATE UNIQUE INDEX idx_messages_hash ON messages(message_hash)');
    await db.execute('CREATE TABLE meta (key TEXT PRIMARY KEY,value TEXT)');
    final legacy = paymentRecord().toMap()..removeWhere((key, value) => const {
      'receipt_state','match_state','receipt_id','reason_code','acknowledged_at',
      'server_time','lifetime_attempts','manual_retries','permanent_failure',
    }.contains(key));
    legacy['retry_count'] = 8; legacy['status'] = 'failed';
    await db.insert('messages', legacy);
    await db.insert('meta', {'key': 'last_inbox_scan_at', 'value': '42'});
    await db.transaction((txn) => AppDatabase.migrateV2(txn));
    repo = SmsRepository(AppDatabase.forTesting(db));
  });
  tearDown(() async => db.close());

  test('legacy acknowledged rows remain unknown and failed migration rolls back', () async {
    final legacyDb = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false));
    try {
      await legacyDb.execute('CREATE TABLE messages (id INTEGER PRIMARY KEY, status TEXT, retry_count INTEGER, synced_at INTEGER)');
      await legacyDb.insert('messages', {'id': 7, 'status': 'synced', 'retry_count': 2, 'synced_at': 123});
      // Force failure after ALTER statements; the real transaction must undo them.
      await legacyDb.execute('CREATE TABLE retry_history (id INTEGER)');
      await expectLater(legacyDb.transaction((txn) => AppDatabase.migrateV2(txn)),
        throwsA(isA<DatabaseException>()));
      final columns = await legacyDb.rawQuery('PRAGMA table_info(messages)');
      expect(columns.map((r) => r['name']), isNot(contains('receipt_state')));
      expect((await legacyDb.query('messages')).single['synced_at'], 123);
      await legacyDb.execute('DROP TABLE retry_history');
      await legacyDb.transaction((txn) => AppDatabase.migrateV2(txn));
      final row = (await legacyDb.query('messages')).single;
      expect(row['reason_code'], 'acknowledged_legacy');
      expect(row['receipt_state'], 'unknown'); expect(row['match_state'], 'unknown');
      expect(row['acknowledged_at'], 123); expect(row['lifetime_attempts'], 3);
    } finally { await legacyDb.close(); }
  });

  test('v1 queue and unknown historical outcomes survive additive upgrade', () async {
    final row = (await repo.recent()).single;
    expect(row.message, paymentBody); expect(row.retryCount, 8);
    expect(row.messageHash, paymentRecord().messageHash);
    expect(row.receiptState, 'unknown'); expect(row.matchState, 'unknown');
    expect(row.lifetimeAttempts, 8);
    expect(await repo.getMeta('last_inbox_scan_at'), '42');
    expect(await repo.purgeSyncedOlderThan(Duration.zero), 0);
  });
  test('manual retry restores budget and preserves durable failure history', () async {
    await repo.markFailed(1, 8, 9999999999999, 'HTTP 401', permanent: true);
    expect(await repo.dueForSend(8, 10), isEmpty);
    await repo.resetForRetry(1);
    final row = (await repo.dueForSend(8, 10)).single;
    expect(row.retryCount, 0); expect(row.manualRetries, 1);
    expect(row.lifetimeAttempts, 9); expect(row.permanentFailure, false);
    final history = await db.query('retry_history', orderBy: 'id');
    expect(history.map((r) => r['outcome']), ['permanent', 'manual_reset']);
  });
  test('late transient failure cannot restart a permanently stopped row', () async {
    await repo.resetForRetry(1);
    await repo.markFailed(1, 1, 0, 'HTTP 401', permanent: true);
    await repo.markFailed(1, 1, 0, 'late timeout');
    expect(await repo.dueForSend(8, 10), isEmpty);
    expect((await repo.recent()).single.permanentFailure, isTrue);
    expect((await repo.recent()).single.lifetimeAttempts, 10);
  });
  test('review acknowledgement records transport only and survives all purge paths', () async {
    await repo.markAcknowledged(1, const SendResult(SendOutcome.success, 'acknowledged',
      receiptState: 'review_pending', matchState: 'unmatched', reasonCode: 'missing_reference'));
    final row = (await repo.recent()).single;
    expect(row.matchState, 'unmatched'); expect(row.receiptState, 'review_pending');
    expect(await repo.getMeta(MetaKeys.lastSyncAt), isNotNull);
    expect(await repo.deleteSynced(), 0);
    expect(await repo.purgeSyncedOlderThan(Duration.zero), 0);
    expect((await repo.recent()).length, 1);
    await repo.markFailed(1, 9, 0, 'late network error');
    expect((await repo.recent()).single.receiptState, 'review_pending');
  });
  test('later conflict acknowledgement replaces an earlier confirmed snapshot', () async {
    await repo.markAcknowledged(1, const SendResult(SendOutcome.success, 'acknowledged',
      receiptState: 'accepted', matchState: 'confirmed', receiptId: 'synthetic-id'));
    expect((await repo.counts(8)).confirmed, 1);
    await repo.markAcknowledged(1, const SendResult(SendOutcome.success, 'acknowledged',
      receiptState: 'review_pending', matchState: 'unmatched',
      receiptId: 'synthetic-id', reasonCode: 'evidence_conflict'));
    expect((await repo.counts(8)).confirmed, 0);
    expect((await repo.recent()).single.acknowledgementLabel, 'Bank evidence needs review');
  });
  test('lost lease cannot insert a page or move its checkpoint', () async {
    final store = RepositoryInboxStore(repo, (_) => paymentRecord());
    expect(await store.acquireInboxLease('one', 100), true);
    expect(await store.acquireInboxLease('two', 101), false);
    await store.commitInboxPage('one', [], const InboxCheckpoint(1, -1, 500), false, 102);
    expect(await store.acquireInboxLease('two', 200000), true);
    await expectLater(store.commitInboxPage('one', [{'id': 2, 'date': 2}],
      const InboxCheckpoint(2, 2, 500), false, 200001), throwsStateError);
    expect((await store.inboxCheckpoint())!.afterDate, 1);
    expect((await repo.recent()).length, 1);
  });
  test('duplicate native/live delivery and cursor are committed together', () async {
    final store = RepositoryInboxStore(repo, (_) => paymentRecord());
    await store.acquireInboxLease('one', 100);
    await store.commitInboxPage('one', [{'id': 1, 'date': 2}],
      const InboxCheckpoint(2, 1, 500), false, 101);
    expect((await repo.recent()).length, 1);
    expect((await store.inboxCheckpoint())!.afterId, 1);
    await store.commitInboxPage('one', [], const InboxCheckpoint(2, 1, 500), true, 102);
    expect(await store.inboxCheckpoint(), isNull);
    expect(await store.inboxCompletedAt(), 500);
  });
  test('different PDU and inbox timestamps for same referenced alert deduplicate', () async {
    final providerCopy = paymentRecord().toMap()
      ..remove('id')
      ..['received_at'] = '2026-09-17T12:30:01+03:00'
      ..['message_hash'] = 'different-provider-timestamp-hash';
    final store = RepositoryInboxStore(repo, (_) => SmsRecord.fromMap(providerCopy));
    await store.acquireInboxLease('one', 100);
    await store.commitInboxPage('one', [{'id': 100, 'date': 200}],
      const InboxCheckpoint(200, 100, 500), false, 101);
    expect((await repo.recent()).length, 1);
    expect((await store.inboxCheckpoint())!.afterId, 100);
  });
  test('queue insert failure rolls back cursor and every preceding page insert', () async {
    // Fail the second real insert; the first insert and cursor must roll back.
    await db.execute("CREATE TRIGGER fail_queue BEFORE INSERT ON messages WHEN NEW.message_hash='bad' BEGIN SELECT RAISE(ABORT, 'disk write denied'); END");
    final store = RepositoryInboxStore(repo, (row) => SmsRecord.fromMap(
      paymentRecord().toMap()..remove('id')
        ..['message_hash'] = row['hash']
        ..['message'] = 'HDFC credit unique without reference'));
    await store.acquireInboxLease('one', 100);
    await expectLater(store.commitInboxPage('one', [
      {'id': 2, 'date': 2, 'hash': 'good'}, {'id': 3, 'date': 3, 'hash': 'bad'}],
      const InboxCheckpoint(3, 3, 500), false, 101), throwsA(isA<DatabaseException>()));
    expect(await store.inboxCheckpoint(), isNull);
    expect((await repo.recent()).length, 1);
  });
  test('awaiting reference is retained and displayed without confirmation', () async {
    await repo.markAcknowledged(1, const SendResult(SendOutcome.success, 'acknowledged',
      receiptState: 'accepted', matchState: 'awaiting_reference',
      receiptId: 'synthetic-id', reasonCode: 'reference_required'));
    final row = (await repo.recent()).single;
    expect(row.acknowledgementLabel, 'Bank evidence stored; reference required');
    expect((await repo.counts(8)).confirmed, 0);
    expect((await repo.counts(8)).accepted, 1);
    await repo.resetForRetry(1);
    expect((await repo.dueForSend(8, 10)).single.matchState, 'awaiting_reference');
  });

  test('only supported labelled 12-digit references enable content dedup', () async {
    for (final label in ['UTR 001234567891', 'UPI REF: 001234567892', 'REFERENCE 001234567893']) {
      final first = paymentRecord(body: 'Rs 1 credited to A/c XX1234. $label').toMap()
        ..remove('id');
      expect(await repo.insert(SmsRecord.fromMap(first)), isNotNull);
      first['message_hash'] = 'provider-$label';
      expect(await repo.insert(SmsRecord.fromMap(first)), isNull);
    }
    for (final text in ['arbitrary 001234567894', 'UTR 0012345678945', 'UTR 123456']) {
      final first = paymentRecord(body: 'Rs 1 credited to A/c XX1234. $text').toMap()
        ..remove('id');
      expect(await repo.insert(SmsRecord.fromMap(first)), isNotNull);
      first['message_hash'] = 'provider-$text';
      expect(await repo.insert(SmsRecord.fromMap(first)), isNotNull);
    }
  });

  test('provider-first then PDU deduplicates exact observed bare UPI format', () async {
    final copy = paymentRecord().toMap()..remove('id')
      ..['message_hash'] = 'later-pdu-hash'
      ..['received_at'] = '2026-09-17T12:30:02+03:00';
    expect(await repo.insert(SmsRecord.fromMap(copy)), isNull);
    expect((await repo.recent()).length, 1);
    // A changed body must reach the server for conflict handling.
    copy['message'] = paymentBody.replaceFirst('1.00', '2.00');
    expect(await repo.insert(SmsRecord.fromMap(copy)), isNotNull);
    expect((await repo.recent()).length, 2);
  });
}
