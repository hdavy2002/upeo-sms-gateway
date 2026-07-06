import 'package:intl/intl.dart';

/// All timestamps that cross the wire use East Africa Time (+03:00, no DST),
/// formatted as a byte-exact ISO-8601 string so the HMAC matches server-side.
class TimeUtils {
  TimeUtils._();

  static const Duration eatOffset = Duration(hours: 3);
  static const String eatSuffix = '+03:00';

  static final DateFormat _fmt = DateFormat("yyyy-MM-dd'T'HH:mm:ss");

  /// Format an epoch-millis instant (e.g. the PDU timestamp) as EAT ISO-8601.
  static String iso8601Eat(int epochMillis) {
    final utc = DateTime.fromMillisecondsSinceEpoch(epochMillis, isUtc: true);
    final shifted = utc.add(eatOffset);
    return '${_fmt.format(shifted)}$eatSuffix';
  }

  /// Current instant as EAT ISO-8601 (used for `sent_at`).
  static String nowEat() => iso8601Eat(DateTime.now().toUtc().millisecondsSinceEpoch);
}
