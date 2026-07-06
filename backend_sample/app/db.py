"""Database setup. SQLite by default; Postgres-ready via DATABASE_URL.

    export DATABASE_URL=postgresql+psycopg://user:pass@host:5432/upeo
"""
import os
from datetime import datetime, timezone

from sqlalchemy import (
    Boolean,
    DateTime,
    Integer,
    String,
    Text,
    UniqueConstraint,
    create_engine,
)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, sessionmaker

DATABASE_URL = os.environ.get("DATABASE_URL", "sqlite:///./upeo_gateway.db")

# check_same_thread only matters for SQLite.
connect_args = {"check_same_thread": False} if DATABASE_URL.startswith("sqlite") else {}
engine = create_engine(DATABASE_URL, connect_args=connect_args, future=True)
SessionLocal = sessionmaker(bind=engine, autoflush=False, expire_on_commit=False)


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


class Base(DeclarativeBase):
    pass


class Device(Base):
    """A registered gateway phone. In production store a *hashed* secret."""

    __tablename__ = "sms_gateway_device"

    device_id: Mapped[str] = mapped_column(String(64), primary_key=True)
    secret: Mapped[str] = mapped_column(String(256), nullable=False)
    last_heartbeat: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    last_app_version: Mapped[str | None] = mapped_column(String(32))
    last_battery: Mapped[int | None] = mapped_column(Integer)
    last_connectivity: Mapped[str | None] = mapped_column(String(16))
    pending: Mapped[int | None] = mapped_column(Integer)
    failed: Mapped[int | None] = mapped_column(Integer)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow)


class SmsMessage(Base):
    """A stored, deduplicated gateway message. Generic — no M-Pesa parsing here."""

    __tablename__ = "sms_gateway_message"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    device_id: Mapped[str] = mapped_column(String(64), index=True)
    sender: Mapped[str] = mapped_column(String(64), index=True)
    message: Mapped[str] = mapped_column(Text)
    received_at: Mapped[str] = mapped_column(String(40))
    sim_slot: Mapped[int] = mapped_column(Integer, default=-1)
    message_hash: Mapped[str] = mapped_column(String(64), unique=True, index=True)
    status: Mapped[str] = mapped_column(String(16), default="received")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow)

    __table_args__ = (UniqueConstraint("message_hash", name="uq_message_hash"),)


class UsedNonce(Base):
    """Replay protection: every accepted nonce is remembered (per device)."""

    __tablename__ = "sms_gateway_nonce"

    nonce: Mapped[str] = mapped_column(String(64), primary_key=True)
    device_id: Mapped[str] = mapped_column(String(64), index=True)
    seen_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow)


def init_db() -> None:
    Base.metadata.create_all(engine)


def seed_demo_device() -> None:
    """Seed a demo device from env for quick local testing.

    DEMO_DEVICE_ID (default PHONE_001) + DEMO_DEVICE_SECRET (default changeme).
    """
    device_id = os.environ.get("DEMO_DEVICE_ID", "PHONE_001")
    secret = os.environ.get("DEMO_DEVICE_SECRET", "changeme-super-secret")
    with SessionLocal() as s:
        if s.get(Device, device_id) is None:
            s.add(Device(device_id=device_id, secret=secret))
            s.commit()
