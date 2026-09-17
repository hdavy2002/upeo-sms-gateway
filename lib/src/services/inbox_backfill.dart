import 'dart:convert';

/// Date + provider row id is stable even when hundreds of messages share a date.
class InboxCheckpoint {
  final int afterDate, afterId, upperDate;
  const InboxCheckpoint(this.afterDate, this.afterId, this.upperDate);
  String encode() => jsonEncode([afterDate, afterId, upperDate]);
  factory InboxCheckpoint.decode(String value) {
    final v = jsonDecode(value) as List;
    return InboxCheckpoint(v[0] as int, v[1] as int, v[2] as int);
  }
}

typedef InboxReader = Future<List<Map<String, dynamic>>> Function(
    int afterDate, int afterId, int upperDate, int limit);

abstract class InboxStore {
  Future<bool> acquireInboxLease(String owner, int now);
  Future<InboxCheckpoint?> inboxCheckpoint();
  Future<int?> inboxCompletedAt();
  /// Rows and cursor commit in one transaction, guarded by the current lease.
  Future<void> commitInboxPage(String owner, List<Map<String, dynamic>> rows,
      InboxCheckpoint checkpoint, bool completed, int now);
  Future<void> releaseInboxLease(String owner);
}

class InboxBackfill {
  final InboxStore store;
  final InboxReader reader;
  final int Function() now;
  final String owner;
  final int pageSize, initialLookbackMs, overlapMs, maxPages;
  InboxBackfill({required this.store, required this.reader, required this.now,
    required this.owner, this.pageSize = 200, this.maxPages = 5,
    this.initialLookbackMs = 172800000, this.overlapMs = 600000});

  Future<void> drain() async {
    if (!await store.acquireInboxLease(owner, now())) return;
    try {
      var cursor = await store.inboxCheckpoint();
      if (cursor == null) {
        final upper = now();
        final last = await store.inboxCompletedAt();
        // Never apply a sliding lookback to an existing watermark: a long
        // offline interval is still drained, regardless of its age.
        final floor = last == null ? upper - initialLookbackMs : last - overlapMs;
        cursor = InboxCheckpoint(floor < 0 ? 0 : floor, -1, upper);
        await store.commitInboxPage(owner, [], cursor, false, now());
      }
      for (var page = 0; page < maxPages; page++) {
        final rows = await reader(cursor.afterDate, cursor.afterId,
            cursor.upperDate, pageSize).timeout(const Duration(seconds: 20));
        if (rows.length > pageSize) throw StateError('Oversized inbox page');
        var date = cursor.afterDate, id = cursor.afterId;
        for (final row in rows) {
          final nextDate = (row['date'] as num).toInt();
          final nextId = (row['id'] as num).toInt();
          if (nextDate > cursor.upperDate || nextDate < date ||
              (nextDate == date && nextId <= id)) {
            throw StateError('Inbox page is not ordered within its window');
          }
          date = nextDate; id = nextId;
        }
        final next = InboxCheckpoint(date, id, cursor.upperDate);
        // Empty page proves drainage. A short page alone is not trusted.
        final completed = rows.isEmpty;
        await store.commitInboxPage(owner, rows, next, completed, now());
        if (completed) return;
        cursor = next;
      }
    } finally {
      await store.releaseInboxLease(owner);
    }
  }
}
