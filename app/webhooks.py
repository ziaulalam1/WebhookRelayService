import json
import uuid
from typing import Any

from fastapi import APIRouter, Header, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from app.database import get_pool

router = APIRouter()


class InboundPayload(BaseModel):
    event_id: str | None = None
    idempotency_key: str
    data: Any


async def _authenticate(api_key: str, conn) -> None:
    """Raise 401 if the key is unknown or disabled."""
    row = await conn.fetchrow(
        "SELECT 1 FROM api_keys WHERE key = $1 AND enabled = TRUE",
        api_key,
    )
    if row is None:
        raise HTTPException(status_code=401, detail="Invalid or disabled API key")


@router.post("/webhooks/inbound", status_code=202)
async def inbound(
    body: InboundPayload,
    request: Request,
    x_api_key: str = Header(...),
):
    request_id = str(uuid.uuid4())
    pool = get_pool()

    async with pool.acquire() as conn:
        await _authenticate(x_api_key, conn)

        # Build the stored payload from the caller-supplied fields.
        payload = {"data": body.data}
        if body.event_id is not None:
            payload["event_id"] = body.event_id

        row = await conn.fetchrow(
            """
            INSERT INTO events (api_key, idempotency_key, payload_json, status)
            VALUES ($1, $2, $3::jsonb, 'received')
            ON CONFLICT (api_key, idempotency_key) DO NOTHING
            RETURNING id
            """,
            x_api_key,
            body.idempotency_key,
            json.dumps(payload),
        )

        if row is None:
            # Duplicate — fetch the existing row's ID to echo back.
            existing = await conn.fetchrow(
                "SELECT id FROM events WHERE api_key = $1 AND idempotency_key = $2",
                x_api_key,
                body.idempotency_key,
            )
            event_id = str(existing["id"])
            is_duplicate = True
            action = "ingest.duplicate"
        else:
            event_id = str(row["id"])
            is_duplicate = False
            action = "ingest.received"

        await conn.execute(
            """
            INSERT INTO audit_log
                (actor, action, entity_type, entity_id, request_id, new_json)
            VALUES ($1, $2, 'event', $3, $4, $5::jsonb)
            """,
            x_api_key,
            action,
            event_id,
            request_id,
            json.dumps({"idempotency_key": body.idempotency_key, "duplicate": is_duplicate}),
        )

    return JSONResponse(
        status_code=202,
        content={"event_id": event_id, "duplicate": is_duplicate},
    )
