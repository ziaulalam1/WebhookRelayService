import pytest


@pytest.fixture
def valid_payload():
    return {
        "idempotency_key": "test-key-001",
        "data": {"type": "order.created", "order_id": "ord-123"},
    }
