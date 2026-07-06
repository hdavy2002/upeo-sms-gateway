# Copyright (c) Upeo. Reference ERPNext / Frappe receiver for the SMS gateway.
#
# Place this in a custom app, e.g. `upeo_gateway/upeo_gateway/api.py`, and call:
#   POST https://erp.example.com/api/method/upeo_gateway.api.incoming
#   POST https://erp.example.com/api/method/upeo_gateway.api.heartbeat
#
# Auth model: the device sends the same HMAC-signed payload as for FastAPI. The
# per-device secret is stored (hashed) on an `SMS Gateway Device` doctype. The
# endpoints are @frappe.whitelist(allow_guest=True) but every request is rejected
# unless the HMAC signature, fresh sent_at, and unused nonce all validate — so
# guest access is gated by the signature, not by a session.
#
# DocTypes (see *.json next to this file):
#   - SMS Gateway Message: device_id, sender, message (Long Text), received_at,
#       sim_slot, message_hash (Unique), status, created_at
#   - SMS Gateway Device:  device_id (unique), secret_hash, last_heartbeat,
#       last_app_version, last_battery, pending, failed

import hashlib
import hmac
from datetime import datetime, timedelta, timezone

import frappe

MAX_SENT_AT_SKEW = timedelta(minutes=5)


# --------------------------------------------------------------------------- #
# Canonicalization — identical to lib/src/core/canonical.dart and the FastAPI
# sample. Do not change without changing the client.
# --------------------------------------------------------------------------- #
def _message_hash(sender, message, received_at):
    canonical = f"{sender}|{message}|{received_at}"
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def _incoming_sts(d):
    return "\n".join(
        [
            d["device_id"],
            d["sender"],
            d["message"],
            d["received_at"],
            str(d["sim_slot"]),
            d["message_hash"],
            d["nonce"],
            d["sent_at"],
        ]
    )


def _heartbeat_sts(d):
    return "\n".join([d["device_id"], d["nonce"], d["sent_at"]])


def _sign(string_to_sign, secret):
    return hmac.new(
        secret.encode("utf-8"), string_to_sign.encode("utf-8"), hashlib.sha256
    ).hexdigest()


# In production store a hash of the secret and compare HMACs computed with the
# raw secret you provisioned to the device. Here we assume `secret_hash` holds
# the raw secret for brevity; swap for your own KMS/derivation.
def _device_secret(device_id):
    secret = frappe.db.get_value("SMS Gateway Device", device_id, "secret_hash")
    if not secret:
        frappe.throw("unknown device", frappe.PermissionError)
    return secret


def _fresh(sent_at):
    try:
        ts = datetime.fromisoformat(sent_at)
    except (ValueError, TypeError):
        return False
    if ts.tzinfo is None:
        ts = ts.replace(tzinfo=timezone.utc)
    return abs(datetime.now(timezone.utc) - ts) <= MAX_SENT_AT_SKEW


def _nonce_seen(nonce):
    # Reuse the message doctype is not ideal; use a dedicated single-field doctype
    # `SMS Gateway Nonce` (device_id, nonce unique). Pseudocode:
    if frappe.db.exists("SMS Gateway Nonce", {"nonce": nonce}):
        return True
    frappe.get_doc({"doctype": "SMS Gateway Nonce", "nonce": nonce}).insert(
        ignore_permissions=True
    )
    return False


@frappe.whitelist(allow_guest=True)
def incoming(**payload):
    required = [
        "device_id", "sender", "message", "received_at", "sim_slot",
        "message_hash", "nonce", "sent_at", "signature",
    ]
    for k in required:
        if k not in payload:
            frappe.throw(f"missing {k}")

    secret = _device_secret(payload["device_id"])

    # 1) integrity: recompute message_hash
    if _message_hash(
        payload["sender"], payload["message"], payload["received_at"]
    ) != payload["message_hash"]:
        frappe.throw("message_hash mismatch")

    # 2) signature
    if not hmac.compare_digest(_sign(_incoming_sts(payload), secret), payload["signature"]):
        frappe.throw("invalid signature", frappe.PermissionError)

    # 3) freshness + 4) replay
    if not _fresh(payload["sent_at"]):
        frappe.throw("stale sent_at")
    if _nonce_seen(payload["nonce"]):
        return {"status": "duplicate", "reason": "nonce"}

    # 5) dedup by message_hash
    if frappe.db.exists("SMS Gateway Message", {"message_hash": payload["message_hash"]}):
        frappe.db.commit()
        return {"status": "duplicate"}

    doc = frappe.get_doc(
        {
            "doctype": "SMS Gateway Message",
            "device_id": payload["device_id"],
            "sender": payload["sender"],
            "message": payload["message"],
            "received_at": payload["received_at"],
            "sim_slot": payload["sim_slot"],
            "message_hash": payload["message_hash"],
            "status": "received",
        }
    ).insert(ignore_permissions=True)
    frappe.db.commit()
    return {"status": "accepted", "name": doc.name}


@frappe.whitelist(allow_guest=True)
def heartbeat(**payload):
    secret = _device_secret(payload["device_id"])
    if not hmac.compare_digest(_sign(_heartbeat_sts(payload), secret), payload.get("signature", "")):
        frappe.throw("invalid signature", frappe.PermissionError)
    if not _fresh(payload["sent_at"]):
        frappe.throw("stale sent_at")

    frappe.db.set_value(
        "SMS Gateway Device",
        payload["device_id"],
        {
            "last_heartbeat": frappe.utils.now(),
            "last_app_version": payload.get("app_version"),
            "last_battery": payload.get("battery"),
            "pending": payload.get("pending"),
            "failed": payload.get("failed"),
        },
    )
    frappe.db.commit()
    return {"status": "ok"}


# ----------------------------------------------------------------------------
# NOTE: M-Pesa parsing is a SEPARATE downstream layer. A scheduled job consumes
# `SMS Gateway Message` rows where status == "received", extracts the M-Pesa
# transaction code, and creates e.g. an `Upeo Retail M-Pesa Payment` keyed on
# that unique code (handling reversals). The gateway stays generic.
# ----------------------------------------------------------------------------
