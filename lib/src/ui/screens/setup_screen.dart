import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/permissions_service.dart';
import '../../state/gateway_actions.dart';
import '../widgets/config_form.dart';

/// First-run setup: privacy notice → permissions → configuration → start.
class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({super.key});
  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends ConsumerState<SetupScreen> {
  final _perms = PermissionsService();
  bool _permsGranted = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final ok = await _perms.hasAllRequired();
    if (mounted) setState(() => _permsGranted = ok);
  }

  Future<void> _request() async {
    await _perms.requestAll();
    await _check();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Set up AvaTOK SMS · Staging')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: Colors.blue.withValues(alpha: 0.08),
            child: const Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Privacy first',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  SizedBox(height: 8),
                  Text(
                    'This device becomes a dedicated HDFC payment-SMS gateway. '
                    'Only credit/received alerts from your HDFC sender allowlist '
                    'naming your configured account suffix are stored in the '
                    'encrypted queue and forwarded to AvaTOK staging over HTTPS. '
                    'OTP and unrelated SMS are ignored. The Worker independently '
                    'validates payments; this phone does not grant wallet credit.',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: Icon(
                  _permsGranted ? Icons.check_circle : Icons.lock_open,
                  color: _permsGranted ? Colors.green : Colors.orange),
              title: Text(_permsGranted
                  ? 'Permissions granted'
                  : 'Grant SMS, phone & notification permissions'),
              subtitle: const Text(
                  'Needed to receive SMS, read the SIM slot, and keep the '
                  'foreground-service notification visible.'),
              trailing: _permsGranted
                  ? null
                  : FilledButton(onPressed: _request, child: const Text('Grant')),
            ),
          ),
          const SizedBox(height: 12),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4),
            child: Text('Backend configuration',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ),
          ConfigForm(
            onSaved: () async {
              // Start the gateway and let the shell route to the dashboard.
              await ref.read(gatewayActionsProvider).startService();
            },
          ),
        ],
      ),
    );
  }
}
