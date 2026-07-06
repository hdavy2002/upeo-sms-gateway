"""HMAC / canonicalization — MUST match the Flutter client byte-for-byte.

Client reference: lib/src/core/canonical.dart
"""
import hashlib
import hmac
from datetime import datetime, timedelta, timezone

# Reject a payload whose sent_at is older/newer than this. Keep in sync with the
# client's K.sentAtSkew (5 minutes).
MAX_SENT_AT_SKEW = timedelta(minutes=5)


def message_hash(sender: str, message: str, received_at: str) -> str:
    """SHA256( sender | message | received_at ) hex."""
    canonical = f"{sender}|{message}|{received_at}"
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def incoming_string_to_sign(
    *,
    device_id: str,
    sender: str,
    message: str,
    received_at: str,
    sim_slot: int,
    message_hash: str,
    nonce: str,
    sent_at: str,
) -> str:
    """device_id\\nsender\\nmessage\\nreceived_at\\nsim_slot\\nmessage_hash\\nnonce\\nsent_at"""
    return "\n".join(
        [
            device_id,
            sender,
            message,
            received_at,
            str(sim_slot),
            message_hash,
            nonce,
            sent_at,
        ]
    )


def heartbeat_string_to_sign(*, device_id: str, nonce: str, sent_at: str) -> str:
    return "\n".join([device_id, nonce, sent_at])


def sign(string_to_sign: str, secret: str) -> str:
    return hmac.new(
        secret.encode("utf-8"), string_to_sign.encode("utf-8"), hashlib.sha256
    ).hexdigest()


def verify_signature(string_to_sign: str, secret: str, signature: str) -> bool:
    expected = sign(string_to_sign, secret)
    # Constant-time comparison.
    return hmac.compare_digest(expected, signature or "")


def parse_eat(ts: str) -> datetime:
    """Parse an ISO-8601 timestamp like '2026-06-19T12:30:01+03:00'."""
    return datetime.fromisoformat(ts)


def sent_at_is_fresh(sent_at: str, now: datetime | None = None) -> bool:
    now = now or datetime.now(timezone.utc)
    try:
        ts = parse_eat(sent_at)
    except (ValueError, TypeError):
        return False
    if ts.tzinfo is None:
        ts = ts.replace(tzinfo=timezone.utc)
    return abs(now - ts) <= MAX_SENT_AT_SKEW
