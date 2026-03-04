# Webhook Relay & Event Inbox

A backend service for receiving, persisting, and reliably delivering inbound webhook events. Events are durably written to PostgreSQL before acknowledgement. Delivery to configured destination URLs is handled asynchronously with retry logic, idempotency enforcement, and a full audit trail of every attempt.

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
| Async delivery worker with exponential backoff | Planned |
| Configurable retry ceiling | Planned |
| Rate limiting per API key (ingestion) and per destination (delivery) | Planned |
| Manual event replay / redelivery | Planned |
| Liveness probe (`GET /healthz`) | **Implemented** |
| Readiness probe (`GET /readyz` — verifies DB pool) | **Implemented** |
| k6 load tests (smoke, sustained, spike) | **Implemented** |
| Ops scripts: audit log export, event export, metrics snapshot, replay, k6 summary | **Implemented** |

---

## Local Setup

### Option A — Docker Compose (recommended)

```bash
cp .env.example .env          # then edit .env and set POSTGRES_PASSWORD
docker compose up --build
```

| Service | Host address |
|---------|-------------|
| API | http://localhost:8001 |
| PostgreSQL | localhost:5433 |

The database schema is applied automatically from `db/init.sql` on first start.

### Option B — manual (venv + local PostgreSQL)

#### 1. Python environment

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

#### 2. Start PostgreSQL

```bash
docker run -d \
  --name webhook-relay-db \
  -e POSTGRES_USER=relay \
  -e POSTGRES_PASSWORD=relay \
  -e POSTGRES_DB=webhook_relay \
  -p 5433:5432 \
  postgres:16
```

#### 3. Run the application

```bash
DATABASE_URL=postgres://relay:relay@localhost:5433/webhook_relay \
  uvicorn app.main:app --reload --port 8001
```

The app starts on **http://localhost:8001**.

> `DATABASE_URL` is required. The app exits at startup if the variable is not set.

---

## Health Checks

| Endpoint | Purpose | Healthy response |
|---|---|---|
| `GET /healthz` | Liveness — process is alive | `200 {"status": "ok"}` |
| `GET /readyz` | Readiness — DB pool is up and responsive | `200 {"status": "ok"}` |

```bash
curl http://localhost:8001/healthz
curl http://localhost:8001/readyz
```

`/readyz` returns `503` if the DB pool is unavailable.

---

## Load Tests (k6)

> Requires [k6](https://k6.io/docs/get-started/installation/) and a running instance with the ingestion endpoint available (see planned features above).

All tests require an `API_KEY` environment variable. Pass `TARGET_URL` to target port 8001 (the k6 scripts default to 8000).

Results are written to `out/` by convention — create it first:

```bash
mkdir -p out
```

### Smoke — basic correctness at low load

10 VUs · 10 seconds · thresholds: <1% errors, p95 <500 ms

```bash
k6 run \
  -e API_KEY=$API_KEY \
  -e TARGET_URL=http://localhost:8001/webhooks/inbound \
  --summary-export=out/smoke_$(date +%Y-%m-%d).json \
  k6/smoke.js
```

### Sustained — steady traffic at expected peak

50 VUs · 2 minutes · thresholds: <5% errors, p95 <500 ms

```bash
k6 run \
  -e API_KEY=$API_KEY \
  -e TARGET_URL=http://localhost:8001/webhooks/inbound \
  --summary-export=out/sustained_$(date +%Y-%m-%d).json \
  k6/sustained.js
```

### Spike — burst at 5× peak load

Ramps 0 → 250 VUs, holds 60 s, ramps back down (~2m10s total). Validates that rate limiting engages and the service recovers cleanly.

```bash
k6 run \
  -e API_KEY=$API_KEY \
  -e TARGET_URL=http://localhost:8001/webhooks/inbound \
  --summary-export=out/spike_$(date +%Y-%m-%d).json \
  k6/spike.js
```

### Convert a result to a Markdown summary

```bash
./scripts/summarize_k6_results.sh \
  --input  out/sustained_$(date +%Y-%m-%d).json \
  --output out/sustained_summary_$(date +%Y-%m-%d).md \
  --label  "Sustained Load — $(date +%Y-%m-%d)"
```

---

## Evidence & Ops Scripts

All scripts in `scripts/` read `DATABASE_URL` from the environment. Outputs go to `out/` by convention.

```bash
mkdir -p out
export DATABASE_URL=postgres://relay:relay@localhost:5432/webhook_relay
```

### Export delivery attempt audit log (CSV)

```bash
./scripts/export_audit_log.sh \
  --from   2026-01-01T00:00:00Z \
  --to     2026-02-24T23:59:59Z \
  --output out/audit_log.csv
```

Optional `--status` filter: `pending` · `succeeded` · `failed` · `dead_lettered`

Generate a chain-of-custody checksum after export:

```bash
sha256sum out/audit_log.csv > out/audit_log.csv.sha256
```

### Export event receipt records (CSV)

```bash
./scripts/export_events.sh \
  --from   2026-01-01T00:00:00Z \
  --to     2026-02-24T23:59:59Z \
  --output out/events.csv
```

Add `--include-payload` to include raw webhook payloads (handle under appropriate data controls).

### Capture a metrics snapshot (JSON)

```bash
METRICS_ENDPOINT=http://localhost:9090 \
  ./scripts/export_metrics.sh \
  --output out/metrics_$(date +%Y%m%d_%H%M%S).json
```

### Manual event replay

Single event:

```bash
ADMIN_API_URL=https://internal.example.com \
ADMIN_API_TOKEN=<token> \
  ./scripts/replay_event.sh \
  --event-id <uuid>
```

Batch replay by source, status, and time window:

```bash
ADMIN_API_URL=https://internal.example.com \
ADMIN_API_TOKEN=<token> \
  ./scripts/replay_event.sh \
  --source-id <id> \
  --status    dead_lettered \
  --from      2026-01-01T00:00:00Z \
  --to        2026-02-24T23:59:59Z
```

---

## Repository Layout

```
app/          FastAPI application (entry point, DB pool, health endpoints)
docs/         Operational runbook, executive summary, evidence index
incidents/    Incident simulation drill outputs
k6/           Load test scripts and results
scripts/      Evidence export and ops automation
```

---

## Documentation

| Document | Purpose |
|---|---|
| `docs/EXEC_SUMMARY.md` | Architecture overview, risk controls, and compliance posture |
| `docs/RUNBOOK.md` | Health checks, alerting thresholds, incident response, evidence collection |
| `docs/EVIDENCE_INDEX.md` | Compliance artifacts checklist with file paths |
