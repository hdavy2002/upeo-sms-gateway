import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/constants.dart';
import 'app_config.dart';

/// Persists [AppConfig] and the DB encryption key in the Android Keystore-backed
/// [FlutterSecureStorage]. Accessible from both the UI isolate and the
/// background-service / WorkManager isolates (same app, same keystore).
class ConfigRepository {
  ConfigRepository({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _kBaseUrl = 'cfg_base_url';
  static const _kDeviceId = 'cfg_device_id';
  static const _kSecret = 'cfg_secret';
  static const _kAllowlist = 'cfg_allowlist';
  static const _kRetention = 'cfg_retention_days';
  static const _kAllowHttp = 'cfg_allow_http';
  static const _kDbKey = 'db_encryption_key';

  Future<AppConfig> load() async {
    final all = await _storage.readAll();
    final allowlistRaw = all[_kAllowlist];
    List<String> allowlist;
    if (allowlistRaw == null || allowlistRaw.isEmpty) {
      allowlist = K.defaultAllowlist;
    } else {
      allowlist = (jsonDecode(allowlistRaw) as List).cast<String>();
    }
    return AppConfig(
      apiBaseUrl: all[_kBaseUrl] ?? '',
      deviceId: all[_kDeviceId] ?? '',
      secretKey: all[_kSecret] ?? '',
      allowlist: allowlist,
      retentionDays: int.tryParse(all[_kRetention] ?? '') ?? K.defaultRetentionDays,
      allowInsecureHttp: (all[_kAllowHttp] ?? 'false') == 'true',
    );
  }

  Future<void> save(AppConfig cfg) async {
    await _storage.write(key: _kBaseUrl, value: cfg.apiBaseUrl.trim());
    await _storage.write(key: _kDeviceId, value: cfg.deviceId.trim());
    await _storage.write(key: _kSecret, value: cfg.secretKey);
    await _storage.write(key: _kAllowlist, value: jsonEncode(cfg.allowlist));
    await _storage.write(key: _kRetention, value: '${cfg.retentionDays}');
    await _storage.write(key: _kAllowHttp, value: '${cfg.allowInsecureHttp}');
  }

  /// Returns the DB encryption key, generating a 256-bit random one on first use.
  Future<String> dbEncryptionKey() async {
    final existing = await _storage.read(key: _kDbKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final rng = Random.secure();
    final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
    final key = base64UrlEncode(bytes);
    await _storage.write(key: _kDbKey, value: key);
    return key;
  }
}
