import pytest
from pydantic import ValidationError

from app.webhooks import InboundPayload


def test_idempotency_key_empty_string():
    p = InboundPayload(idempotency_key="", data={})
    assert p.idempotency_key == ""


def test_data_accepts_integer():
    p = InboundPayload(idempotency_key="k-int", data=42)
    assert p.data == 42


def test_data_accepts_boolean():
    p = InboundPayload(idempotency_key="k-bool", data=True)
    assert p.data is True


def test_event_id_none_by_default():
    p = InboundPayload(idempotency_key="k-default", data={})
    assert p.event_id is None


def test_payload_fields():
    p = InboundPayload(idempotency_key="k-fields", data={"x": 1})
    assert set(p.model_fields.keys()) == {"event_id", "idempotency_key", "data"}
