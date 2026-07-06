import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants.dart';
import '../data/sms_message.dart';
import '../data/sms_repository.dart';
import '../services/native_bridge.dart';
import 'providers.dart';

/// Everything the dashboard renders in one immutable snapshot.
class DashboardData {
  final ServiceStatus serviceStatus;
  final bool batteryOptimizationIgnored;
  final QueueCounts counts;
  final SmsRecord? lastReceived;
  final String connectivity;
  final DateTime? lastHeartbeatAt;
  final bool lastHeartbeatOk;
  final DateTime? lastSyncAt;
  final bool configComplete;

  const DashboardData({
    required this.serviceStatus,
    required this.batteryOptimizationIgnored,
    required this.counts,
    required this.lastReceived,
    required this.connectivity,
    required this.lastHeartbeatAt,
    required this.lastHeartbeatOk,
    required this.lastSyncAt,
    required this.configComplete,
  });
}

class DashboardController extends AsyncNotifier<DashboardData> {
  Timer? _timer;

  @override
  Future<DashboardData> build() async {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _refreshSilently());
    ref.onDispose(() => _timer?.cancel());
    return _gather();
  }

  Future<DashboardData> _gather() async {
    final native = ref.read(nativeBridgeProvider);
    final repo = await ref.read(smsRepositoryProvider.future);
    final device = ref.read(deviceStatusProvider);
    final cfg = await ref.read(configControllerProvider.future);

    final serviceStatus = await native.serviceStatus();
    final batteryOk = await native.isIgnoringBatteryOptimizations();
    final counts = await repo.counts(K.maxRetries);
    final last = await repo.lastReceived();
    final conn = await device.connectivityLabel();

    final hbAtRaw = await repo.getMeta(MetaKeys.lastHeartbeatAt);
    final hbOkRaw = await repo.getMeta(MetaKeys.lastHeartbeatOk);
    final syncAtRaw = await repo.getMeta(MetaKeys.lastSyncAt);

    return DashboardData(
      serviceStatus: serviceStatus,
      batteryOptimizationIgnored: batteryOk,
      counts: counts,
      lastReceived: last,
      connectivity: conn,
      lastHeartbeatAt: _toDate(hbAtRaw),
      lastHeartbeatOk: hbOkRaw == 'true',
      lastSyncAt: _toDate(syncAtRaw),
      configComplete: cfg.isComplete,
    );
  }

  Future<void> refresh() async {
    state = await AsyncValue.guard(_gather);
  }

  Future<void> _refreshSilently() async {
    final v = await AsyncValue.guard(_gather);
    state = v;
  }

  static DateTime? _toDate(String? ms) {
    if (ms == null) return null;
    final v = int.tryParse(ms);
    if (v == null || v == 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(v);
  }
}

final dashboardControllerProvider =
    AsyncNotifierProvider<DashboardController, DashboardData>(DashboardController.new);

/// Recent allowlisted messages for the log screen.
class LogsController extends AsyncNotifier<List<SmsRecord>> {
  @override
  Future<List<SmsRecord>> build() async {
    final repo = await ref.read(smsRepositoryProvider.future);
    return repo.recent(limit: 200);
  }

  Future<void> refresh() async {
    state = await AsyncValue.guard(() async {
      final repo = await ref.read(smsRepositoryProvider.future);
      return repo.recent(limit: 200);
    });
  }

  Future<void> retry(int id) async {
    final repo = await ref.read(smsRepositoryProvider.future);
    await repo.resetForRetry(id);
    // Kick an immediate sweep.
    final sync = await ref.read(uiSyncServiceProvider.future);
    await sync.sweep();
    await refresh();
  }
}

final logsControllerProvider =
    AsyncNotifierProvider<LogsController, List<SmsRecord>>(LogsController.new);
