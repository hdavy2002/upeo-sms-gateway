import 'package:intl/intl.dart';

/// UI time formatting helpers.
class Fmt {
  Fmt._();
  static final DateFormat _dt = DateFormat('yyyy-MM-dd HH:mm:ss');

  static String dateTime(DateTime? d) => d == null ? '—' : _dt.format(d);

  static String ago(DateTime? d) {
    if (d == null) return 'never';
    final diff = DateTime.now().difference(d);
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}
