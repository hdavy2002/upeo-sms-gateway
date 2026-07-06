"""Tiny signing client to exercise the backend locally and to demonstrate that
the canonicalization matches the Flutter app byte-for-byte.

Usage (backend running on :8000):
    python test_client.py
"""
import json
import urllib.request
import uuid
from datetime import datetime, timezone

from app import security

BASE = "http://127.0.0.1:8000"
DEVICE_ID = "PHONE_001"
SECRET = "changeme-super-secret"  # must match the seeded demo device


def _post(path: str, body: dict) -> tuple[int, dict]:
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        BASE + path, data=data, headers={"Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())


def now_eat() -> str:
    # +03:00, mirroring the client. (Here we just emit UTC+3 with the offset.)
    from datetime import timedelta

    eat = datetime.now(timezone.utc) + timedelta(hours=3)
    return eat.strftime("%Y-%m-%dT%H:%M:%S") + "+03:00"


def send_sms(sender: str, message: str) -> tuple[int, dict]:
    received_at = now_eat()
    sent_at = now_eat()
    nonce = str(uuid.uuid4())
    mhash = security.message_hash(sender, message, received_at)
    sts = security.incoming_string_to_sign(
        device_id=DEVICE_ID,
        sender=sender,
        message=message,
        received_at=received_at,
        sim_slot=1,
        message_hash=mhash,
        nonce=nonce,
        sent_at=sent_at,
    )
    sig = security.sign(sts, SECRET)
    body = {
        "device_id": DEVICE_ID,
        "sender": sender,
        "message": message,
        "received_at": received_at,
        "sim_slot": 1,
        "message_hash": mhash,
        "nonce": nonce,
        "sent_at": sent_at,
        "signature": sig,
    }
    return _post("/api/sms/incoming", body)


def send_heartbeat() -> tuple[int, dict]:
    sent_at = now_eat()
    nonce = str(uuid.uuid4())
    sts = security.heartbeat_string_to_sign(
        device_id=DEVICE_ID, nonce=nonce, sent_at=sent_at
    )
    sig = security.sign(sts, SECRET)
    body = {
        "device_id": DEVICE_ID,
        "nonce": nonce,
        "sent_at": sent_at,
        "signature": sig,
        "app_version": "1.0.0+1",
        "pending": 0,
        "failed": 0,
        "battery": 87,
        "connectivity": "wifi",
    }
    return _post("/api/sms/heartbeat", body)


if __name__ == "__main__":
    print("health:", _post.__name__)
    print("heartbeat ->", send_heartbeat())
    msg = "QGH7ABCD12 Confirmed. Ksh1,000.00 received from JOHN DOE 0712345678 on 19/6/26."
    print("incoming  ->", send_sms("MPESA", msg))
    print("duplicate ->", send_sms("MPESA", msg))  # same hash -> duplicate
