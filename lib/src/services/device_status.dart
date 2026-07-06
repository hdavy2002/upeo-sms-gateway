import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../core/app_log.dart';

/// Snapshot of device health used for the heartbeat + About screen.
class DeviceStatus {
  static const _tag = 'DeviceStatus';

  final Battery _battery = Battery();
  final Connectivity _connectivity = Connectivity();

  Future<int?> batteryLevel() async {
    try {
      return await _battery.batteryLevel;
    } catch (e) {
      return null;
    }
  }

  Future<bool> isCharging() async {
    try {
      final s = await _battery.batteryState;
      return s == BatteryState.charging || s == BatteryState.full;
    } catch (_) {
      return false;
    }
  }

  /// A coarse connectivity label: wifi | mobile | ethernet | none | other.
  Future<String> connectivityLabel() async {
    try {
      final results = await _connectivity.checkConnectivity();
      return _labelFor(results);
    } catch (e) {
      AppLog.w(_tag, 'connectivity check failed: $e');
      return 'unknown';
    }
  }

  static String _labelFor(List<ConnectivityResult> results) {
    if (results.contains(ConnectivityResult.wifi)) return 'wifi';
    if (results.contains(ConnectivityResult.mobile)) return 'mobile';
    if (results.contains(ConnectivityResult.ethernet)) return 'ethernet';
    if (results.isEmpty || results.every((r) => r == ConnectivityResult.none)) {
      return 'none';
    }
    return 'other';
  }

  Future<bool> hasConnectivity() async {
    final label = await connectivityLabel();
    return label != 'none' && label != 'unknown';
  }

  Future<String> appVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return '${info.version}+${info.buildNumber}';
    } catch (e) {
      return 'unknown';
    }
  }
}
