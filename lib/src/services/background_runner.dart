import 'dart:async';
import 'package:uuid/uuid.dart';

import 'package:connectivity_plus/connectivity_plus.dart';

import '../config/config_repository.dart';
import '../core/app_log.dart';
import '../core/constants.dart';
import '../data/database.dart';
import '../data/sms_repository.dart';
import 'sync_service.dart';
import 'inbox_backfill.dart';

/// Boots the data + sync stack inside a background isolate (the one hosted by
/// the Kotlin foreground service, and the one WorkManager spawns).
///
/// It deliberately rebuilds [SyncService] per operation by reloading config, so
/// the operator changing the API URL / secret in the UI takes effect on the next
/// SMS / sweep without restarting the service.
class BackgroundRunner {
  BackgroundRunner();

  final ConfigRepository _configRepo = ConfigRepository();
  AppDatabase? _db;
  SmsRepository? _repo;
  StreamSubscription? _connSub;
  Timer? _heartbeatTimer;
  Timer? _sweepTimer;
  Timer? _inboxTimer;
  bool _initialised = false;

  /// Reads the device SMS inbox via the native channel. Injected by
  /// `backgroundMain` (the foreground-service isolate). Null in isolates with no
  /// native host (e.g. WorkManager), where the inbox backfill simply no-ops.
  InboxReader? inboxReader;

  static const _tag = 'BgRunner';

  Future<SmsRepository> _repository() async {
    if (_repo != null) return _repo!;
    _db = await AppDatabase.open(config: _configRepo);
    _repo = SmsRepository(_db!);
    return _repo!;
  }

  Future<SyncService> _sync() async {
    final repo = await _repository();
    final cfg = await _configRepo.load();
    return SyncService(repo: repo, config: cfg);
  }

  /// Called once by the foreground-service isolate. Starts the periodic
  /// heartbeat + sweep timers and a connectivity-regained listener.
  Future<void> startServiceLoops() async {
    if (_initialised) return;
    _initialised = true;
    AppLog.i(_tag, 'Background service loops starting');
    await _repository();

    _heartbeatTimer = Timer.periodic(K.heartbeatInterval, (_) => _safeHeartbeat());
    // Frequent (15s) catch-up sweep for anything not yet synced. Purge runs only
    // on the occasional paths below, not every 15s.
    _sweepTimer = Timer.periodic(K.sweepInterval, (_) => _safeSweep('timer'));
    // Periodic (60s) device-inbox scan: recover any SMS the live receiver never
    // delivered (arrived while the DB was briefly closed or the service dead).
    _inboxTimer = Timer.periodic(K.inboxScanInterval, (_) => _safeBackfill('timer'));

    _connSub = Connectivity().onConnectivityChanged.listen((results) {
      final online = results.any((r) => r != ConnectivityResult.none);
      if (online) {
        AppLog.i(_tag, 'Connectivity regained — sweeping');
        _safeSweep('connectivity');
      }
    });

    // Initial catch-up.
    await _safeBackfill('startup');
    await _safeSweep('startup', purge: true);
    await _safeHeartbeat();
  }

  /// Handle one captured SMS: persist (with allowlist) then attempt an immediate
  /// send.
  Future<void> onSmsReceived(Map<dynamic, dynamic> args) async {
    try {
      final sync = await _sync();
      final id = await sync.captureIncoming(
        sender: (args['sender'] ?? '').toString(),
        body: (args['body'] ?? '').toString(),
        pduTimestampMillis: (args['timestampMillis'] as num?)?.toInt() ?? 0,
        simSlot: (args['simSlot'] as num?)?.toInt() ?? -1,
        subscriptionId: (args['subscriptionId'] as num?)?.toInt() ?? -1,
      );
      if (id != null) {
        await sync.sweep(); // immediate send path
      }
    } catch (e, st) {
      AppLog.e(_tag, 'onSmsReceived error: $e\n$st');
    }
  }

  Future<SweepResult> _safeSweep(String reason, {bool purge = false}) async {
    try {
      final sync = await _sync();
      // Retention purge is a periodic cleanup, not needed on every 15s sweep.
      if (purge) await sync.purgeRetention();
      final res = await sync.sweep();
      return res;
    } catch (e) {
      AppLog.e(_tag, 'sweep($reason) error: $e');
      return const SweepResult(0, 0, 0);
    }
  }

  /// Drain up to five ascending pages, preserving a frozen window across
  /// invocations. Only the first scan uses the initial lookback; an unfinished
  /// old window is never skipped merely because the device was offline.
  Future<void> _safeBackfill(String reason) async {
    final reader = inboxReader;
    if (reader == null) return; // no native channel in this isolate
    try {
      final repo = await _repository();
      final cfg = await _configRepo.load();
      if (!cfg.isComplete) return;

      final sync = await _sync();
      final store = RepositoryInboxStore(repo, sync.recordFromInbox);
      await InboxBackfill(store: store, reader: reader,
        owner: const Uuid().v4(), now: () => DateTime.now().millisecondsSinceEpoch,
        pageSize: K.inboxScanLimit,
        initialLookbackMs: K.inboxInitialLookback.inMilliseconds,
        overlapMs: K.inboxScanOverlap.inMilliseconds).drain();
      await sync.sweep();
    } catch (e) {
      AppLog.e(_tag, 'backfill($reason) error: $e');
    }
  }

  Future<void> _safeHeartbeat() async {
    try {
      final sync = await _sync();
      await sync.sendHeartbeat();
    } catch (e) {
      AppLog.e(_tag, 'heartbeat error: $e');
    }
  }

  /// One-shot used by the WorkManager backstop: sweep + heartbeat + purge, then
  /// tear down the DB connection.
  Future<bool> runBackstopOnce() async {
    try {
      AppLog.i(_tag, 'WorkManager backstop running');
      await _safeSweep('backstop', purge: true);
      await _safeHeartbeat();
      return true;
    } finally {
      await dispose();
    }
  }

  Future<void> sweepNow() => _safeSweep('manual').then((_) {});

  Future<void> dispose() async {
    await _connSub?.cancel();
    _heartbeatTimer?.cancel();
    _sweepTimer?.cancel();
    _inboxTimer?.cancel();
    // Deliberately do NOT close the database here. sqflite shares one native
    // handle per path across every isolate, so closing it (e.g. from the
    // WorkManager backstop's teardown) would close it for the always-on service
    // and the UI too — the root cause of the `database_closed` failures. The OS
    // reclaims the handle when the process exits.
    _db = null;
    _repo = null;
    _initialised = false;
  }
}
