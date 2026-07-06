import 'package:permission_handler/permission_handler.dart';

import '../core/app_log.dart';

/// Runtime permission orchestration with graceful denial handling.
class PermissionsService {
  static const _tag = 'Permissions';

  /// The permissions the gateway needs to capture + forward SMS.
  static const List<Permission> required = [
    Permission.sms, // RECEIVE_SMS / READ_SMS
    Permission.phone, // READ_PHONE_STATE (SIM slot / subscription id)
    Permission.notification, // POST_NOTIFICATIONS (Android 13+)
  ];

  Future<Map<Permission, PermissionStatus>> requestAll() async {
    final result = await required.request();
    result.forEach((perm, status) {
      AppLog.i(_tag, '${perm.toString()} -> $status');
    });
    return result;
  }

  Future<bool> hasAllRequired() async {
    for (final p in required) {
      if (!await p.isGranted) return false;
    }
    return true;
  }

  Future<PermissionStatus> status(Permission p) => p.status;

  Future<bool> request(Permission p) async {
    final s = await p.request();
    return s.isGranted;
  }

  Future<void> openSettings() => openAppSettings();
}
