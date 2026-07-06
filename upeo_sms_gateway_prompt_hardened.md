# Claude Code Prompt — Upeo SMS Gateway (Flutter + Kotlin, hardened)

You are an expert Flutter + native Android (Kotlin) engineer building reliable, offline-first background services.

Build a **production-ready Flutter Android app called `Upeo SMS Gateway`**.

## Purpose
Turn a dedicated Android phone into an SMS gateway: listen for incoming SMS, store them locally, and forward them securely to a backend (FastAPI or ERPNext/Frappe) over HTTPS with a signed payload. The app is a **dumb, message-type-agnostic pipe** — it forwards the raw SMS and does **no** business parsing on the device. All M-Pesa/OTP/business semantics live in the backend.

## Non-negotiable design principles (the landmines — read first)

These are the requirements that determine whether this works on a cheap Tecno/Infinix/Xiaomi/Oppo phone in a Kenyan shop. Treat them as hard requirements, not nice-to-haves.

1. **A persistent foreground service is mandatory.** A manifest `BroadcastReceiver` alone is unreliable: aggressive OEM battery managers and Doze kill background processes, and after a force-stop the receiver won't fire until the app is reopened. Run a Kotlin **foreground service** with an ongoing notification that keeps the process alive, owns the SMS receiver, and triggers immediate sync. WorkManager is only the periodic backstop, not the primary path.
2. **Two-tier sync.** Immediate path: SMS received → persist → enqueue → attempt send right away (driven by the foreground service). Backstop path: a WorkManager periodic job (note the ~15-minute minimum interval) sweeps the queue for anything the immediate path missed. Plus sync on app start, on connectivity regained, and on manual tap.
3. **Sender allowlist — default ON.** The app must NOT forward every SMS on the phone. That is over-collection, a Kenya Data Protection Act problem, and spyware-like behavior. Provide a configurable **sender/keyword allowlist** (default to M-Pesa senders such as `MPESA`) and only persist/forward messages matching it. Everything else is ignored and never stored or transmitted. Make this prominent in setup.
4. **Heartbeat so a dead gateway is noticed.** A silent phone = payments silently stop = an undetected loss. Send a periodic heartbeat to the backend (device_id, app version, pending/failed counts, last_sms_at, battery, connectivity, signal if available). The backend flags a gateway as offline when heartbeats stop.
5. **Encrypt local data at rest.** SMS bodies contain PII (names, phone numbers, codes). Use an encrypted local DB (SQLCipher via `sqflite_sqlcipher` or Drift with encryption), store the secret in `flutter_secure_storage`, and auto-purge synced messages after a configurable retention window.
6. **Replay-proof, byte-exact HMAC.** Define the canonical signed string explicitly so client and server agree to the byte. Include a `nonce` and the `received_at` in the signed material; the backend rejects stale timestamps and reused nonces.
7. **Sideload only — never Play Store.** Google Play forbids `READ_SMS`/`RECEIVE_SMS` for non-default-handlers and grants no exception when an official API exists (M-Pesa has Daraja). The app is for private APK distribution. It does **not** need to be the default SMS handler — runtime permissions are enough off-Play. Add an **in-app update check** (fetch latest APK/version from the backend) since there is no Play auto-update.

## 1. Platform
- Flutter app targeting Android (minSdk 24+, target latest stable).
- **Kotlin native** for the SMS BroadcastReceiver, the foreground service, the boot receiver, and SIM/subscription info via a MethodChannel/EventChannel. Do not rely on Flutter-only SMS plugins.
- Flutter UI for setup, dashboard, logs, manual sync, settings, about.

## 2. SMS receiving (Kotlin)
- Manifest-registered `BroadcastReceiver` for `SMS_RECEIVED`, owned/kept alive by the foreground service.
- Permissions, requested at runtime with graceful denial handling:
  - `RECEIVE_SMS`, `READ_SMS`, `INTERNET`, `ACCESS_NETWORK_STATE`
  - `RECEIVE_BOOT_COMPLETED` (restart service on reboot)
  - `READ_PHONE_STATE` (SIM slot / subscription id)
  - `POST_NOTIFICATIONS` (Android 13+, for the foreground-service notification)
  - `FOREGROUND_SERVICE` (+ `FOREGROUND_SERVICE_DATA_SYNC` on Android 14+)
  - `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`
- On SMS received, before anything else, capture and persist: sender, full raw body (never parsed/modified), SMSC/PDU timestamp, SIM slot + subscription id if available, device_id/name. Reassemble multipart SMS into one logical message first.
- Apply the **sender allowlist** at capture: non-matching messages are dropped immediately.

## 3. Local queue (encrypted SQLite)
Store each allowed SMS with: `id`, `sender`, `message`, `received_at` (ISO8601 +03:00, from the PDU timestamp), `sim_slot`, `subscription_id`, `device_id`, `status` (pending/synced/failed), `retry_count`, `last_error`, `next_attempt_at`, `message_hash`, `created_at`, `synced_at`.
- **`message_hash` = SHA256 over a canonical `sender|message|received_at(PDU)`** — so a duplicate delivery / double receiver-fire dedups, but two genuinely distinct messages never collapse. Unique index on `message_hash`.
- DB encrypted at rest; auto-purge `synced` rows older than the retention window.

## 4. Backend sync
- Configurable: API base URL, device_id, secret key (all in secure storage).
- `POST {base}/api/sms/incoming`, HTTPS required unless an explicit debug flag is set.
- Payload:
```json
{
  "device_id": "PHONE_001",
  "sender": "MPESA",
  "message": "raw SMS body",
  "received_at": "2026-06-19T12:30:00+03:00",
  "sim_slot": 1,
  "message_hash": "...",
  "nonce": "uuid-v4",
  "sent_at": "2026-06-19T12:30:01+03:00",
  "signature": "hmac_sha256_hex"
}
```
- **Canonical string to sign (document this exactly in the README and mirror it server-side):**
  `device_id\nsender\nmessage\nreceived_at\nsim_slot\nmessage_hash\nnonce\nsent_at`
  HMAC-SHA256 over that UTF-8 string with the device secret; hex-encode; place in `signature` (the `signature` field itself is excluded from signing).
- Mark `synced` only on a 2xx that confirms acceptance (or a documented "duplicate" response, treated as success). Keep non-2xx in the queue for retry with exponential backoff + jitter; cap retries and flag permanent failures for the UI.

## 5. Background sync & boot
- WorkManager (native Kotlin or `workmanager` plugin) for the periodic sweep + connectivity-triggered sync.
- Boot receiver: on `BOOT_COMPLETED`, restart the foreground service and schedule the sweep — never just rely on the user reopening the app.
- Never lose SMS across restart, app close, or offline periods (durability before transmission).

## 6. Flutter UI (Riverpod for state, Dio for HTTP)
- **Setup:** API URL, device ID, secret key (masked), **sender allowlist editor (default `MPESA`)**, Save, Test Connection (does a signed handshake/heartbeat).
- **Dashboard:** gateway/service running state, foreground-service health, last SMS received, pending/synced/failed counts, last sync time, **last heartbeat / "gateway online" indicator**, battery-optimization status.
- **SMS log:** recent allowed messages, status badge, sender, masked preview, received time, retry button for failed.
- **Settings:** edit API URL / device ID / secret key / allowlist, retention window, clear synced logs, export logs, check-for-update.
- **About:** app version, device/manufacturer/model, Android version, permissions and service status self-check.
- **Reliability/permissions screen:** programmatically request battery-optimization exemption; detect manufacturer and deep-link to the OEM **autostart/protected-apps** settings (Xiaomi/MIUI, Oppo/ColorOS, Vivo, Samsung, Tecno/Infinix-Transsion) with per-OEM guidance; show a clear warning if the foreground service has been killed.

## 7. Backend samples
`/backend_sample` (FastAPI):
- `POST /api/sms/incoming`: verify HMAC over the documented canonical string; **reject invalid signatures, stale `sent_at` (e.g. older than a few minutes), and reused `nonce`**; dedup by `message_hash`; store in a Postgres-ready schema; return success/duplicate JSON.
- `POST /api/sms/heartbeat`: record device health, expose/flag offline gateways.
- Brief note: M-Pesa-specific parsing, transaction-code dedup, and reversal handling are a **separate downstream layer** that consumes stored gateway messages and maps them into the retail system (e.g. an `Upeo Retail M-Pesa Payment` record keyed on the unique transaction code). Keep the gateway generic.

ERPNext/Frappe example:
- Whitelisted endpoint (token + HMAC auth), Python receiver with the same signature/nonce/timestamp verification and `message_hash` dedup.
- Example DocType `SMS Gateway Message` fields: device_id, sender, message (Long Text), received_at, sim_slot, message_hash (unique), status, created_at; plus a `SMS Gateway Device` doctype holding per-device hashed secret + last_heartbeat for the offline flag.

## 8. Reliability
Foreground service + boot receiver + two-tier sync + exponential backoff + duplicate prevention + offline-first durability + structured logging. Add a self-watchdog that detects and reports if the service was killed.

## 9. Security
- No hardcoded secrets; secret in `flutter_secure_storage`; masked in UI; never logged.
- HMAC-SHA256 with nonce + timestamp replay protection.
- HTTPS enforced unless debug.
- Encrypted local DB; configurable retention/auto-purge.
- Do not forward non-allowlisted SMS; document the privacy posture and DPA considerations in the README.

## 10. Developer quality
Clean folder structure; Riverpod (or Provider); Dio; Drift or `sqflite_sqlcipher`; thorough comments. README covering: setup, full permissions rationale (incl. foreground service, boot, battery exemption, OEM autostart), how to build and **sideload** the APK, the exact signing/canonicalization spec, backend payload + verification, in-app update flow, troubleshooting (service killed, SMS not arriving, signature mismatch, OEM battery settings), and a clear section on **Play Store SMS restrictions and why this is APK-only**.

## 11. Build notes
- Private/internal APK only — not Play Store. Not the default SMS handler.
- Must run reliably on a cheap Android kept on power with Wi-Fi/mobile data, surviving reboots and OEM battery management.
- Primary use: forwarding M-Pesa till SMS to ERPNext/Frappe or FastAPI. Restrict scope via the sender allowlist; do not indiscriminately forward personal SMS or OTPs.

Deliver the full working codebase (Flutter app + Kotlin native + `/backend_sample`), buildable to a signed APK, with the README.
