# Runbook — Webhook Relay & Event Inbox

**Document Owner:** Engineering
**Classification:** Internal — Confidential
**Last Reviewed:** 2026-03-04

---

## 0. Starting the Stack

```bash
cp .env.example .env          # first time only
docker compose -p webhook-relay up --build
```

| Service | Host | Container |
|---------|------|-----------|
| API | http://localhost:8001 | port 8000 |
| PostgreSQL | localhost:5433 | `db:5432` |

---

## 1. Health Verification

Run after every deployment, at shift start, or when an alert fires.

### 1.1 Liveness and Readiness

```bash
curl -sf http://localhost:8001/healthz && echo "OK"
curl -sf http://localhost:8001/readyz && echo "OK"
```

Both should return `200 {"status":"ok"}`. Non-200 or connection refused is an incident.

### 1.2 Recent Ingestion Rate

```sql
SELECT COUNT(*) AS recent_events
FROM events
WHERE created_at > NOW() - INTERVAL '5 minutes';
```

Compare against expected upstream send rate. Zero for 5+ minutes during business hours needs investigation.

### 1.3 Idempotency Check

```sql
-- should always return zero rows
SELECT api_key, idempotency_key, COUNT(*) AS row_count
FROM events
GROUP BY api_key, idempotency_key
HAVING COUNT(*) > 1;
```

### 1.4 Recent Audit Activity

```sql
SELECT ts, action, entity_id, request_id
FROM audit_log
WHERE ts > NOW() - INTERVAL '5 minutes'
ORDER BY ts DESC
LIMIT 50;
```

### 1.5 Queue Depth and Delivery Success Rate

> Applies once the async delivery worker is deployed.

```sql
-- pending deliveries
SELECT COUNT(*) AS pending_deliveries
FROM delivery_attempts
WHERE status = 'pending'
   OR (status = 'failed' AND attempt_number < max_attempts);
```

```sql
-- success rate last hour
SELECT
  status,
  COUNT(*) AS count,
  ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2) AS pct
FROM delivery_attempts
WHERE created_at > NOW() - INTERVAL '1 hour'
GROUP BY status;
```

Target: `succeeded` >= 98%. Failure rate above 5% for more than 10 minutes is an incident.

---

## 2. Logs and Metrics

### 2.1 Audit Log Fields

| Field | What to look for |
|-------|-----------------|
| `request_id` | Trace a single event end-to-end |
| `actor` | API key (masked) that submitted the request |
| `action` | `ingest.received`, `ingest.duplicate` |
| `entity_id` | UUID of the affected event |
| `idempotency_key` | Spike in `ingest.duplicate` may indicate an upstream retry storm |

```sql
SELECT ts, action, actor, entity_id, request_id
FROM audit_log
WHERE action LIKE 'ingest.%'
  AND ts > NOW() - INTERVAL '1 hour'
ORDER BY ts DESC
LIMIT 100;
```

### 2.2 Alert Thresholds

| Metric | Threshold | Notes |
|--------|-----------|-------|
| Ingestion rate | Zero for 5 min during business hours | Upstream outage or key revoked |
| Delivery success rate | < 95% over 10 min | Destination unreachable |
| Queue depth | > 1000 pending | Worker stalled or under-provisioned |
| Dead-letter count | > 0 per hour | Manual review required |
| Ingestion p95 latency | > 500 ms | DB bottleneck or pool exhaustion |

---

## 3. Incident Response

### 3.1 Delivery Worker Stalled

> Applies once the async delivery worker is deployed.

**Signs:** queue depth growing, no delivery audit events, succeeded counter flat.

1. Check worker process: `ps aux | grep worker` or inspect the container.
2. Check worker logs for panic, OOM, or unhandled exception.
3. Check DB connectivity: `psql $DATABASE_URL -c "SELECT 1;"`
4. Check destination reachability: `curl -I https://destination.example.com/webhook`
5. Restart if dead. Note restart time in the incident log.
6. Confirm queue starts draining within 2 minutes.

### 3.2 Elevated Delivery Failure Rate

> Applies once the async delivery worker is deployed.

**Signs:** 4xx/5xx in delivery logs, success rate below threshold.

1. Find the failing destination:
   ```sql
   SELECT destination_url, http_status, COUNT(*)
   FROM delivery_attempts
   WHERE status = 'failed' AND created_at > NOW() - INTERVAL '30 minutes'
   GROUP BY destination_url, http_status
   ORDER BY COUNT(*) DESC;
   ```
2. Check whether the destination is reachable. Contact that team if not.
3. Don't replay until the destination is confirmed healthy — replaying into a broken endpoint burns retry budget.
4. Once healthy, replay via Section 3.4.

### 3.3 Duplicate Storm

**Signs:** `ingest.duplicate` audit rows spiking.

1. Find the source:
   ```sql
   SELECT actor, idempotency_key, COUNT(*) AS duplicate_count
   FROM audit_log
   WHERE action = 'ingest.duplicate'
     AND ts > NOW() - INTERVAL '1 hour'
   GROUP BY actor, idempotency_key
   ORDER BY duplicate_count DESC;
   ```
2. Verify dedup is working: delivery count should match original ingestion count, not raw submission count.
3. Notify the upstream team — no relay-side action needed if dedup is functioning.
4. Document volume, source, and duration.

### 3.4 Manual Replay

```bash
# single event
./scripts/replay_event.sh --event-id <uuid> --destination-url <url>

# batch by source and time window
./scripts/replay_event.sh \
  --source-id <source_id> \
  --status dead_lettered \
  --from "2026-02-24T00:00:00Z" \
  --to   "2026-02-24T06:00:00Z"
```

### 3.5 Unauthorized Ingestion Attempt

**Signs:** HTTP 401 on `POST /webhooks/inbound`. Auth is rejected before any DB write, so no `audit_log` row will exist for the request.

1. Identify the source IP and claimed key from logs.
2. Confirm no data was written.
3. Block at the gateway if attempts are sustained.
4. Escalate to security if a key compromise is suspected.
5. Rotate the affected key immediately. Already-persisted events are unaffected.

---

## 4. Evidence Collection

### 4.1 Quick Capture

```bash
make evidence
```

Writes to `out/evidence/` (gitignored — local only, never committed) and produces `out/evidence/checksums.sha256`.

| File | Contents |
|---|---|
| `compose_ps.txt` | Container status at capture time |
| `api_logs_tail.txt` | Last 120 API log lines |
| `idempotency_proof.txt` | `events` grouped by `(api_key, idempotency_key)` — `row_count = 1` for all entries |
| `audit_log_tail.txt` | Last 20 `audit_log` rows, actor masked |
| `api_keys_inventory.txt` | All `api_keys` rows, key masked to last 4 chars |

### 4.2 Export Audit Log (CSV)

```bash
export DATABASE_URL=postgresql://relay:relay@localhost:5433/webhook_relay

./scripts/export_audit_log.sh \
  --from "2026-01-01T00:00:00Z" \
  --to   "2026-02-24T23:59:59Z" \
  --output out/audit_log_2026-01-01_to_2026-02-24.csv

shasum -a 256 out/audit_log_2026-01-01_to_2026-02-24.csv \
  > out/audit_log_2026-01-01_to_2026-02-24.csv.sha256
```

### 4.3 Export Event Records (CSV)

```bash
./scripts/export_events.sh \
  --from "2026-01-01T00:00:00Z" \
  --to   "2026-02-24T23:59:59Z" \
  --output out/events_2026-01-01_to_2026-02-24.csv
```

### 4.4 Metrics Snapshot

```bash
./scripts/export_metrics.sh \
  --output out/metrics_snapshot_$(date +%Y%m%d_%H%M%S).json
```

### 4.5 Package for Delivery

```bash
tar -czf out/evidence_package_$(date +%Y%m%d_%H%M%S).tar.gz out/evidence/
shasum -a 256 out/evidence_package_*.tar.gz > out/evidence_package_checksums.sha256
```

Keep both the archive and its checksum. Send over encrypted channels only; log the timestamp and recipient.
