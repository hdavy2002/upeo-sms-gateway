import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/core/app_log.dart';
import 'src/core/constants.dart';
import 'src/services/background_runner.dart';
import 'src/services/native_bridge.dart';
import 'src/services/workmanager_backstop.dart';
import 'src/ui/app.dart';

/// UI entrypoint (the normal app process).
void main() {
  runApp(const ProviderScope(child: _Bootstrap(child: UpeoApp())));
}

/// Performs one-time startup side effects (schedule the WorkManager backstop,
/// ensure the foreground service is running) without blocking first paint.
class _Bootstrap extends StatefulWidget {
  const _Bootstrap({required this.child});
  final Widget child;
  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startup());
  }

  Future<void> _startup() async {
    // Schedule the ~15-minute periodic backstop sweep.
    await const WorkmanagerBackstop().initAndSchedule();
    // Ensure the gateway service is running (also recovers after a force-stop,
    // the only time the user reopens the app). Harmless if already running.
    try {
      await NativeBridge().startService();
    } catch (e) {
      AppLog.w('Bootstrap', 'startService failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// ===========================================================================
/// Background entrypoint hosted by the Kotlin foreground service.
///
/// Runs in its own isolate (plugins are registered natively by
/// GeneratedPluginRegistrant in SmsForegroundService). It owns the immediate
/// capture→persist→send path plus the periodic heartbeat/sweep timers.
/// ===========================================================================
@pragma('vm:entry-point')
void backgroundMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppLog.i('backgroundMain', 'Background isolate starting');

  const channel = MethodChannel(K.smsEventsChannel);
  final runner = BackgroundRunner();

  // Let the runner read the device SMS inbox (native, via the service engine)
  // so it can backfill any allowlisted SMS the live receiver never delivered.
  runner.inboxReader = (sinceMillis, limit) async {
    final res = await channel.invokeMethod(
      'readInbox',
      {'sinceMillis': sinceMillis, 'limit': limit},
    );
    if (res is List) {
      return res
          .map((e) => (e as Map).map((k, v) => MapEntry(k.toString(), v)))
          .cast<Map<String, dynamic>>()
          .toList();
    }
    return <Map<String, dynamic>>[];
  };

  channel.setMethodCallHandler((call) async {
    switch (call.method) {
      case 'onSmsReceived':
        await runner.onSmsReceived(
          Map<dynamic, dynamic>.from(call.arguments as Map),
        );
        break;
      case 'onSweep':
        await runner.sweepNow();
        break;
    }
    return null;
  });

  // Tell the service we are ready so it flushes any SMS queued during warm-up.
  try {
    await channel.invokeMethod('backgroundReady');
  } catch (e) {
    AppLog.w('backgroundMain', 'backgroundReady failed: $e');
  }

  // Start periodic heartbeat + sweep + connectivity listener and do a catch-up.
  await runner.startServiceLoops();
}
