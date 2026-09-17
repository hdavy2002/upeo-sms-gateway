import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/dashboard_controller.dart';
import '../../state/gateway_actions.dart';
import '../format.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dataAsync = ref.watch(dashboardControllerProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () =>
                ref.read(dashboardControllerProvider.notifier).refresh(),
          ),
        ],
      ),
      body: dataAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (d) => RefreshIndicator(
          onRefresh: () =>
              ref.read(dashboardControllerProvider.notifier).refresh(),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _ServiceCard(d: d, ref: ref),
              const SizedBox(height: 12),
              if (!d.configComplete) const _ConfigWarning(),
              if (!d.batteryOptimizationIgnored) const _BatteryWarning(),
              const SizedBox(height: 4),
              _CountsRow(d: d),
              const SizedBox(height: 12),
              _InfoCard(d: d),
              const SizedBox(height: 12),
              _ActionsCard(),
            ],
          ),
        ),
      ),
    );
  }
}

class _ServiceCard extends StatelessWidget {
  const _ServiceCard({required this.d, required this.ref});
  final DashboardData d;
  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
    final s = d.serviceStatus;
    final healthy = s.healthy;
    final color = healthy
        ? Colors.green
        : (s.isRunning ? Colors.orange : Colors.red);
    final label = healthy
        ? 'Gateway ONLINE'
        : (s.isRunning ? 'Running (stale heartbeat)' : 'Gateway STOPPED');
    return Card(
      color: color.withValues(alpha: 0.1),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(healthy ? Icons.check_circle : Icons.error, color: color, size: 40),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: color)),
                  Text('Foreground service: ${s.isRunning ? "active" : "not running"}'),
                  Text('Last service tick: ${Fmt.ago(s.lastAlive)}'),
                ],
              ),
            ),
            Column(
              children: [
                FilledButton(
                  onPressed: () =>
                      ref.read(gatewayActionsProvider).startService(),
                  child: const Text('Start'),
                ),
                TextButton(
                  onPressed: () =>
                      ref.read(gatewayActionsProvider).stopService(),
                  child: const Text('Stop'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ConfigWarning extends StatelessWidget {
  const _ConfigWarning();
  @override
  Widget build(BuildContext context) => Card(
        color: Colors.amber.withValues(alpha: 0.2),
        child: const ListTile(
          leading: Icon(Icons.settings, color: Colors.amber),
          title: Text('Configuration incomplete'),
          subtitle: Text('Set API URL, device ID and secret in Settings.'),
        ),
      );
}

class _BatteryWarning extends StatelessWidget {
  const _BatteryWarning();
  @override
  Widget build(BuildContext context) => Card(
        color: Colors.orange.withValues(alpha: 0.15),
        child: const ListTile(
          leading: Icon(Icons.battery_alert, color: Colors.orange),
          title: Text('Battery optimization is ON'),
          subtitle: Text(
              'The OS may kill the gateway. Fix this on the Reliability tab.'),
        ),
      );
}

class _CountsRow extends StatelessWidget {
  const _CountsRow({required this.d});
  final DashboardData d;
  @override
  Widget build(BuildContext context) {
    final c = d.counts;
    return Column(children: [
      Row(children: [
        _Stat(label: 'Pending', value: c.pending, color: Colors.blue),
        _Stat(label: 'Acknowledged', value: c.synced, color: Colors.blueGrey),
        _Stat(label: 'Failed', value: c.failed, color: Colors.red),
      ]),
      Row(children: [
        _Stat(label: 'Accepted', value: c.accepted, color: Colors.teal),
        _Stat(label: 'Confirmed', value: c.confirmed, color: Colors.green),
        _Stat(label: 'Unresolved', value: c.review, color: Colors.orange),
      ]),
      const Text('Last acknowledged results only. Accepted evidence may still require a reference. Later browser claims are not refreshed here.',
        style: TextStyle(fontSize: 12)),
    ]);
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, required this.color});
  final String label;
  final int value;
  final Color color;
  @override
  Widget build(BuildContext context) => Expanded(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              children: [
                Text('$value',
                    style: TextStyle(
                        fontSize: 28, fontWeight: FontWeight.bold, color: color)),
                Text(label),
              ],
            ),
          ),
        ),
      );
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.d});
  final DashboardData d;
  @override
  Widget build(BuildContext context) {
    final last = d.lastReceived;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _row('Last SMS received',
                last == null ? '—' : '${last.sender} · ${Fmt.ago(last.createdAtDate)}'),
            _row('Last acknowledgement', Fmt.ago(d.lastSyncAt)),
            _row('Last heartbeat',
                '${Fmt.ago(d.lastHeartbeatAt)} ${d.lastHeartbeatAt == null ? '' : (d.lastHeartbeatOk ? '✓' : '✗')}'),
            _row('Connectivity', d.connectivity),
            if (d.counts.permanentlyFailed > 0)
              _row('Permanent failures', '${d.counts.permanentlyFailed}',
                  color: Colors.red),
          ],
        ),
      ),
    );
  }

  Widget _row(String k, String v, {Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(k, style: const TextStyle(color: Colors.grey)),
            Flexible(
                child: Text(v,
                    textAlign: TextAlign.right,
                    style: TextStyle(fontWeight: FontWeight.w600, color: color))),
          ],
        ),
      );
}

class _ActionsCard extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: FilledButton.tonalIcon(
                icon: const Icon(Icons.sync),
                label: const Text('Sync now'),
                onPressed: () async {
                  final r = await ref.read(gatewayActionsProvider).syncNow();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text('Sync: ${r.sent} sent, ${r.failed} failed')));
                  }
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.favorite),
                label: const Text('Heartbeat'),
                onPressed: () async {
                  final r = await ref.read(gatewayActionsProvider).testConnection();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Heartbeat: ${r.detail}')));
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
