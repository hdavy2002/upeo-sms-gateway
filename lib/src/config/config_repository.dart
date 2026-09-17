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
  static const _kSnapshot = 'avatok_production_config_v1';

  Future<AppConfig> load() async {
    final all = await _storage.readAll();
    final snapshot = all[_kSnapshot];
    if (snapshot != null) {
      final data = jsonDecode(snapshot) as Map<String, dynamic>;
      return AppConfig(
        apiBaseUrl: data['base_url'] as String,
        deviceId: data['device_id'] as String,
        secretKey: data['secret'] as String,
        allowlist: (data['allowlist'] as List).cast<String>(),
        accountSuffix: data['account_suffix'] as String,
        retentionDays: data['retention_days'] as int,
        allowInsecureHttp: false,
      );
    }
    final allowlistRaw = all[_kAllowlist];
    List<String> allowlist;
    if (allowlistRaw == null || allowlistRaw.isEmpty) {
      allowlist = K.defaultAllowlist;
    } else {
      allowlist = (jsonDecode(allowlistRaw) as List).cast<String>();
    }
    return AppConfig(
      apiBaseUrl: all[_kBaseUrl] ?? K.productionBaseUrl,
      deviceId: all[_kDeviceId] ?? '',
      secretKey: all[_kSecret] ?? '',
      allowlist: allowlist,
      retentionDays: int.tryParse(all[_kRetention] ?? '') ?? K.defaultRetentionDays,
      allowInsecureHttp: (all[_kAllowHttp] ?? 'false') == 'true',
    );
  }

  Future<void> save(AppConfig cfg) async {
    final error = cfg.validationError;
    if (error != null) throw ArgumentError(error);
    // A single encrypted value prevents background isolates observing a new
    // device ID with an old secret during a multi-key configuration save.
    await _storage.write(key: _kSnapshot, value: jsonEncode({
      'base_url': cfg.apiBaseUrl,
      'device_id': cfg.deviceId,
      'secret': cfg.secretKey,
      'allowlist': cfg.allowlist,
      'account_suffix': cfg.accountSuffix,
      'retention_days': cfg.retentionDays,
    }));
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
