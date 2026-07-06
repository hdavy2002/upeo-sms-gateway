import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/app_config.dart';
import '../config/config_repository.dart';
import '../data/database.dart';
import '../data/sms_repository.dart';
import '../services/device_status.dart';
import '../services/native_bridge.dart';
import '../services/sync_service.dart';

// ----- Singletons -----

final configRepositoryProvider = Provider<ConfigRepository>((ref) {
  return ConfigRepository();
});

final nativeBridgeProvider = Provider<NativeBridge>((ref) => NativeBridge());

final deviceStatusProvider = Provider<DeviceStatus>((ref) => DeviceStatus());

// ----- Database / repository (UI isolate connection) -----

final appDatabaseProvider = FutureProvider<AppDatabase>((ref) async {
  // NOTE: deliberately NOT closing on dispose. sqflite shares one native handle
  // per path across every isolate, so closing here would close it for the
  // always-on background service too (the cause of the `database_closed` error).
  // The OS reaps the connection when the process dies.
  return AppDatabase.open(config: ref.read(configRepositoryProvider));
});

final smsRepositoryProvider = FutureProvider<SmsRepository>((ref) async {
  final db = await ref.watch(appDatabaseProvider.future);
  return SmsRepository(db);
});

// ----- Config (editable) -----

class ConfigController extends AsyncNotifier<AppConfig> {
  @override
  Future<AppConfig> build() async {
    return ref.read(configRepositoryProvider).load();
  }

  Future<void> save(AppConfig cfg) async {
    await ref.read(configRepositoryProvider).save(cfg);
    state = AsyncData(cfg);
  }
}

final configControllerProvider =
    AsyncNotifierProvider<ConfigController, AppConfig>(ConfigController.new);

// ----- SyncService for the UI isolate (manual sync / test connection) -----

final uiSyncServiceProvider = FutureProvider<SyncService>((ref) async {
  final repo = await ref.watch(smsRepositoryProvider.future);
  final cfg = await ref.watch(configControllerProvider.future);
  return SyncService(
    repo: repo,
    config: cfg,
    deviceStatus: ref.read(deviceStatusProvider),
  );
});
