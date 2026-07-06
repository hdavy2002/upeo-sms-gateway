import 'package:flutter/services.dart';

import '../core/app_log.dart';
import '../core/constants.dart';

/// Status of the native foreground service.
class ServiceStatus {
  final bool isRunning;
  final DateTime? lastAlive;
  const ServiceStatus(this.isRunning, this.lastAlive);

  /// The watchdog verdict: running AND a recent alive-tick.
  bool get healthy {
    if (!isRunning) return false;
    final la = lastAlive;
    if (la == null) return false;
    return DateTime.now().difference(la) <= K.watchdogStaleAfter;
  }
}

/// Thin wrapper over the `upeo/native` MethodChannel (handled by MainActivity).
class NativeBridge {
  static const MethodChannel _ch = MethodChannel(K.nativeChannel);
  static const _tag = 'NativeBridge';

  Future<T?> _invoke<T>(String method, [dynamic args]) async {
    try {
      return await _ch.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      AppLog.w(_tag, '$method failed: ${e.message}');
      return null;
    } on MissingPluginException {
      // Happens when called from an isolate that does not have MainActivity
      // (e.g. WorkManager). Callers handle null gracefully.
      return null;
    }
  }

  Future<void> startService() => _invoke('startService');
  Future<void> stopService() => _invoke('stopService');
  Future<bool> isServiceRunning() async => (await _invoke<bool>('isServiceRunning')) ?? false;

  Future<ServiceStatus> serviceStatus() async {
    final m = await _invoke<Map>('getServiceStatus');
    if (m == null) return const ServiceStatus(false, null);
    final running = (m['isRunning'] as bool?) ?? false;
    final ms = (m['lastAliveMillis'] as int?) ?? 0;
    return ServiceStatus(
      running,
      ms > 0 ? DateTime.fromMillisecondsSinceEpoch(ms) : null,
    );
  }

  Future<bool> isIgnoringBatteryOptimizations() async =>
      (await _invoke<bool>('isIgnoringBatteryOptimizations')) ?? false;
  Future<void> requestIgnoreBatteryOptimizations() =>
      _invoke('requestIgnoreBatteryOptimizations');
  Future<void> openBatteryOptimizationSettings() =>
      _invoke('openBatteryOptimizationSettings');

  Future<String> manufacturer() async => (await _invoke<String>('getManufacturer')) ?? '';
  Future<void> openAutostartSettings() => _invoke('openAutostartSettings');
  Future<void> openAppDetailsSettings() => _invoke('openAppDetailsSettings');
  Future<void> openNotificationSettings() => _invoke('openNotificationSettings');

  Future<Map<String, dynamic>> deviceInfo() async {
    final m = await _invoke<Map>('getDeviceInfo');
    return (m ?? {}).map((k, v) => MapEntry(k.toString(), v));
  }

  /// Read the device SMS inbox (UI isolate; backed by MainActivity). Returns
  /// `{sender, body, date, subId}` maps for messages newer than [sinceMillis].
  Future<List<Map<String, dynamic>>> readInbox(int sinceMillis, int limit) async {
    final list = await _invoke<List>('readInbox', {
      'sinceMillis': sinceMillis,
      'limit': limit,
    });
    if (list == null) return [];
    return list
        .map((e) => (e as Map).map((k, v) => MapEntry(k.toString(), v)))
        .toList();
  }

  Future<List<Map<String, dynamic>>> simInfo() async {
    final list = await _invoke<List>('getSimInfo');
    if (list == null) return [];
    return list
        .map((e) => (e as Map).map((k, v) => MapEntry(k.toString(), v)))
        .toList();
  }
}
