import pytest
from pydantic import ValidationError

from app.webhooks import InboundPayload


def test_minimal_valid_payload(valid_payload):
    p = InboundPayload(**valid_payload)
    assert p.idempotency_key == "test-key-001"
    assert p.event_id is None


def test_event_id_defaults_to_none():
    p = InboundPayload(idempotency_key="k-002", data={})
    assert p.event_id is None


def test_event_id_set():
    p = InboundPayload(event_id="evt-001", idempotency_key="k-003", data={})
    assert p.event_id == "evt-001"


def test_data_accepts_nested_dict():
    p = InboundPayload(
        idempotency_key="k-004",
        data={"order": {"id": "o-1", "amount": 99.95}},
    )
    assert p.data["order"]["id"] == "o-1"


def test_data_accepts_list():
    p = InboundPayload(idempotency_key="k-005", data=[1, 2, 3])
    assert p.data == [1, 2, 3]


def test_missing_idempotency_key_raises():
    with pytest.raises(ValidationError):
        InboundPayload(data={"type": "ping"})
