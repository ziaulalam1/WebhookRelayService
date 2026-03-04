# Executive Summary — Webhook Relay & Event Inbox

**Document Owner:** Engineering / Compliance
**Classification:** Internal — Confidential
**Last Reviewed:** 2026-02-24
**Review Cadence:** Quarterly

---

## What the System Does

The Webhook Relay & Event Inbox is a backend service that receives inbound webhook events from authorized external sources, persists them durably in PostgreSQL, and delivers them asynchronously to configured internal destination URLs via a background worker.

Each inbound source authenticates with a unique API key. On receipt, the service stores both the raw payload and parsed fields before acknowledgement — ensuring no event is accepted and silently lost. Delivery to destination URLs is attempted asynchronously with exponential backoff and a configurable maximum retry ceiling. Every delivery attempt (success or failure) is recorded. Operators can inspect events through a minimal inbox UI and manually trigger replay or redelivery of any past event.

Idempotency is enforced by deduplicating on a composite key of source identifier and caller-supplied idempotency key, preventing duplicate events from producing duplicate side-effects even under network retry conditions. Rate limiting is applied per API key at ingestion and per destination at delivery, protecting both the relay itself and downstream systems from traffic spikes.

---

## Risks Reduced

| Risk | Control |
|------|---------|
| Unauthorized event ingestion from unknown sources | Per-source API key authentication; requests without a valid key are rejected at the boundary with no data written |
| Silent event loss on transient downstream failures | Async worker with exponential backoff retries; raw event persisted to Postgres before delivery is attempted |
| Duplicate event processing causing double-actions | Idempotency deduplication by `(source_id, idempotency_key)`; duplicates are detected and short-circuited before worker enqueue |
| Inability to reconstruct what was received and when | Raw payload stored verbatim alongside parsed fields, receipt timestamp, and source identity |
| Undetected delivery failures | Every delivery attempt logged with HTTP status, latency, attempt number, and outcome; alert thresholds on sustained failure rates |
| Destination or source overload | Per-API-key ingestion rate limits; per-destination delivery rate limits enforced in worker |
| Inability to recover from mis-routed or dropped events | Replay and redelivery available to authorized operators for any persisted event, with the resulting attempt recorded in the delivery log |

---

## Controls

**Access Control**
API keys are issued per source. Each key is scoped to a single source identity and can be rotated or revoked independently without affecting other sources. No unauthenticated requests reach storage or worker queues.

**Audit and Delivery Log**
Every delivery attempt — including timestamp, destination URL, HTTP response code, attempt number, and final disposition — is written to a structured log table in Postgres. This log is append-only at the application layer. Manual replays create new delivery attempt records rather than mutating existing ones, preserving the original history.

**Traceability**
Every inbound request is assigned a unique `X-Request-ID` at the boundary. This identifier propagates through the persistence layer, worker, and delivery attempt records. A single request ID is sufficient to reconstruct the full lifecycle of any event across logs, database records, and metrics.

**Idempotency**
Duplicate submissions identified by `(source_id, idempotency_key)` are acknowledged to the caller but not re-processed, providing a safe retry surface for upstream senders without risk of duplication in downstream systems.

**Structured Logging and Metrics**
All application events (ingestion, enqueue, delivery attempt, retry schedule, deduplication hit, rate limit enforcement) are emitted as structured JSON with consistent field names. Basic metrics (ingestion rate, delivery success/failure rate, queue depth, retry count, p95 latency) are tracked and exposed for alerting.

---

## Supporting Evidence

| Artifact | Path | Purpose |
|----------|------|---------|
| Operational Runbook | `docs/RUNBOOK.md` | Health verification, log and metric checks, incident response, evidence export |
| Evidence Index | `docs/EVIDENCE_INDEX.md` | Enumerated compliance artifacts with file paths and what each proves |
| Incident Simulation Outputs | `incidents/` | Drill results demonstrating detection, containment, and recovery capability |
| Load Test Results | `k6/` | Performance evidence at peak and spike load |
| Collected Evidence Archive | `docs/evidence/` | Timestamped artifacts ready for examiner review |
