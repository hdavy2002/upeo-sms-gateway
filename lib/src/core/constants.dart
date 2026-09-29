/// App-wide constants. No secrets here — those live in secure storage.
class K {
  K._();

  static const String appName = 'AvaTOK SMS Gateway · Production';
  static const String releaseSha = String.fromEnvironment('RELEASE_SHA', defaultValue: 'unversioned');
  static const String applicationId = 'ai.avatok.sms_companion.test';
  // Exact production origin. No runtime HTTP/host override.
  static const String productionBaseUrl = 'https://api.avatok.ai';

  // ----- MethodChannels (must match the Kotlin side) -----
  static const String nativeChannel = 'upeo/native';
  static const String smsEventsChannel = 'upeo/sms_events';

  // ----- Backend endpoints (relative to the configured base URL) -----
  static const String incomingPath = '/api/sms/incoming';
  static const String heartbeatPath = '/api/sms/heartbeat';
  static const String versionPath = '/api/app/version';

  // ----- Defaults -----
  static const List<String> defaultAllowlist = ['HDFCBK', 'HDFCBN', 'HDFCBANK'];
  static const int defaultRetentionDays = 14;

  // ----- Sync / retry policy -----
  static const int maxRetries = 8;
  static const Duration baseBackoff = Duration(seconds: 15);
  static const Duration maxBackoff = Duration(minutes: 15);
  // A payment SMS younger than this never stops retrying (no attempt cap): the
  // customer is waiting at checkout and the server may simply be mid-deploy.
  static const Duration paymentRetryWindow = Duration(hours: 48);
  static const int syncBatchSize = 25;

  // ----- Background timers (foreground-service isolate) -----
  static const Duration heartbeatInterval = Duration(minutes: 5);
  // Sweep often so any SMS that failed to send during a brief server blip
  // (e.g. a backend deploy/restart) is retried within seconds. The per-message
  // exponential backoff still prevents hammering a server that is actually down.
  static const Duration sweepInterval = Duration(seconds: 15);

  // ----- Replay window the server should also enforce -----
  static const Duration sentAtSkew = Duration(minutes: 5);

  // ----- Device-inbox backfill (recover SMS the live receiver never saw, e.g.
  //       a message that arrived while the DB was briefly closed or the service
  //       was dead). Scans content://sms/inbox and ingests anything missing. -----
  static const Duration inboxScanInterval = Duration(seconds: 60);
  // Initial v2 recovery window only. Persisted unfinished scans never advance
  // past old unseen messages; destructive retention is disabled.
  static const Duration inboxInitialLookback = Duration(days: 2);
  // Re-scan a little before the high-water mark to tolerate clock skew between
  // the PDU timestamp and the inbox `date`; transactional dedup makes overlap safe.
  static const Duration inboxScanOverlap = Duration(minutes: 10);
  static const int inboxScanLimit = 200;

  // ----- WorkManager backstop -----
  static const String backstopTaskName = 'upeo_backstop_sweep';
  static const String backstopUniqueName = 'upeo_backstop_periodic';

  // ----- Watchdog: service considered "stale" if no tick within this window -----
  static const Duration watchdogStaleAfter = Duration(minutes: 3);

  // ----- Kill switch -----
  // [UPI3-REENABLE 2026-09-29] Turned back ON (layer 2 of the UPI 3-layer
  // confirmation). Flip both this and CompanionRail.disabled to true to take
  // the app dark again.
  // [TAKEDOWN-HDFC-DARK-1 2026-09-20] This companion is the private counterpart to
  // the internal ₹1 HDFC UPI SMS smoke harness (worker `hdfcSmsRailEnabled` flag),
  // never the commercial rail. While true: the app never starts the gateway
  // service, never reads or forwards SMS, and shows a plain disabled notice
  // instead of the dashboard. Reversible — flip back to false to restore.
  // Mirrored natively by `CompanionRail.disabled` in android/.../CompanionRail.kt.
  static const bool railDisabled = false;
}
