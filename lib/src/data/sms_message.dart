/// Status of a queued message in its sync lifecycle.
enum SmsStatus { pending, synced, failed }

extension SmsStatusX on SmsStatus {
  String get value => name;
  static SmsStatus parse(String s) =>
      SmsStatus.values.firstWhere((e) => e.name == s, orElse: () => SmsStatus.pending);
}

/// One stored, allowlisted SMS. Mirrors the `messages` table columns.
class SmsRecord {
  final int? id;
  final String sender;
  final String message;

  /// PDU/SMSC timestamp as EAT ISO-8601 (used in the hash + signature).
  final String receivedAt;
  final int simSlot;
  final int subscriptionId;
  final String deviceId;
  final SmsStatus status;
  final int retryCount;
  final String? lastError;

  /// Epoch millis of the earliest next send attempt (backoff).
  final int nextAttemptAt;
  final String messageHash;
  final int createdAt; // epoch millis
  final int? syncedAt; // epoch millis

  const SmsRecord({
    this.id,
    required this.sender,
    required this.message,
    required this.receivedAt,
    required this.simSlot,
    required this.subscriptionId,
    required this.deviceId,
    required this.status,
    required this.retryCount,
    required this.lastError,
    required this.nextAttemptAt,
    required this.messageHash,
    required this.createdAt,
    required this.syncedAt,
  });

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'sender': sender,
        'message': message,
        'received_at': receivedAt,
        'sim_slot': simSlot,
        'subscription_id': subscriptionId,
        'device_id': deviceId,
        'status': status.value,
        'retry_count': retryCount,
        'last_error': lastError,
        'next_attempt_at': nextAttemptAt,
        'message_hash': messageHash,
        'created_at': createdAt,
        'synced_at': syncedAt,
      };

  factory SmsRecord.fromMap(Map<String, Object?> m) => SmsRecord(
        id: m['id'] as int?,
        sender: m['sender'] as String,
        message: m['message'] as String,
        receivedAt: m['received_at'] as String,
        simSlot: (m['sim_slot'] as int?) ?? -1,
        subscriptionId: (m['subscription_id'] as int?) ?? -1,
        deviceId: m['device_id'] as String,
        status: SmsStatusX.parse(m['status'] as String),
        retryCount: (m['retry_count'] as int?) ?? 0,
        lastError: m['last_error'] as String?,
        nextAttemptAt: (m['next_attempt_at'] as int?) ?? 0,
        messageHash: m['message_hash'] as String,
        createdAt: (m['created_at'] as int?) ?? 0,
        syncedAt: m['synced_at'] as int?,
      );

  DateTime get createdAtDate => DateTime.fromMillisecondsSinceEpoch(createdAt);
  DateTime? get syncedAtDate =>
      syncedAt == null ? null : DateTime.fromMillisecondsSinceEpoch(syncedAt!);

  /// Privacy-preserving preview for the UI log (never show the full body in lists).
  String get maskedPreview {
    final body = message.replaceAll('\n', ' ').trim();
    if (body.length <= 18) return body;
    return '${body.substring(0, 18)}…';
  }
}
