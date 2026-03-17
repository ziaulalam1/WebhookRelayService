# Webhook Relay & Event Inbox

Receives inbound webhooks, writes them durably to PostgreSQL, and delivers them to configured destinations. Every event is persisted before the `202` goes back to the caller. Retries, idempotency dedup, and a full audit trail are built in.

Reliable event ingestion matters more when downstream consumers are non-deterministic — if an AI pipeline, async worker, or external model processes an event twice or misses one, the error is silent and hard to trace. This service makes the ingestion layer the one thing you can trust.

**Stack:** Python 3 · FastAPI · asyncpg · PostgreSQL · k6

---

## Features

| Feature | Status |
|---|---|
| Inbound webhook ingestion (`POST /webhooks/inbound`) | **Implemented** |
| API key authentication (`X-API-Key` header, `api_keys` table) | **Implemented** |
| Idempotency deduplication by `(api_key, idempotency_key)` | **Implemented** |
| Durable event persistence before acknowledgement | **Implemented** |
| Append-only audit log (`audit_log` table) | **Implemented** |
| Liveness probe (`GET /healthz`) | **Implemented** |
| Readiness probe (`GET /readyz` — verifies DB pool) | **Implemented** |
| k6 load tests (smoke, sustained, spike) | **Implemented** |
| Ops scripts: audit log export, event export, metrics snapshot, replay, k6 summary | **Implemented** |
| Async delivery worker with exponential backoff | Planned |
| Configurable retry ceiling | Planned |
| Rate limiting per API key and per destination | Planned |
| Manual event replay / redelivery | Planned |

---

## Local Setup

### Docker Compose (recommended)

```bash
cp .env.example .env
docker compose -p webhook-relay up --build
```

| Service | Host |
|---------|------|
| API | http://localhost:8001 |
| PostgreSQL | localhost:5433 (container: `db:5432`) |

Schema is applied from `db/init.sql` on first start. `dev-key-1` is seeded automatically.

### Manual (venv + local PostgreSQL)

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

docker run -d \
  --name webhook-relay-db \
  -e POSTGRES_USER=relay \
  -e POSTGRES_PASSWORD=relay \
  -e POSTGRES_DB=webhook_relay \
  -p 5433:5432 \
  postgres:16

DATABASE_URL=postgresql://relay:relay@localhost:5433/webhook_relay \
  uvicorn app.main:app --reload --port 8001
```

> `DATABASE_URL` is required — the app exits at startup if it's not set.

---

## Health Checks

| Endpoint | Purpose | Healthy response |
|---|---|---|
| `GET /healthz` | Liveness — process is alive | `200 {"status": "ok"}` |
| `GET /readyz` | Readiness — DB pool is responsive | `200 {"status": "ok"}` |

```bash
curl http://localhost:8001/healthz
curl http://localhost:8001/readyz
```

`/readyz` returns `503` if the DB pool is down.

---

## Ingestion

### Send an event

```bash
curl -s -X POST http://localhost:8001/webhooks/inbound \
  -H "Content-Type: application/json" \
  -H "X-API-Key: dev-key-1" \
  -d '{"idempotency_key":"evt-001","data":{"hello":"world"}}' | jq .
```

```json
{ "event_id": "<uuid>", "duplicate": false }
```

### Same call again — idempotency

```bash
curl -s -X POST http://localhost:8001/webhooks/inbound \
  -H "Content-Type: application/json" \
  -H "X-API-Key: dev-key-1" \
  -d '{"idempotency_key":"evt-001","data":{"hello":"world"}}' | jq .
```

Same `event_id` comes back, no second row written:

```json
{ "event_id": "<same-uuid>", "duplicate": true }
```

### Bad key — rejected before any DB write

```bash
curl -s -X POST http://localhost:8001/webhooks/inbound \
  -H "Content-Type: application/json" \
  -H "X-API-Key: bad-key" \
  -d '{"idempotency_key":"x","data":{}}' | jq .
# → 401 {"detail":"Invalid or disabled API key"}
```

---

## Evidence & Ops

### Capture evidence

```bash
make evidence
```

Writes five timestamped files to `out/evidence/` and generates `out/evidence/checksums.sha256`. `out/` is in `.gitignore` — nothing here gets committed.

| File | Contents |
|---|---|
| `compose_ps.txt` | Container status |
| `api_logs_tail.txt` | Last 120 API log lines |
| `idempotency_proof.txt` | `events` grouped by `(api_key, idempotency_key)` — `row_count` must be 1 for every pair |
| `audit_log_tail.txt` | Last 20 `audit_log` rows, actor masked |
| `api_keys_inventory.txt` | All `api_keys` rows, key values masked to last 4 chars |

### Pre-push scrub

```bash
make scrub
```

Scans filenames and file contents for policy-violating strings. Exits non-zero on any hit.

### Export audit log (CSV)

```bash
export DATABASE_URL=postgresql://relay:relay@localhost:5433/webhook_relay

./scripts/export_audit_log.sh \
  --from   2026-01-01T00:00:00Z \
  --to     2026-02-24T23:59:59Z \
  --output out/audit_log.csv

shasum -a 256 out/audit_log.csv > out/audit_log.csv.sha256
```

Optional `--status` filter: `pending` · `succeeded` · `failed` · `dead_lettered`

### Export event records (CSV)

```bash
./scripts/export_events.sh \
  --from   2026-01-01T00:00:00Z \
  --to     2026-02-24T23:59:59Z \
  --output out/events.csv
```

Add `--include-payload` to include raw payloads.

---

## Load Tests (k6)

Requires [k6](https://k6.io/docs/get-started/installation/) and a running stack.

```bash
mkdir -p out

# Smoke — 10 VUs · 10 s · <1% errors · p95 <500 ms
k6 run \
  -e API_KEY=dev-key-1 \
  -e TARGET_URL=http://localhost:8001/webhooks/inbound \
  --summary-export=out/smoke_$(date +%Y-%m-%d).json \
  k6/smoke.js

# Sustained — 50 VUs · 2 min · <5% errors · p95 <500 ms
k6 run \
  -e API_KEY=dev-key-1 \
  -e TARGET_URL=http://localhost:8001/webhooks/inbound \
  --summary-export=out/sustained_$(date +%Y-%m-%d).json \
  k6/sustained.js

# Spike — ramp to 250 VUs · ~2m10s total
k6 run \
  -e API_KEY=dev-key-1 \
  -e TARGET_URL=http://localhost:8001/webhooks/inbound \
  --summary-export=out/spike_$(date +%Y-%m-%d).json \
  k6/spike.js
```

---

## Repository Layout

```
app/          FastAPI app — entry point, DB pool, health, ingestion
db/           init.sql applied on first container start
docs/         Runbook, executive summary, evidence index
incidents/    Incident drill outputs
k6/           Load test scripts
scripts/      Evidence capture, export, and ops
Makefile      evidence and scrub targets
```

---

## Documentation

| Document | Purpose |
|---|---|
| `docs/EXEC_SUMMARY.md` | Architecture, risk controls, compliance posture |
| `docs/RUNBOOK.md` | Health checks, incident response, evidence collection |
| `docs/EVIDENCE_INDEX.md` | Compliance artifacts checklist with file paths |
