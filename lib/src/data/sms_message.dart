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
  final int? syncedAt; // legacy transport timestamp
  final String receiptState, matchState;
  final String? receiptId, reasonCode;
  final int? acknowledgedAt, serverTime;
  final int lifetimeAttempts, manualRetries;
  final bool permanentFailure;

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
    this.receiptState = 'unknown', this.matchState = 'unknown',
    this.receiptId, this.reasonCode, this.acknowledgedAt, this.serverTime,
    this.lifetimeAttempts = 0, this.manualRetries = 0,
    this.permanentFailure = false,
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
        'receipt_state': receiptState, 'match_state': matchState,
        'receipt_id': receiptId, 'reason_code': reasonCode,
        'acknowledged_at': acknowledgedAt, 'server_time': serverTime,
        'lifetime_attempts': lifetimeAttempts, 'manual_retries': manualRetries,
        'permanent_failure': permanentFailure ? 1 : 0,
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
        receiptState: m['receipt_state'] as String? ?? 'unknown',
        matchState: m['match_state'] as String? ?? 'unknown',
        receiptId: m['receipt_id'] as String?, reasonCode: m['reason_code'] as String?,
        acknowledgedAt: m['acknowledged_at'] as int?, serverTime: m['server_time'] as int?,
        lifetimeAttempts: m['lifetime_attempts'] as int? ?? 0,
        manualRetries: m['manual_retries'] as int? ?? 0,
        permanentFailure: m['permanent_failure'] == 1,
      );

  /// A snapshot from the last acknowledged send, never a live payment lookup.
  String get acknowledgementLabel {
    if (matchState == 'awaiting_reference' && receiptState == 'accepted') {
      return 'Bank evidence stored; reference required';
    }
    if (matchState == 'confirmed' && receiptState == 'accepted') {
      return 'Payment matched at last acknowledgement';
    }
    if (receiptState == 'accepted') return 'Bank evidence stored; unmatched';
    if (receiptState == 'ignored') return 'Message ignored; no payment confirmation';
    if (receiptState == 'review_pending') return 'Bank evidence needs review';
    return 'Acknowledged; payment outcome unknown';
  }

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
