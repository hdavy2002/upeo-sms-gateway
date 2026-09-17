# AvaTOK HDFC SMS companion — staging only

Dedicated, sideloaded Android payment-SMS gateway adapted from
[hdavy2002/upeo-sms-gateway](https://github.com/hdavy2002/upeo-sms-gateway), baseline
`db58742`. Upstream source/package names and method channels remain to minimize
changes to background-service plumbing. Historical documentation is in
[UPSTREAM_README.md](UPSTREAM_README.md); it is not this fork's operating guide.

Android application ID: `ai.avatok.sms_companion.staging`. This installs separately
from Upeo and AvaTOK, with its own Android app sandbox and Keystore-backed config.
It is a single gateway-device installation, not a shared AvaTOK user-account app.
No device ID, device secret, account digits or signing keys are shipped in source.

## Configuration on the gateway phone

- Worker root: `https://api-staging.avatok.ai` (prefilled). Only this exact HTTPS
  origin, with an optional trailing slash/default port, is accepted. Paths,
  credentials, query strings, fragments, alternate hosts, HTTP and redirects are
  rejected. There is no production mode or insecure-HTTP escape hatch.
- Device ID: the registered staging gateway device, 1–64 letters/digits/`_`/`-`.
- Device secret: the same 32–256 character non-whitespace secret provisioned for
  that staging device on the Worker. The generator creates 256 random bits; it
  neither exposes the generated value automatically nor copies it to clipboard.
- HDFC sender allowlist: defaults to `HDFCBK,HDFCBN`; verify actual headers on the
  test phone. Entries match exact HDFC bank headers case-insensitively, allowing
  an Indian DLT two-letter routing prefix (e.g. `AD-HDFCBK`) and a category suffix
  (`-S`, `-T`, `-P`, `-G`). No wildcard or substring matching.
- Account suffix: exactly the last four digits of the receiving HDFC account.
- Synced-message retention: 3–90 days, default 14. Pending/failed records remain.

“Test heartbeat” uses the form values without saving them, starting the service,
or sending any SMS. It sends a signed heartbeat with `test: true`; success means
the staging endpoint accepted the request, not that any payment was verified.
Save persists one encrypted configuration snapshot so background isolates cannot
read a partially updated ID/secret pair. Grant SMS/notification permissions and
allow background operation on the dedicated phone. Use the dashboard/reliability
screen to check the foreground service and battery settings.

## Capture and delivery

Before queue insertion, both live reception and inbox recovery require complete
valid staging configuration, an allowed HDFC sender, a labelled account token
ending in the configured suffix, `credited` or `received`, and an INR/Rs/₹ amount
marker. OTP, one-time-code, password, PIN, verification and debit messages are
excluded. The account suffix cannot match an amount, UTR or phone number alone.
This conservative English-language filter may reject unfamiliar bank templates;
add only redacted test fixtures when expanding it. It is not proof of payment or
a bank-authenticity check. The Worker must independently validate/reconcile every
raw SMS and reject irrelevant or ambiguous messages before granting wallet credit.

The fork preserves SQLCipher queue encryption, unique message hashes, original
PDU timestamps, multipart reception, foreground service, boot/update receiver,
inbox backfill, WorkManager backstop, reconnect sweep and jittered exponential
retry (8 attempts, capped at one hour). Manual retry remains available. Database
open errors preserve all encrypted files instead of erasing the payment queue.

Delivery rechecks the sender/account filter and stored device ID against current
config. Rows that no longer match remain failed for operator review, never silently
reassigned to a new device. Changing configuration does not rewrite old rows.
HTTP 408/429/5xx/network errors retry. A 409 is acknowledged only with an explicit
`{"status":"duplicate"}` or `{"result":"duplicate"}` response; replay conflicts
remain failures. Redirects are refused. HTTP response bodies are not copied into
diagnostic logs because they could echo SMS content. Existing retry exhaustion
and manual-retry semantics remain unchanged for other 4xx errors.

## Worker integration contract (parent integration required)

Endpoints retain Upeo's contract, relative to the pinned staging root:

- `POST /api/sms/incoming`
- `POST /api/sms/heartbeat`
- Optional version feed: `GET /api/app/version`

Incoming JSON fields: `device_id`, `sender`, `message`, `received_at`, `sim_slot`,
`message_hash`, `nonce`, `sent_at`, `signature`.

```
message_hash = lowercase_hex(SHA256(UTF8(sender + "|" + message + "|" + received_at)))
incoming_signing_string = device_id + "\n" + sender + "\n" + message + "\n"
  + received_at + "\n" + decimal(sim_slot) + "\n" + message_hash + "\n"
  + nonce + "\n" + sent_at
heartbeat_signing_string = device_id + "\n" + nonce + "\n" + sent_at
signature = lowercase_hex(HMAC_SHA256(UTF8(device_secret), UTF8(signing_string)))
```

No trailing newline. Original SMS strings are not trimmed or reformatted.
The upstream timestamp representation remains ISO-8601 at `+03:00` with seconds
precision for hash/signature compatibility; parse its offset rather than assuming
India local time. Each attempt creates a fresh UUID nonce and `sent_at`; a retry
keeps the original message hash and `received_at`.

The Worker must verify signatures with the registered per-device secret, recompute
the message hash, enforce a ±5 minute `sent_at` window, atomically reject reused
nonces, and deduplicate accepted payments by device/message hash and bank reference.
Dedup must outlive local retention and local log clearing. Verify auth/replay
before returning duplicate success. Local sender/account filters are defense in
depth; the server's registered account and HDFC sender policy remain authoritative.
The account suffix is local configuration, not a new unsigned payment field.

Periodic heartbeat JSON additionally contains app version, queue counts, last SMS
time, battery/charging and connectivity. These optional health fields (including
`test`) are **not signed by Upeo's heartbeat canonicalization** and must not control
authorization, payment amounts or device enrollment. Caller-provided health values
cannot override the client's signed identity, nonce, timestamp or signature.

## Review and verification

Tests cover staging URL restrictions, HDFC sender/account/OTP filtering,
capture/backfill gating, heartbeat-only behavior, unchanged canonical signatures,
fresh retry nonces, redirect policy, duplicate/replay distinction and rate limits.
Run Flutter tests and Android build/device checks only in an approved CI workflow.
This task does not authorize builds, deployment, credentials access or a live
heartbeat. No local Flutter/Dart/Gradle build, analyzer or test command was run.

Worker endpoint implementation, device provisioning, real redacted HDFC fixtures,
CI compilation and physical-phone checks (multipart SMS, offline retry, reboot,
OEM battery handling and modern Android foreground-service restrictions) remain
integration/release checks. The inherited dataSync boot-service approach may need
Android-version-specific follow-up; do not assume boot recovery is verified from
source inspection alone. Parent review must also confirm matching endpoint paths.

The bundled `backend_sample/` is upstream reference material only; it is not the
AvaTOK Worker implementation and must not be deployed as part of this companion.


## Receipt evidence and recovery (protocol v2)

The dashboard distinguishes transport **Acknowledged**, parsed **Accepted**, and
server **Confirmed** matching. Accepted `awaiting_reference` shows “Bank evidence
stored; reference required.” Ignored, unmatched, awaiting-reference, review-pending,
and legacy unknown responses never mean a confirmed payment. These are the last
acknowledged outcomes, not a live query of a later browser claim; retry an unresolved row to
refresh its outcome. Failed/configuration requests remain visible. Permanent
HTTP/configuration failures stop automatic retries immediately. Manual retry
starts a new retry budget while retaining lifetime attempts and audit history.

The encrypted database upgrades additively from schema 1 to 2. Existing queue
bodies, hashes and retry state remain intact; old acknowledgements have unknown
receipt/matching outcomes. Never erase or re-key the database to recover a failed
upgrade. Automatic and manual evidence deletion are disabled pending an approved
retention policy. Unresolved receipts must not lose their only evidence.

Inbox recovery uses ascending `(date, _id)` pages and a frozen upper timestamp.
Each page and cursor commit together under an expiring database lease. Each sweep
reads at most five pages of 200 messages, resuming the same window next time. A
provider/permission error or lost lease cannot advance the cursor. First v2
startup rescans the preceding two days because the old watermark could have
skipped messages; an existing v2 watermark is never moved forward merely because
the device was offline for more than two days. Subsequent scans overlap ten
minutes and exact signed-message hashes and transactional reference-bearing content checks
deduplicate native/live delivery with differing provider/PDU timestamps. Reference-less
SMS timestamps remain distinct uncertain evidence; server bank-identity uniqueness is the
payment deduplication authority. Older-than-initial-window legacy SMS require an
explicit operator recovery procedure; they are not silently declared scanned.

The About screen displays the CI-injected source revision. The heartbeat contract
is unchanged. Original `received_at` (+03:00, whole seconds) and signed canonical
fields are retained byte-for-byte on retries; only nonce and sent_at are rebuilt.

Both workflows pin Flutter 3.47.2 (official tag verified at
`d3b14c876900e553bc736ca19295fc09e3853e8e`). CI must resolve this repository's Dart
^3.12.2 dependencies before the toolchain is considered validated. Verification is manual or reusable by the manual APK workflow. It
runs Flutter tests (SQLite adapter migration/page/retry tests included) and native
Robolectric provider tests before any build/signing step. No push trigger was
added. SQLCipher encryption/key retention and device background behavior still
require the separately authorized real-device upgrade smoke check; desktop
SQLite tests exercise schema and transaction behavior, not Android encryption.

The native verification job installs Gradle 9.1.0, matching the tracked wrapper
properties, instead of relying on an untracked `android/gradlew` launcher. CI
uploads `companion-dependency-lock-<revision>` containing `pubspec.lock`. Only an
explicit manual `resolve_lock=true` verification may resolve a new lock; integrate
that artifact after the authorized successful run. All ordinary verification and
release jobs enforce the committed lock, so an unresolved draft cannot release.
The dependent APK/AAB job downloads that exact lock and uses
`flutter pub get --enforce-lockfile`, so artifact construction cannot silently
select a different dependency resolution from the verified one.
