"""Upeo SMS Gateway — FastAPI reference backend.

A *generic* receiver for gateway messages. It verifies the HMAC signature,
rejects stale timestamps and reused nonces, dedups on message_hash, and stores
the raw SMS. M-Pesa / transaction-code parsing is intentionally NOT here — that
is a separate downstream layer (see README).

Run:
    pip install -r requirements.txt
    uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
"""
import os
from datetime import datetime, timedelta, timezone

from fastapi import Depends, FastAPI, HTTPException
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from . import security
from .db import Device, SessionLocal, SmsMessage, UsedNonce, init_db, seed_demo_device
from .schemas import AcceptResponse, Heartbeat, IncomingSms, VersionResponse

app = FastAPI(title="Upeo SMS Gateway Backend", version="1.0.0")


@app.on_event("startup")
def _startup() -> None:
    init_db()
    seed_demo_device()


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


def _require_device(db: Session, device_id: str) -> Device:
    device = db.get(Device, device_id)
    if device is None:
        raise HTTPException(status_code=401, detail="unknown device")
    return device


@app.get("/")
def health():
    return {"status": "ok", "service": "upeo-sms-gateway"}


@app.post("/api/sms/incoming", response_model=AcceptResponse)
def incoming(payload: IncomingSms, db: Session = Depends(get_db)):
    device = _require_device(db, payload.device_id)

    # 1) message_hash must match the canonical recomputation (integrity).
    expected_hash = security.message_hash(
        payload.sender, payload.message, payload.received_at
    )
    if expected_hash != payload.message_hash:
        raise HTTPException(status_code=400, detail="message_hash mismatch")

    # 2) HMAC signature over the exact documented canonical string.
    sts = security.incoming_string_to_sign(
        device_id=payload.device_id,
        sender=payload.sender,
        message=payload.message,
        received_at=payload.received_at,
        sim_slot=payload.sim_slot,
        message_hash=payload.message_hash,
        nonce=payload.nonce,
        sent_at=payload.sent_at,
    )
    if not security.verify_signature(sts, device.secret, payload.signature):
        raise HTTPException(status_code=401, detail="invalid signature")

    # 3) Replay protection: reject stale sent_at.
    if not security.sent_at_is_fresh(payload.sent_at):
        raise HTTPException(status_code=400, detail="stale sent_at")

    # 4) Replay protection: reject reused nonce.
    if db.get(UsedNonce, payload.nonce) is not None:
        raise HTTPException(status_code=409, detail="nonce already used (replay)")
    db.add(UsedNonce(nonce=payload.nonce, device_id=payload.device_id))

    # 5) Dedup by message_hash (a duplicate delivery is success, not an error).
    existing = db.scalar(
        select(SmsMessage).where(SmsMessage.message_hash == payload.message_hash)
    )
    if existing is not None:
        db.commit()  # persist the nonce
        return AcceptResponse(status="duplicate", id=existing.id)

    row = SmsMessage(
        device_id=payload.device_id,
        sender=payload.sender,
        message=payload.message,
        received_at=payload.received_at,
        sim_slot=payload.sim_slot,
        message_hash=payload.message_hash,
        status="received",
    )
    db.add(row)
    try:
        db.commit()
    except IntegrityError:
        # Concurrent insert of the same hash — treat as duplicate.
        db.rollback()
        existing = db.scalar(
            select(SmsMessage).where(SmsMessage.message_hash == payload.message_hash)
        )
        return AcceptResponse(status="duplicate", id=existing.id if existing else None)

    db.refresh(row)
    return AcceptResponse(status="accepted", id=row.id)


@app.post("/api/sms/heartbeat")
def heartbeat(payload: Heartbeat, db: Session = Depends(get_db)):
    device = _require_device(db, payload.device_id)

    sts = security.heartbeat_string_to_sign(
        device_id=payload.device_id, nonce=payload.nonce, sent_at=payload.sent_at
    )
    if not security.verify_signature(sts, device.secret, payload.signature):
        raise HTTPException(status_code=401, detail="invalid signature")
    if not security.sent_at_is_fresh(payload.sent_at):
        raise HTTPException(status_code=400, detail="stale sent_at")

    device.last_heartbeat = datetime.now(timezone.utc)
    device.last_app_version = payload.app_version
    device.last_battery = payload.battery
    device.last_connectivity = payload.connectivity
    device.pending = payload.pending
    device.failed = payload.failed
    db.commit()
    return {"status": "ok", "device_id": device.device_id}


@app.get("/api/devices/offline")
def offline_devices(threshold_minutes: int = 10, db: Session = Depends(get_db)):
    """List gateways whose heartbeat has gone silent — i.e. a dead gateway."""
    cutoff = datetime.now(timezone.utc) - timedelta(minutes=threshold_minutes)
    devices = db.scalars(select(Device)).all()
    offline = []
    for d in devices:
        hb = d.last_heartbeat
        if hb is None or (hb.tzinfo and hb < cutoff) or (
            hb.tzinfo is None and hb.replace(tzinfo=timezone.utc) < cutoff
        ):
            offline.append(
                {
                    "device_id": d.device_id,
                    "last_heartbeat": d.last_heartbeat.isoformat()
                    if d.last_heartbeat
                    else None,
                    "pending": d.pending,
                    "failed": d.failed,
                }
            )
    return {"threshold_minutes": threshold_minutes, "offline": offline}


@app.get("/api/app/version", response_model=VersionResponse)
def app_version():
    """In-app update feed (sideload — no Play auto-update). Configure via env."""
    return VersionResponse(
        version=os.environ.get("LATEST_APP_VERSION", "1.0.0"),
        build=int(os.environ.get("LATEST_APP_BUILD", "1")),
        url=os.environ.get("LATEST_APK_URL"),
        notes=os.environ.get("LATEST_APP_NOTES", ""),
    )
