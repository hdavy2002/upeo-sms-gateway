import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/constants.dart';
import '../../services/permissions_service.dart';
import '../../state/providers.dart';

class AboutScreen extends ConsumerStatefulWidget {
  const AboutScreen({super.key});
  @override
  ConsumerState<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends ConsumerState<AboutScreen> {
  Map<String, dynamic> _device = {};
  List<Map<String, dynamic>> _sims = [];
  String _version = '';
  bool _serviceRunning = false;
  bool _batteryOk = false;
  Map<String, bool> _perms = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final native = ref.read(nativeBridgeProvider);
    final info = await PackageInfo.fromPlatform();
    final device = await native.deviceInfo();
    final sims = await native.simInfo();
    final running = await native.isServiceRunning();
    final battery = await native.isIgnoringBatteryOptimizations();
    final perms = <String, bool>{};
    for (final p in PermissionsService.required) {
      perms[_permLabel(p)] = await p.isGranted;
    }
    if (!mounted) return;
    setState(() {
      _version = '${info.version}+${info.buildNumber}';
      _device = device;
      _sims = sims;
      _serviceRunning = running;
      _batteryOk = battery;
      _perms = perms;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('About'),
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load)],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const ListTile(
            leading: Icon(Icons.sms, size: 40),
            title: Text(K.appName,
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            subtitle: Text('HDFC payment SMS · production · sideload only'),
          ),
          _card('App', [
            _kv('Version', _version),
            _kv('Source revision', K.releaseSha),
            _kv('Package', K.applicationId),
          ]),
          _card('Device', [
            _kv('Manufacturer', '${_device['manufacturer'] ?? ''}'),
            _kv('Brand', '${_device['brand'] ?? ''}'),
            _kv('Model', '${_device['model'] ?? ''}'),
            _kv('Android', '${_device['androidRelease'] ?? ''} (SDK ${_device['sdkInt'] ?? '?'})'),
          ]),
          _card('SIM / subscriptions', [
            if (_sims.isEmpty) _kv('SIMs', 'none detected (or permission denied)'),
            for (final s in _sims)
              _kv('Slot ${s['simSlot']}',
                  '${s['carrier'] ?? ''} (subId ${s['subscriptionId']})'),
          ]),
          _card('Self-check', [
            _check('Foreground service running', _serviceRunning),
            _check('Battery optimization exempt', _batteryOk),
            for (final e in _perms.entries) _check(e.key, e.value),
          ]),
          const SizedBox(height: 16),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Privacy: only HDFC payment alerts matching the sender allowlist '
                'and configured account suffix are stored '
                '(encrypted at rest) and forwarded over HTTPS with an HMAC '
                'signature. Non-allowlisted messages are never stored or sent. '
                'Destination: AvaTOK production only. Based on Upeo SMS Gateway.',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(String title, List<Widget> children) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              ...children,
            ],
          ),
        ),
      );

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(k, style: const TextStyle(color: Colors.grey)),
            Flexible(child: Text(v, textAlign: TextAlign.right)),
          ],
        ),
      );

  Widget _check(String label, bool ok) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Icon(ok ? Icons.check_circle : Icons.cancel,
                size: 18, color: ok ? Colors.green : Colors.red),
            const SizedBox(width: 8),
            Expanded(child: Text(label)),
          ],
        ),
      );

  String _permLabel(Permission p) {
    if (p == Permission.sms) return 'SMS permission';
    if (p == Permission.phone) return 'Phone-state permission';
    if (p == Permission.notification) return 'Notification permission';
    return p.toString();
  }
}
