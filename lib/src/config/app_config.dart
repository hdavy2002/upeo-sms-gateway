import '../core/constants.dart';

/// Operator-supplied gateway configuration. The [secretKey] is sensitive and is
/// never logged or shown unmasked.
class AppConfig {
  final String apiBaseUrl;
  final String deviceId;
  final String secretKey;
  final List<String> allowlist;
  final String accountSuffix;
  final int retentionDays;

  /// Legacy field retained for source compatibility. True is always rejected.
  final bool allowInsecureHttp;

  const AppConfig({
    required this.apiBaseUrl,
    required this.deviceId,
    required this.secretKey,
    required this.allowlist,
    this.accountSuffix = '',
    required this.retentionDays,
    required this.allowInsecureHttp,
  });

  static const AppConfig empty = AppConfig(
    apiBaseUrl: K.productionBaseUrl,
    deviceId: '',
    secretKey: '',
    allowlist: K.defaultAllowlist,
    retentionDays: K.defaultRetentionDays,
    allowInsecureHttp: false,
  );

  bool get isComplete => validationError == null;

  bool get isHttps => Uri.tryParse(apiBaseUrl)?.scheme == 'https';

  static String? validateBaseUrl(String value) {
    final uri = Uri.tryParse(value);
    final expected = Uri.parse(K.productionBaseUrl);
    if (uri == null || uri.scheme != 'https' ||
        uri.host != expected.host || uri.port != 443 ||
        uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      return 'Use the AvaTOK production Worker root: ${K.productionBaseUrl}';
    }
    return null;
  }

  static String? validateDeviceId(String value) =>
      RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(value)
          ? null : 'Use 1–64 letters, digits, underscores or hyphens';

  static String? validateSecret(String value) =>
      value.length >= 32 && value.length <= 256 &&
              !RegExp(r'\s').hasMatch(value)
          ? null : 'Enter a 32–256 character device secret without whitespace';

  static String? validateAccountSuffix(String value) =>
      RegExp(r'^[0-9]{4}$').hasMatch(value)
          ? null : 'Enter the last 4 account digits';

  // Exact bank header after an optional Indian DLT routing prefix/category.
  // Substring matching would accept e.g. NOTHDFCBK or HDFCBKSCAM.
  static String? _bankHeader(String value) => RegExp(
        r'^(?:[A-Z]{2}-)?(HDFC[A-Z0-9]{2,6})(?:-[SPTG])?$',
      ).firstMatch(value.trim().toUpperCase())?.group(1);

  static const _supportedHdfcHeaders = {'HDFCBK', 'HDFCBN', 'HDFCBANK'};

  static String? validateAllowlist(List<String> values) =>
      values.isNotEmpty && values.every((v) => _bankHeader(v) != null)
          ? null : 'Enter exact HDFC sender headers, separated by commas';

  String? get validationError => validateBaseUrl(apiBaseUrl) ??
      (allowInsecureHttp ? 'HTTP is disabled in this production companion' : null) ??
      validateDeviceId(deviceId) ?? validateSecret(secretKey) ??
      validateAllowlist(allowlist) ?? validateAccountSuffix(accountSuffix) ??
      (retentionDays < 3 || retentionDays > 90
          ? 'Retention must be between 3 and 90 days' : null);

  /// Case-insensitive exact HDFC header match; no wildcard/substring matches.
  bool senderAllowed(String sender) {
    final header = _bankHeader(sender);
    // One configured HDFC header opts into the known HDFC sender family. This
    // covers carrier/DLT variations such as JX-HDFCBK-S, VM-HDFCBN-T and
    // HDFCBANK without allowing unrelated senders or arbitrary substrings.
    return header != null && _supportedHdfcHeaders.contains(header) &&
        allowlist.any((v) => _supportedHdfcHeaders.contains(_bankHeader(v)));
  }

  /// Conservative capture filter, NOT payment validation. The Worker must parse
  /// and reconcile the signed raw SMS independently before granting any credit.
  bool paymentSmsAllowed(String sender, String body) {
    if (!isComplete || !senderAllowed(sender) || body.length > 8192) return false;
    if (RegExp(r'\b(?:otp|one[ -]?time|password|pin|verification|debited)\b',
            caseSensitive: false).hasMatch(body)) return false;
    if (!RegExp(r'\b(?:credited|received)\b', caseSensitive: false).hasMatch(body) ||
        !RegExp(r'(?:\bINR\b|\bRs\.?|₹)\s*[0-9]',
            caseSensitive: false).hasMatch(body)) return false;
    final accounts = RegExp(
      r'\b(?:a\s*/\s*c|acct|account|ac)\b\s*(?:(?:no\.?|number)\s*)?[:.\-]?\s*([xX*0-9]+)(?![A-Za-z0-9])',
      caseSensitive: false,
    ).allMatches(body);
    // Match the suffix only within an account-labelled token, never an amount,
    // phone number, reference/UTR, or the middle of a longer account number.
    return accounts.any((m) => m.group(1)!.endsWith(accountSuffix));
  }

  AppConfig copyWith({
    String? apiBaseUrl,
    String? deviceId,
    String? secretKey,
    List<String>? allowlist,
    String? accountSuffix,
    int? retentionDays,
    bool? allowInsecureHttp,
  }) {
    return AppConfig(
      apiBaseUrl: apiBaseUrl ?? this.apiBaseUrl,
      deviceId: deviceId ?? this.deviceId,
      secretKey: secretKey ?? this.secretKey,
      allowlist: allowlist ?? this.allowlist,
      accountSuffix: accountSuffix ?? this.accountSuffix,
      retentionDays: retentionDays ?? this.retentionDays,
      allowInsecureHttp: allowInsecureHttp ?? this.allowInsecureHttp,
    );
  }
}
