import '../core/constants.dart';

/// Operator-supplied gateway configuration. The [secretKey] is sensitive and is
/// never logged or shown unmasked.
class AppConfig {
  final String apiBaseUrl;
  final String deviceId;
  final String secretKey;
  final List<String> allowlist;
  final int retentionDays;

  /// When true, plain-HTTP base URLs are permitted (DEV ONLY). HTTPS is enforced
  /// otherwise.
  final bool allowInsecureHttp;

  const AppConfig({
    required this.apiBaseUrl,
    required this.deviceId,
    required this.secretKey,
    required this.allowlist,
    required this.retentionDays,
    required this.allowInsecureHttp,
  });

  static const AppConfig empty = AppConfig(
    apiBaseUrl: '',
    deviceId: '',
    secretKey: '',
    allowlist: K.defaultAllowlist,
    retentionDays: K.defaultRetentionDays,
    allowInsecureHttp: false,
  );

  /// Minimum config needed to attempt sync.
  bool get isComplete =>
      apiBaseUrl.isNotEmpty && deviceId.isNotEmpty && secretKey.isNotEmpty;

  bool get isHttps => apiBaseUrl.toLowerCase().startsWith('https://');

  /// Whether the message from [sender] passes the allowlist. Case-insensitive;
  /// an allowlist entry matches if it is contained in the sender (so `MPESA`
  /// matches `MPESA`, `M-PESA`, and shortcodes that embed it).
  bool senderAllowed(String sender) {
    if (allowlist.isEmpty) return false;
    final s = sender.toUpperCase().replaceAll('-', '').replaceAll(' ', '');
    for (final raw in allowlist) {
      final token = raw.trim().toUpperCase().replaceAll('-', '').replaceAll(' ', '');
      if (token.isEmpty) continue;
      if (s.contains(token)) return true;
    }
    return false;
  }

  AppConfig copyWith({
    String? apiBaseUrl,
    String? deviceId,
    String? secretKey,
    List<String>? allowlist,
    int? retentionDays,
    bool? allowInsecureHttp,
  }) {
    return AppConfig(
      apiBaseUrl: apiBaseUrl ?? this.apiBaseUrl,
      deviceId: deviceId ?? this.deviceId,
      secretKey: secretKey ?? this.secretKey,
      allowlist: allowlist ?? this.allowlist,
      retentionDays: retentionDays ?? this.retentionDays,
      allowInsecureHttp: allowInsecureHttp ?? this.allowInsecureHttp,
    );
  }
}
