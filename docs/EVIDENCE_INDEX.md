# Evidence Index — Webhook Relay & Event Inbox

**Document Owner:** Engineering / Compliance
**Classification:** Internal — Confidential
**Last Reviewed:** 2026-03-04
**Review Cadence:** Quarterly or after any material incident

---

## Purpose

This index enumerates every compliance evidence artifact for the Webhook Relay & Event Inbox system. Each entry identifies the artifact's file path, how it is produced, and what compliance question it answers. Examiners and auditors should use this index as the starting point for any evidence request.

---

## Quick Capture (operational snapshot)

Run `scripts/capture_evidence.sh` to produce all five snapshot artifacts in a single step. No credentials are required on the host; all database queries execute inside the running `db` container. API keys are masked to the last 4 characters in every output file.

```bash
mkdir -p out/evidence
./scripts/capture_evidence.sh          # uses project name "centerbridge" by default
./scripts/capture_evidence.sh --project <name>   # override if compose project differs
```

All artifacts land in `out/evidence/` (gitignored). After capture, generate chain-of-custody checksums:

```bash
sha256sum out/evidence/*.txt > out/evidence/checksums.sha256
```

### Snapshot artifacts

| # | Artifact | File Path | What It Proves |
|---|----------|-----------|----------------|
| S-1 | Container status | `out/evidence/compose_ps.txt` | Both `api` and `db` services are running at time of capture |
| S-2 | API container logs | `out/evidence/api_logs_tail.txt` | Last 120 log lines showing startup, request handling, and any errors |
| S-3 | Idempotency proof | `out/evidence/idempotency_proof.txt` | Every `(api_key, idempotency_key)` pair has exactly one row in `events`; `row_count = 1` for all entries proves the UNIQUE constraint is enforced end-to-end |
| S-4 | Audit log tail | `out/evidence/audit_log_tail.txt` | Last 20 `audit_log` rows showing `ingest.received` and `ingest.duplicate` actions with masked actor, entity ID, and per-request trace ID |
| S-5 | API key inventory | `out/evidence/api_keys_inventory.txt` | All rows in `api_keys` with masked key values (`name`, `enabled`); demonstrates least-privilege issuance |

---

## Evidence Checklist

### A. Audit and Delivery Logs

| # | Artifact | File Path | How Produced | What It Proves |
|---|----------|-----------|--------------|----------------|
| A-1 | Audit log snapshot (recent) | `out/evidence/audit_log_tail.txt` | `scripts/capture_evidence.sh` → S-4 | Last 20 ingestion events with action, actor (masked), entity ID, and request ID |
| A-2 | Audit log export (date range) | `docs/evidence/audit_log_<from>_to_<to>.csv` | `scripts/export_audit_log.sh --from <ts> --to <ts> --output <file>` | Full audit record for a requested period |
| A-3 | SHA-256 checksum of log export | `docs/evidence/audit_log_<from>_to_<to>.csv.sha256` | `sha256sum <file> > <file>.sha256` immediately after export | Chain of custody — proves the export has not been altered since creation |
| A-4 | Raw event metadata export | `docs/evidence/events_<from>_to_<to>.csv` | `scripts/export_events.sh --from <ts> --to <ts> --output <file>` | Record of every event received: api_key, receipt timestamp, idempotency key |

---

### B. Access Control

| # | Artifact | File Path | How Produced | What It Proves |
|---|----------|-----------|--------------|----------------|
| B-1 | API key inventory (masked) | `out/evidence/api_keys_inventory.txt` | `scripts/capture_evidence.sh` → S-5 | All authorized keys with masked values (`name`, `enabled`); no raw secrets in the file |
| B-2 | Auth failure log excerpt | `out/evidence/api_logs_tail.txt` | `scripts/capture_evidence.sh` → S-2; filter for `401` | HTTP 401 lines confirm unauthenticated requests are rejected before any database write |
| B-3 | API key rotation record | `docs/evidence/key_rotation_log_<date>.csv` | `audit_log` query filtered for `action IN ('api_key.rotated','api_key.revoked')` | Demonstrates active key hygiene and timely response to suspected compromise |

---

### C. Idempotency and Deduplication

| # | Artifact | File Path | How Produced | What It Proves |
|---|----------|-----------|--------------|----------------|
| C-1 | Idempotency proof | `out/evidence/idempotency_proof.txt` | `scripts/capture_evidence.sh` → S-3 | `row_count = 1` for every `(api_key, idempotency_key)` pair; UNIQUE constraint enforced at the database level |
| C-2 | Deduplication audit entries | `out/evidence/audit_log_tail.txt` | `scripts/capture_evidence.sh` → S-4; filter `action = ingest.duplicate` | Each duplicate submission produces an `ingest.duplicate` audit row with a distinct `request_id`, confirming detection without re-processing |

---

### D. Incident Simulations

| # | Artifact | File Path | How Produced | What It Proves |
|---|----------|-----------|--------------|----------------|
| D-1 | Worker stall drill | `incidents/YYYY-MM-DD_worker_stall.md` | Live drill: kill worker process, measure queue depth growth, restart, verify drain | Demonstrates detection capability and recovery time for worker failure scenario |
| D-2 | Destination outage drill | `incidents/YYYY-MM-DD_destination_outage.md` | Live drill: take destination offline, observe retry backoff behavior, restore, verify replay | Demonstrates retry and replay procedures function as documented; no events permanently lost |
| D-3 | Unauthorized ingestion simulation | `incidents/YYYY-MM-DD_auth_rejection.md` | Live drill: send requests with invalid and missing API keys, confirm 401 responses and no DB writes | Demonstrates authentication boundary is enforced; unauthenticated events cannot enter the system |
| D-4 | Duplicate storm simulation | `incidents/YYYY-MM-DD_duplicate_storm.md` | Live drill: replay same event 100× from a single source, confirm single row in `events` | Demonstrates idempotency holds under sustained duplicate pressure |

---

### E. Load Test Results

| # | Artifact | File Path | Script | What It Proves |
|---|----------|-----------|--------|----------------|
| E-0 | Smoke test report | `k6/results/smoke_<date>.json` | `k6/smoke.js` | Post-deployment correctness at 10 VUs / 10 s; threshold: error rate < 1%, p95 < 500 ms |
| E-1 | Sustained load test report | `k6/results/sustained_<date>.json` | `k6/sustained.js` | System sustains 50 VUs for 2 min without degradation; threshold: error rate < 5%, p95 < 500 ms |
| E-2 | Spike load test report | `k6/results/spike_<date>.json` | `k6/spike.js` | Rate limiting engages at 250 VUs (5× peak); no 5xx errors; service recovers cleanly after spike |
| E-3 | Load test summary (human-readable) | `k6/results/load_test_summary_<date>.md` | `scripts/summarize_k6_results.sh` | Narrative p50/p95/p99, error rate, and throughput for examiner consumption; includes pass/fail verdict |

#### Load Test Run Commands

Replace `$API_KEY` with a valid test-environment API key.

**Smoke (run after every deployment):**
```bash
k6 run \
  -e API_KEY=$API_KEY \
  -e TARGET_URL=http://localhost:8001/webhooks/inbound \
  --summary-export=k6/results/smoke_$(date +%Y-%m-%d).json \
  k6/smoke.js
```

**Sustained (run before release or quarterly as evidence):**
```bash
k6 run \
  -e API_KEY=$API_KEY \
  -e TARGET_URL=http://localhost:8001/webhooks/inbound \
  --summary-export=k6/results/sustained_$(date +%Y-%m-%d).json \
  k6/sustained.js
```

**Spike (run quarterly or before capacity changes):**
```bash
k6 run \
  -e API_KEY=$API_KEY \
  -e TARGET_URL=http://localhost:8001/webhooks/inbound \
  --summary-export=k6/results/spike_$(date +%Y-%m-%d).json \
  k6/spike.js
```

**Generate human-readable summary:**
```bash
./scripts/summarize_k6_results.sh \
  --input  k6/results/sustained_$(date +%Y-%m-%d).json \
  --output k6/results/load_test_summary_$(date +%Y-%m-%d).md \
  --label  "Sustained Load — $(date +%Y-%m-%d)"
```

---

### F. Metrics and Observability

| # | Artifact | File Path | How Produced | What It Proves |
|---|----------|-----------|--------------|----------------|
| F-1 | Metric snapshot | `docs/evidence/metrics_snapshot_<datetime>.json` | `scripts/export_metrics.sh` | Point-in-time capture of ingestion rate, delivery success rate, queue depth, retry counts, and latency percentiles |
| F-2 | Alert configuration export | `docs/evidence/alert_config_<date>.json` | Export from alerting system | Documents thresholds configured to detect delivery failures, queue stalls, and auth anomalies |

---

### G. Evidence Archive

| # | Artifact | File Path | How Produced | What It Proves |
|---|----------|-----------|--------------|----------------|
| G-1 | Snapshot archive | `out/evidence_package_<datetime>.tar.gz` | `tar -czf out/evidence_package_$(date +%Y%m%d_%H%M%S).tar.gz out/evidence/` | Compressed archive of all snapshot artifacts for examiner delivery |
| G-2 | Archive checksum | `out/evidence_package_checksums.sha256` | `sha256sum out/evidence_package_*.tar.gz > out/evidence_package_checksums.sha256` | Proves archive integrity at time of transmission |

---

## Evidence Production Checklist (for Regulatory Requests)

Use this checklist when preparing a response to a regulatory inquiry or internal audit.

- [ ] Confirm date range of the request and note it in writing
- [ ] Run `scripts/capture_evidence.sh` → S-1 through S-5
- [ ] Generate checksums: `sha256sum out/evidence/*.txt > out/evidence/checksums.sha256`
- [ ] Run `scripts/export_audit_log.sh` for the full requested period → A-2
- [ ] Generate checksum immediately after export → A-3
- [ ] Run `scripts/export_events.sh` for the same period → A-4
- [ ] Copy relevant incident simulation reports from `incidents/` → D-1 through D-4
- [ ] Copy latest load test reports from `k6/results/` → E-0, E-1, E-2, E-3
- [ ] Run `scripts/export_metrics.sh` → F-1
- [ ] Package all artifacts into a timestamped archive → G-1
- [ ] Generate archive checksum → G-2
- [ ] Record the names of individuals who produced, reviewed, and transmitted the package
- [ ] Transmit only over encrypted channel; log transmission timestamp and recipient
