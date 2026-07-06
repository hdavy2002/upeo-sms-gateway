# Upeo SMS Gateway — Backend Samples

Two reference receivers that implement the **exact** signing/verification the
Flutter app uses. Pick one; both share the canonicalization in
[`app/security.py`](app/security.py) (FastAPI) and
[`erpnext/upeo_gateway.py`](erpnext/upeo_gateway.py) (Frappe).

> The gateway is a **generic pipe**. These backends only verify + store the raw
> SMS. M-Pesa transaction parsing, dedup-by-transaction-code, and reversal
> handling are a **separate downstream layer** that consumes stored messages.

## FastAPI

```bash
cd backend_sample
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

# Demo device (must match the phone's Device ID + secret):
export DEMO_DEVICE_ID=PHONE_001
export DEMO_DEVICE_SECRET=changeme-super-secret

uvicorn app.main:app --host 0.0.0.0 --port 8000
```

Then, in another shell, exercise it with the signing client:

```bash
source .venv/bin/activate
python test_client.py
# heartbeat -> (200, {'status': 'ok', ...})
# incoming  -> (200, {'status': 'accepted', 'id': 1})
# duplicate -> (200, {'status': 'duplicate', 'id': 1})
```

### Endpoints

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/api/sms/incoming` | Verify HMAC + nonce + freshness, dedup on `message_hash`, store. |
| `POST` | `/api/sms/heartbeat` | Record device health; powers offline detection. |
| `GET`  | `/api/devices/offline?threshold_minutes=10` | List gateways whose heartbeat went silent. |
| `GET`  | `/api/app/version` | In-app update feed (sideload; no Play auto-update). |

Set `DATABASE_URL=postgresql+psycopg://user:pass@host:5432/upeo` for Postgres.

Update feed env: `LATEST_APP_VERSION`, `LATEST_APP_BUILD`, `LATEST_APK_URL`,
`LATEST_APP_NOTES`.

## ERPNext / Frappe

Copy [`erpnext/upeo_gateway.py`](erpnext/upeo_gateway.py) into a custom app and
import the two DocTypes (`sms_gateway_message.json`, `sms_gateway_device.json`,
plus a single-field `SMS Gateway Nonce`). Endpoints:

```
POST /api/method/upeo_gateway.api.incoming
POST /api/method/upeo_gateway.api.heartbeat
```

They are `allow_guest=True` but gated by the HMAC signature, fresh `sent_at`, and
unused `nonce` — not by a Frappe session.

## Verification rules (both backends)

1. **Unknown device** → 401.
2. **`message_hash` mismatch** (server recompute ≠ supplied) → 400.
3. **Invalid HMAC signature** → 401.
4. **Stale `sent_at`** (> 5 min skew) → 400.
5. **Reused `nonce`** → 409 (replay).
6. **Duplicate `message_hash`** → 200 `{"status":"duplicate"}` (success).
7. Otherwise store and return 200 `{"status":"accepted"}`.

See the repository root README for the byte-exact canonical string spec.
