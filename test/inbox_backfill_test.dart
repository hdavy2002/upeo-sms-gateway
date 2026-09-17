import 'package:flutter_test/flutter_test.dart';
import 'package:upeo_sms_gateway/src/services/inbox_backfill.dart';

class MemoryStore implements InboxStore {
  String? lease;
  InboxCheckpoint? checkpoint;
  int? completed;
  final ids = <int>{};
  bool failCommit = false;
  @override Future<bool> acquireInboxLease(String owner, int now) async {
    if (lease != null) return false;
    lease = owner; return true;
  }
  @override Future<InboxCheckpoint?> inboxCheckpoint() async => checkpoint;
  @override Future<int?> inboxCompletedAt() async => completed;
  @override Future<void> commitInboxPage(String owner, List<Map<String, dynamic>> rows,
      InboxCheckpoint next, bool done, int now) async {
    if (lease != owner || failCommit) throw StateError('commit failed');
    ids.addAll(rows.map((r) => r['id'] as int));
    checkpoint = done ? null : next;
    if (done) completed = next.upperDate;
  }
  @override Future<void> releaseInboxLease(String owner) async {
    if (lease == owner) lease = null;
  }
}

void main() {
  test('501 equal-date messages drain in bounded resumable pages without omission', () async {
    final store = MemoryStore();
    final rows = List.generate(501, (id) => <String,dynamic>{'id': id, 'date': 500});
    Future<List<Map<String,dynamic>>> read(int date, int id, int upper, int limit) async =>
      rows.where((r) => (r['date'] as int) <= upper &&
        ((r['date'] as int) > date || (r['date'] == date && (r['id'] as int) > id)))
        .take(limit).toList();
    InboxBackfill runner() => InboxBackfill(store: store, reader: read,
      now: () => 1000, owner: 'run', pageSize: 100, maxPages: 2);
    await runner().drain();
    expect(store.ids.length, 200); expect(store.completed, isNull);
    await runner().drain();
    expect(store.ids.length, 400); expect(store.completed, isNull);
    await runner().drain();
    expect(store.ids.length, 501);
    expect(store.completed, isNull);
    expect(store.checkpoint!.afterId, 500);
    expect(store.checkpoint!.upperDate, 1000);
    await runner().drain(); // Only an empty page proves the window is complete.
    expect(store.ids.length, 501);
    expect(store.completed, 1000); expect(store.checkpoint, isNull);
    await runner().drain(); // overlap is deduplicated by persistence
    expect(store.ids.length, 501);
  });
  test('provider failure and failed commit retain last durable cursor', () async {
    final store = MemoryStore()..checkpoint = const InboxCheckpoint(50, 7, 100);
    final runner = InboxBackfill(store: store, now: () => 100, owner: 'run',
      reader: (_, _, _, _) async => throw StateError('permission denied'));
    await expectLater(runner.drain(), throwsStateError);
    expect(store.checkpoint!.afterId, 7); expect(store.completed, isNull);
    store.failCommit = true;
    await expectLater(InboxBackfill(store: store, now: () => 100, owner: 'run',
      reader: (_, _, _, _) async => [{'id': 8, 'date': 50}]).drain(), throwsStateError);
    expect(store.checkpoint!.afterId, 7); expect(store.ids, isEmpty);
  });
  test('out-of-order rows cannot commit and original upper bound survives restart', () async {
    final store = MemoryStore()..checkpoint = const InboxCheckpoint(50, 7, 100);
    await expectLater(InboxBackfill(store: store, now: () => 9999, owner: 'run',
      reader: (date,id,upper,limit) async {
        expect(upper, 100); return [{'id': 8, 'date': 101}];
      }).drain(), throwsStateError);
    expect(store.checkpoint!.upperDate, 100); expect(store.ids, isEmpty);
  });
  test('long offline backlog starts at durable watermark, not a sliding lookback', () async {
    final store = MemoryStore()..completed = 1000000;
    await InboxBackfill(store: store, now: () => 900000000, owner: 'run',
      reader: (date, id, upper, limit) async {
        expect(date, 400000); expect(upper, 900000000); return [];
      }).drain();
    expect(store.completed, 900000000);
  });
  test('another lease holder causes no provider access', () async {
    final store = MemoryStore()..lease = 'other';
    await InboxBackfill(store: store, now: () => 100, owner: 'run',
      reader: (_,_,_,_) async => throw StateError('must not read')).drain();
    expect(store.checkpoint, isNull);
  });
}
