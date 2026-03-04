-- Webhook Relay & Event Inbox — database schema
-- Applied automatically on first container start via /docker-entrypoint-initdb.d/

-- ---------------------------------------------------------------------------
-- api_keys
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS api_keys (
    key     TEXT    PRIMARY KEY,
    name    TEXT    NOT NULL,
    enabled BOOLEAN NOT NULL DEFAULT TRUE
);

-- Seed a development key that works out of the box.
INSERT INTO api_keys (key, name, enabled)
VALUES ('dev-key-1', 'dev', TRUE)
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- events
-- One row per unique (api_key, idempotency_key) pair.
-- The unique constraint is the idempotency guard — duplicate requests hit
-- ON CONFLICT DO NOTHING and the original row is returned.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS events (
    id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    api_key          TEXT        NOT NULL REFERENCES api_keys (key),
    idempotency_key  TEXT        NOT NULL,
    payload_json     JSONB       NOT NULL,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    status           TEXT        NOT NULL DEFAULT 'received',
    CONSTRAINT events_api_key_idempotency_key UNIQUE (api_key, idempotency_key)
);

CREATE INDEX IF NOT EXISTS events_api_key_idx    ON events (api_key);
CREATE INDEX IF NOT EXISTS events_created_at_idx ON events (created_at);
CREATE INDEX IF NOT EXISTS events_status_idx     ON events (status);

-- ---------------------------------------------------------------------------
-- audit_log
-- Append-only structured event log.  Every ingest (original or duplicate)
-- produces one row.  Never update or delete rows here.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit_log (
    id          BIGSERIAL   PRIMARY KEY,
    ts          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    actor       TEXT,                   -- api_key that performed the action
    action      TEXT        NOT NULL,   -- e.g. ingest.received, ingest.duplicate
    entity_type TEXT        NOT NULL,   -- e.g. event
    entity_id   TEXT,                   -- UUID of the affected event
    request_id  TEXT,                   -- per-request trace ID
    prev_json   JSONB,
    new_json    JSONB
);

CREATE INDEX IF NOT EXISTS audit_log_ts_idx          ON audit_log (ts);
CREATE INDEX IF NOT EXISTS audit_log_actor_idx       ON audit_log (actor);
CREATE INDEX IF NOT EXISTS audit_log_entity_idx      ON audit_log (entity_type, entity_id);
CREATE INDEX IF NOT EXISTS audit_log_request_id_idx  ON audit_log (request_id);
