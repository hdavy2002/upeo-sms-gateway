from pydantic import BaseModel, Field


class IncomingSms(BaseModel):
    device_id: str
    sender: str
    message: str
    received_at: str
    sim_slot: int = -1
    message_hash: str
    nonce: str
    sent_at: str
    signature: str


class Heartbeat(BaseModel):
    device_id: str
    nonce: str
    sent_at: str
    signature: str
    app_version: str | None = None
    pending: int | None = None
    failed: int | None = None
    synced: int | None = None
    last_sms_at: str | None = None
    battery: int | None = None
    charging: bool | None = None
    connectivity: str | None = None


class AcceptResponse(BaseModel):
    status: str = Field(description="'accepted' or 'duplicate'")
    id: int | None = None


class VersionResponse(BaseModel):
    version: str
    build: int | None = None
    url: str | None = None
    notes: str | None = None
