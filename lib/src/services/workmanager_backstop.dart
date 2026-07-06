import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import '../core/app_log.dart';
import '../core/constants.dart';
import 'background_runner.dart';

/// WorkManager entrypoint. Runs in its own isolate, so it must initialise plugin
/// registration itself.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    AppLog.i('Backstop', 'Task fired: $task');
    final runner = BackgroundRunner();
    return runner.runBackstopOnce();
  });
}

/// The periodic backstop: a ~15-minute (platform minimum) sweep that catches
/// anything the immediate, foreground-service-driven path missed.
class WorkmanagerBackstop {
  const WorkmanagerBackstop();

  Future<void> initAndSchedule() async {
    try {
      await Workmanager().initialize(callbackDispatcher);
      await Workmanager().registerPeriodicTask(
        K.backstopUniqueName,
        K.backstopTaskName,
        frequency: const Duration(minutes: 15),
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
        backoffPolicy: BackoffPolicy.linear,
      );
      AppLog.i('Backstop', 'Periodic backstop scheduled');
    } catch (e) {
      AppLog.w('Backstop', 'Failed to schedule backstop: $e');
    }
  }

  Future<void> cancel() async {
    try {
      await Workmanager().cancelByUniqueName(K.backstopUniqueName);
    } catch (_) {}
  }
}
