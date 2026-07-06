import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../services/permissions_service.dart';
import '../../state/dashboard_controller.dart';
import '../../state/providers.dart';

/// Per-OEM autostart guidance shown next to the deep-link button.
String _oemGuidance(String manufacturer) {
  final m = manufacturer.toLowerCase();
  if (m.contains('xiaomi') || m.contains('redmi') || m.contains('poco')) {
    return 'MIUI: Security → Permissions → Autostart → enable UPEO SMS Gateway. '
        'Also Settings → Apps → UPEO SMS Gateway → Battery saver → No restrictions.';
  }
  if (m.contains('oppo') || m.contains('realme')) {
    return 'ColorOS: Settings → Battery → App battery management → UPEO SMS Gateway → '
        'allow background + auto-launch.';
  }
  if (m.contains('vivo') || m.contains('iqoo')) {
    return 'Funtouch/OriginOS: Settings → Battery → High background power '
        'consumption → allow UPEO SMS Gateway; enable Auto-start.';
  }
  if (m.contains('huawei') || m.contains('honor')) {
    return 'EMUI: Settings → Apps → UPEO SMS Gateway → Power usage details → enable '
        '"Manage manually" (Auto-launch, Secondary launch, Run in background).';
  }
  if (m.contains('samsung')) {
    return 'One UI: Settings → Apps → UPEO SMS Gateway → Battery → Unrestricted; and remove '
        'UPEO SMS Gateway from "Sleeping apps"/"Deep sleeping apps".';
  }
  if (m.contains('tecno') || m.contains('infinix') || m.contains('transsion') ||
      m.contains('itel')) {
    return 'HiOS/XOS: Phone Master → App freezer/Power → exclude UPEO SMS Gateway; '
        'Settings → Apps → UPEO SMS Gateway → allow Autostart & background activity.';
  }
  return 'Open your phone settings → Apps → UPEO SMS Gateway and allow Autostart and '
      'unrestricted background activity.';
}

class ReliabilityScreen extends ConsumerStatefulWidget {
  const ReliabilityScreen({super.key});
  @override
  ConsumerState<ReliabilityScreen> createState() => _ReliabilityScreenState();
}

class _ReliabilityScreenState extends ConsumerState<ReliabilityScreen> {
  final _perms = PermissionsService();
  String _manufacturer = '';
  bool _batteryIgnored = false;
  Map<Permission, bool> _permStatus = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final native = ref.read(nativeBridgeProvider);
    final mfr = await native.manufacturer();
    final batt = await native.isIgnoringBatteryOptimizations();
    final perms = <Permission, bool>{};
    for (final p in PermissionsService.required) {
      perms[p] = await p.isGranted;
    }
    if (!mounted) return;
    setState(() {
      _manufacturer = mfr;
      _batteryIgnored = batt;
      _permStatus = perms;
    });
  }

  @override
  Widget build(BuildContext context) {
    final native = ref.read(nativeBridgeProvider);
    final dash = ref.watch(dashboardControllerProvider);
    final healthy = dash.asData?.value.serviceStatus.healthy ?? false;
    final running = dash.asData?.value.serviceStatus.isRunning ?? false;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Reliability'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: (running ? (healthy ? Colors.green : Colors.orange) : Colors.red)
                .withValues(alpha: 0.12),
            child: ListTile(
              leading: Icon(running ? Icons.shield : Icons.gpp_bad,
                  color: running ? (healthy ? Colors.green : Colors.orange) : Colors.red),
              title: Text(running
                  ? (healthy ? 'Service healthy' : 'Service running but heartbeat stale')
                  : 'Foreground service NOT running'),
              subtitle: const Text(
                  'If the service keeps dying, the steps below stop the OEM '
                  'battery manager from killing it.'),
            ),
          ),
          const SizedBox(height: 8),
          _section('1. Permissions'),
          ..._permStatus.entries.map((e) => ListTile(
                leading: Icon(e.value ? Icons.check_circle : Icons.cancel,
                    color: e.value ? Colors.green : Colors.red),
                title: Text(_permLabel(e.key)),
                trailing: e.value
                    ? const Text('Granted')
                    : TextButton(
                        onPressed: () async {
                          await _perms.request(e.key);
                          _load();
                        },
                        child: const Text('Grant'),
                      ),
              )),
          ListTile(
            leading: const Icon(Icons.settings),
            title: const Text('Open app permission settings'),
            onTap: () => _perms.openSettings(),
          ),
          const SizedBox(height: 8),
          _section('2. Battery optimization'),
          ListTile(
            leading: Icon(_batteryIgnored ? Icons.check_circle : Icons.battery_alert,
                color: _batteryIgnored ? Colors.green : Colors.orange),
            title: Text(_batteryIgnored
                ? 'Exempt from battery optimization'
                : 'Battery optimization is ON (risky)'),
            subtitle: const Text('Exempt UPEO SMS Gateway so Doze cannot freeze the gateway.'),
            trailing: _batteryIgnored
                ? null
                : FilledButton(
                    onPressed: () async {
                      await native.requestIgnoreBatteryOptimizations();
                      await Future.delayed(const Duration(seconds: 1));
                      _load();
                    },
                    child: const Text('Fix'),
                  ),
          ),
          const SizedBox(height: 8),
          _section('3. Autostart / protected apps${_manufacturer.isEmpty ? '' : ' ($_manufacturer)'}'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_oemGuidance(_manufacturer)),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton.tonalIcon(
                        icon: const Icon(Icons.open_in_new),
                        label: const Text('Open autostart settings'),
                        onPressed: () => native.openAutostartSettings(),
                      ),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.notifications),
                        label: const Text('Notification settings'),
                        onPressed: () => native.openNotificationSettings(),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 4),
        child: Text(t, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
      );

  String _permLabel(Permission p) {
    if (p == Permission.sms) return 'SMS (receive & read)';
    if (p == Permission.phone) return 'Phone state (SIM slot)';
    if (p == Permission.notification) return 'Notifications';
    return p.toString();
  }
}
