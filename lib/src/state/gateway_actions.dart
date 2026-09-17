import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/constants.dart';
import '../data/sms_repository.dart';
import '../services/inbox_backfill.dart';

import '../services/api_client.dart';
import 'dashboard_controller.dart';
import 'providers.dart';

/// User-triggered gateway actions invoked from the UI.
class GatewayActions {
  GatewayActions(this.ref);
  final Ref ref;

  Future<void> startService() async {
    await ref.read(nativeBridgeProvider).startService();
    await Future.delayed(const Duration(milliseconds: 600));
    ref.invalidate(dashboardControllerProvider);
  }

  Future<void> stopService() async {
    await ref.read(nativeBridgeProvider).stopService();
    await Future.delayed(const Duration(milliseconds: 400));
    ref.invalidate(dashboardControllerProvider);
  }

  /// Manual "Sync now".
  Future<SweepSummary> syncNow() async {
    final sync = await ref.read(uiSyncServiceProvider.future);
    if (sync.config.isComplete) {
      await InboxBackfill(
        store: RepositoryInboxStore(sync.repo, sync.recordFromInbox),
        reader: ref.read(nativeBridgeProvider).readInbox,
        owner: const Uuid().v4(), now: () => DateTime.now().millisecondsSinceEpoch,
        pageSize: K.inboxScanLimit,
        initialLookbackMs: K.inboxInitialLookback.inMilliseconds,
        overlapMs: K.inboxScanOverlap.inMilliseconds,
      ).drain();
    }
    final res = await sync.sweep();
    ref.invalidate(dashboardControllerProvider);
    ref.invalidate(logsControllerProvider);
    return SweepSummary(res.sent, res.failed);
  }

  /// Test Connection = a signed heartbeat handshake.
  Future<SendResult> testConnection() async {
    final sync = await ref.read(uiSyncServiceProvider.future);
    final res = await sync.sendHeartbeat();
    ref.invalidate(dashboardControllerProvider);
    return res;
  }

  Future<Map<String, dynamic>?> checkForUpdate() async {
    final cfg = await ref.read(configControllerProvider.future);
    if (!cfg.isComplete) return null;
    return ApiClient(cfg).checkLatestVersion();
  }
}

class SweepSummary {
  final int sent;
  final int failed;
  const SweepSummary(this.sent, this.failed);
}

final gatewayActionsProvider = Provider<GatewayActions>((ref) => GatewayActions(ref));
