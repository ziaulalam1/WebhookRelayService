# Runbook — Webhook Relay & Event Inbox

**Document Owner:** Engineering
**Classification:** Internal — Confidential
**Last Reviewed:** 2026-02-24

---

## 1. System Health Verification

Run these checks at the start of any on-call shift, after a deployment, or when an alert fires.

### 1.1 Liveness and Readiness

```bash
# Service is alive
curl -sf http://localhost:8001/healthz && echo "OK"

# Service is ready (DB connection pool reachable and responsive)
curl -sf http://localhost:8001/readyz && echo "OK"
```

Expected: HTTP 200 with `{"status":"ok"}`. Any non-200 or connection refused is an incident.

### 1.2 Queue Depth

```sql
-- Events received but not yet successfully delivered
SELECT COUNT(*) AS pending_deliveries
FROM delivery_attempts
WHERE status = 'pending'
   OR (status = 'failed' AND attempt_number < max_attempts);
```

Expected: queue drains to near-zero within 60 seconds of ingestion under normal load. Sustained depth above 500 warrants investigation.

### 1.3 Retry Backlog

```sql
-- Events that have exhausted retries (dead-lettered)
SELECT source_id, COUNT(*) AS dead_letter_count
FROM delivery_attempts
WHERE status = 'failed' AND attempt_number >= max_attempts
  AND created_at > NOW() - INTERVAL '24 hours'
GROUP BY source_id
ORDER BY dead_letter_count DESC;
```

Expected: zero in steady state. Any non-zero result requires operator review and may require manual replay.

### 1.4 Recent Ingestion Rate

```sql
-- Events received in last 5 minutes
SELECT COUNT(*) AS recent_events
FROM events
WHERE created_at > NOW() - INTERVAL '5 minutes';
```

Cross-reference against expected upstream send rate. A drop to zero during business hours is an alert condition.

### 1.5 Delivery Success Rate (Last Hour)

```sql
SELECT
  status,
  COUNT(*) AS count,
  ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2) AS pct
FROM delivery_attempts
WHERE created_at > NOW() - INTERVAL '1 hour'
GROUP BY status;
```

Expected: `succeeded` >= 98%. Failure rate above 5% sustained for more than 10 minutes is an incident.

---

## 2. Logs and Metrics to Check

### 2.1 Structured Log Fields

All application log lines are emitted as JSON. Key fields to filter on:

| Field | What to look for |
|-------|-----------------|
| `request_id` | Trace a single event end-to-end across all log lines |
| `source_id` | Filter activity for a specific upstream sender |
| `event` | `ingestion.received`, `ingestion.duplicate`, `delivery.attempt`, `delivery.succeeded`, `delivery.failed`, `delivery.dead_lettered`, `rate_limit.enforced` |
| `attempt_number` | Values > 3 indicate persistent delivery problems |
| `http_status` | Non-2xx from destination URLs |
| `duration_ms` | p95 above 2000 ms on ingestion or delivery warrants review |
| `idempotency_key` | Presence of `ingestion.duplicate` events at unexpected volume may indicate upstream retry storms |

**Sample query against the audit_log table:**

```sql
SELECT ts, action, actor, entity_id, request_id
FROM audit_log
WHERE action LIKE 'ingest.%'
  AND ts > NOW() - INTERVAL '1 hour'
ORDER BY ts DESC
LIMIT 100;
```

### 2.2 Metrics to Check

| Metric | Alert Threshold | Notes |
|--------|----------------|-------|
| `webhook.ingestion.rate` | < 0 events/min sustained 5 min during business hours | Possible upstream outage or auth key revocation |
| `webhook.delivery.success_rate` | < 95% over 10 min window | Destination URL unreachable or returning errors |
| `webhook.queue.depth` | > 1000 pending | Worker may be stalled or under-provisioned |
| `webhook.retry.dead_letter_count` | > 0 in any 1 hour window | Manual review and possible replay required |
| `webhook.rate_limit.enforced_count` | Spike > 50/min from a single source | Potential misconfigured or misbehaving sender |
| `http.p95_latency_ms` (ingestion) | > 500 ms | DB write bottleneck or connection pool exhaustion |

---

## 3. Incident Response

### 3.1 Delivery Worker Stalled (Queue Depth Growing, No Deliveries)

**Detection:** Queue depth metric rising; `delivery.attempt` log events absent; `delivery.succeeded` counter flat.

**Steps:**
1. Check worker process health: `ps aux | grep worker` or check the process supervisor / container status.
2. Check worker logs for panic, OOM, or unhandled exception.
3. Check Postgres connectivity from the worker host:
   ```bash
   psql $DATABASE_URL -c "SELECT 1;"
   ```
4. Check destination URL reachability:
   ```bash
   curl -I https://destination.example.com/webhook
   ```
5. If worker is dead, restart it. Document restart time and cause in the incident log.
6. Verify queue begins draining within 2 minutes of restart.
7. Run the retry backlog query (Section 1.3) to confirm no events were dead-lettered during the outage window.
8. For any dead-lettered events, trigger manual replay (Section 3.4).

### 3.2 Elevated Delivery Failure Rate (Destination Returning Errors)

**Detection:** `delivery.failed` log events; HTTP status 4xx or 5xx in delivery attempt logs; success rate metric below threshold.

**Steps:**
1. Identify the failing destination:
   ```sql
   SELECT destination_url, http_status, COUNT(*)
   FROM delivery_attempts
   WHERE status = 'failed' AND created_at > NOW() - INTERVAL '30 minutes'
   GROUP BY destination_url, http_status
   ORDER BY COUNT(*) DESC;
   ```
2. Confirm whether the destination is externally reachable. Contact the destination team if needed.
3. Do not manually replay until the destination confirms it is healthy — replaying into a broken destination generates additional failed attempts and may exhaust retry budget.
4. Once destination is healthy, replay affected events using the procedure in Section 3.4.
5. Confirm delivery attempts succeed post-replay.

### 3.3 Duplicate Events Arriving at Unexpected Volume

**Detection:** `ingestion.duplicate` log event count spikes; same idempotency key appearing multiple times in `events` table.

**Steps:**
1. Identify the source:
   ```sql
   SELECT api_key, idempotency_key, COUNT(*) AS duplicate_count
   FROM audit_log
   WHERE action = 'ingest.duplicate'
     AND ts > NOW() - INTERVAL '1 hour'
   GROUP BY api_key, idempotency_key
   ORDER BY duplicate_count DESC;
   ```
2. Confirm idempotency deduplication is suppressing reprocessing (check that downstream delivery count matches expected, not raw ingestion count).
3. Notify the upstream source team of their retry storm. No corrective action on the relay is required if deduplication is functioning correctly.
4. Document volume, source, and duration for the incident record.

### 3.4 Manual Event Replay

Use the replay procedure when events must be redelivered after a destination outage or mis-configuration.

```bash
# Replay a single event by event ID
./scripts/replay_event.sh --event-id <uuid> --destination-url <url>

# Replay all dead-lettered events for a source in a time window
./scripts/replay_event.sh \
  --source-id <source_id> \
  --status dead_lettered \
  --from "2026-02-24T00:00:00Z" \
  --to   "2026-02-24T06:00:00Z"
```

Each replay creates a new delivery attempt record. The original event record is not modified. Confirm successful delivery by querying:

```sql
SELECT event_id, attempt_number, status, http_status, created_at
FROM delivery_attempts
WHERE event_id = '<uuid>'
ORDER BY created_at DESC;
```

### 3.5 Unauthorized Ingestion Attempt

**Detection:** HTTP 401 responses on `POST /webhooks/inbound`; no `audit_log` row written (auth is rejected before any DB write).

**Steps:**
1. Identify the source IP and claimed source identifier from logs.
2. Confirm no data was written (auth rejection occurs before any database write).
3. If attempts are sustained, apply IP-level block at the gateway or firewall layer.
4. Escalate to the security team if the source identity suggests a leaked or compromised API key.
5. Rotate the affected API key immediately if compromise is suspected. Key rotation does not affect already-persisted events.

---

## 4. Evidence Collection

Run these steps to produce a complete, timestamped evidence package for a regulatory request, audit, or post-incident review.

### 4.1 Export Audit / Delivery Attempt Log

```bash
# Exports all delivery attempts for a date range to a signed, timestamped CSV
./scripts/export_audit_log.sh \
  --from "2026-01-01T00:00:00Z" \
  --to   "2026-02-24T23:59:59Z" \
  --output docs/evidence/audit_log_2026-01-01_to_2026-02-24.csv

# Produce a SHA-256 checksum of the export for chain-of-custody
sha256sum docs/evidence/audit_log_2026-01-01_to_2026-02-24.csv \
  > docs/evidence/audit_log_2026-01-01_to_2026-02-24.csv.sha256
```

Fields included in export: `event_id`, `source_id`, `destination_url`, `attempt_number`, `http_status`, `status`, `duration_ms`, `created_at`, `request_id`.

### 4.2 Export Raw Event Records

```bash
# Export raw event metadata (no payload data unless specifically required)
./scripts/export_events.sh \
  --from "2026-01-01T00:00:00Z" \
  --to   "2026-02-24T23:59:59Z" \
  --output docs/evidence/events_2026-01-01_to_2026-02-24.csv
```

### 4.3 Capture Metric Snapshots

```bash
# Export current metric values to a JSON snapshot
./scripts/export_metrics.sh --output docs/evidence/metrics_snapshot_$(date +%Y%m%d_%H%M%S).json
```

### 4.4 Export Incident Simulation Reports

Incident simulation outputs are stored in `incidents/`. Each file is named by drill date and scenario:

```
incidents/YYYY-MM-DD_<scenario>.md
```

Copy relevant files to `docs/evidence/` before packaging for examiner delivery.

### 4.5 Package Evidence Archive

```bash
# Create a timestamped, compressed archive of all evidence
tar -czf evidence_package_$(date +%Y%m%d_%H%M%S).tar.gz docs/evidence/
sha256sum evidence_package_*.tar.gz > evidence_package_checksums.sha256
```

Retain both the archive and its checksum file. Provide both to the requesting examiner. Do not transmit the archive over unencrypted channels.
