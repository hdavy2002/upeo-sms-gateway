import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

import '../config/config_repository.dart';
import '../core/app_log.dart';

/// Opens the SQLCipher-encrypted database. The encryption key comes from
/// [ConfigRepository] (Keystore-backed secure storage). Both the UI isolate and
/// the background isolates open their own connection to the same file; SQLite
/// serialises writes and we set a busy timeout to ride out brief contention.
///
/// Hardened open: the open is time-boxed so a wedged native call surfaces an
/// error instead of hanging the UI forever. Failed opens NEVER erase queued
/// payments: leave the encrypted files intact for recovery. WAL journalling is NOT used
/// — `journal_mode=WAL` was observed to wedge `openDatabase` on some OEM storage
/// (OnePlus/OxygenOS); the default rollback journal is reliable here.
class AppDatabase {
  AppDatabase._(this._db, this._path, this._key);

  Database _db;
  final String _path;
  final String _key;

  /// The live connection. Use [SmsRepository], which guards every call so a
  /// connection that was closed out from under us (see [reopen]) self-heals.
  Database get db => _db;

  bool get isOpen => _db.isOpen;

  static const String table = 'messages';
  static const String metaTable = 'meta';
  static const int _version = 1;
  static const String _tag = 'AppDatabase';
  static const Duration _openTimeout = Duration(seconds: 12);
  static const Duration _keyTimeout = Duration(seconds: 8);

  static Future<AppDatabase> open({ConfigRepository? config}) async {
    final cfg = config ?? ConfigRepository();
    final key = await cfg.dbEncryptionKey().timeout(
      _keyTimeout,
      onTimeout: () =>
          throw TimeoutException('Reading the database key timed out'),
    );

    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'upeo_gateway.db');

    return AppDatabase._(await _open(path, key), path, key);
  }

  /// Re-establish the connection after a `database_closed`. sqflite shares ONE
  /// native handle per path across every isolate in the process, so if any
  /// isolate ever closes it, the others see `database_closed`; reopening here
  /// lets the repository transparently retry instead of wedging until restart.
  /// Idempotent and serialised so concurrent callers don't open twice.
  Future<void> reopen() {
    if (_db.isOpen) return Future.value();
    return _reopening ??= () async {
      try {
        if (!_db.isOpen) {
          AppLog.w(_tag, 'Reopening closed database connection');
          _db = await _open(_path, _key);
        }
      } finally {
        _reopening = null;
      }
    }();
  }

  Future<void>? _reopening;

  static Future<Database> _open(String path, String key) {
    return openDatabase(
      path,
      password: key,
      version: _version,
      onConfigure: (d) async {
        // Value-returning PRAGMAs MUST use rawQuery on Android: execute()
        // (execSQL) rejects them with "Queries can be performed using
        // query or rawQuery methods only", which previously made every open
        // fail and hung the whole app. (journal_mode=WAL had the same problem
        // and is intentionally left at the reliable default.)
        await d.rawQuery('PRAGMA busy_timeout = 5000');
      },
      onCreate: _onCreate,
    ).timeout(
      _openTimeout,
      onTimeout: () => throw TimeoutException('Opening the database timed out'),
    );
  }

  static Future<void> _onCreate(Database d, int version) async {
    await d.execute('''
      CREATE TABLE $table (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sender TEXT NOT NULL,
        message TEXT NOT NULL,
        received_at TEXT NOT NULL,
        sim_slot INTEGER,
        subscription_id INTEGER,
        device_id TEXT NOT NULL,
        status TEXT NOT NULL,
        retry_count INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        next_attempt_at INTEGER NOT NULL DEFAULT 0,
        message_hash TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        synced_at INTEGER
      )
    ''');
    // Dedup: a duplicate delivery / double receiver-fire collapses on the hash.
    await d.execute(
      'CREATE UNIQUE INDEX idx_messages_hash ON $table(message_hash)',
    );
    await d.execute('CREATE INDEX idx_messages_status ON $table(status)');
    await d.execute(
      'CREATE INDEX idx_messages_next_attempt ON $table(next_attempt_at)',
    );

    // Small KV table for runtime status shared across isolates (last heartbeat,
    // last sync, …). Lives in the same encrypted DB.
    await d.execute('''
      CREATE TABLE $metaTable (
        key TEXT PRIMARY KEY,
        value TEXT
      )
    ''');
  }

  /// Closing the shared single-instance handle tears it down for EVERY isolate
  /// in the process, which previously caused `database_closed` in the always-on
  /// service and the UI. Nothing in the app should close it during normal
  /// operation; it is reaped when the process dies. Kept only for tests.
  Future<void> close() => _db.close();
}
