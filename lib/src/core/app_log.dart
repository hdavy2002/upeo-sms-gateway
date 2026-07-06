import 'package:flutter/foundation.dart';

enum LogLevel { debug, info, warn, error }

class LogEntry {
  final DateTime time;
  final LogLevel level;
  final String tag;
  final String message;

  LogEntry(this.level, this.tag, this.message) : time = DateTime.now();

  @override
  String toString() =>
      '${time.toIso8601String()} [${level.name.toUpperCase()}] $tag: $message';
}

/// Lightweight structured logger with an in-memory ring buffer (for the in-app
/// log viewer / export) plus `debugPrint`. Never logs secrets — callers must
/// mask sensitive values before passing them in.
class AppLog {
  AppLog._();

  static const int _max = 800;
  static final List<LogEntry> _buffer = <LogEntry>[];

  static List<LogEntry> get entries => List.unmodifiable(_buffer);

  static void _add(LogLevel level, String tag, String message) {
    final entry = LogEntry(level, tag, message);
    _buffer.add(entry);
    if (_buffer.length > _max) _buffer.removeRange(0, _buffer.length - _max);
    if (kDebugMode) debugPrint(entry.toString());
  }

  static void d(String tag, String msg) => _add(LogLevel.debug, tag, msg);
  static void i(String tag, String msg) => _add(LogLevel.info, tag, msg);
  static void w(String tag, String msg) => _add(LogLevel.warn, tag, msg);
  static void e(String tag, String msg) => _add(LogLevel.error, tag, msg);

  static void clear() => _buffer.clear();

  static String export() => _buffer.map((e) => e.toString()).join('\n');
}
