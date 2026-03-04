/**
 * sustained.js — Sustained load test: steady traffic at expected peak.
 *
 * 50 VUs for 2 minutes with no artificial sleep, driving maximum natural
 * throughput per VU. Captures p50/p95/p99 latency, error rate, and
 * throughput at the production baseline load level.
 *
 * Thresholds match the alert thresholds in RUNBOOK.md §2.2:
 *   - delivery success rate >= 95%  →  error rate < 5%
 *   - p95 latency < 500 ms
 *
 * Required env:
 *   API_KEY         — inbound API key for the source under test (no default; fails fast if absent)
 *
 * Optional env:
 *   TARGET_URL      — inbound webhook endpoint (default: http://localhost:8000/webhooks/inbound)
 *   REQUEST_TIMEOUT — per-request timeout (default: 10s)
 *
 * Run:
 *   k6 run \
 *     -e API_KEY=$API_KEY \
 *     --summary-export=k6/results/sustained_$(date +%Y-%m-%d).json \
 *     k6/sustained.js
 *
 * Capture a metrics snapshot during the test window for evidence artifact F-1:
 *   ./scripts/export_metrics.sh --output docs/evidence/metrics_snapshot_$(date +%Y%m%d_%H%M%S).json
 */

import http from 'k6/http';
import { check } from 'k6';

// ---------------------------------------------------------------------------
// Fail fast — checked before any VU starts
// ---------------------------------------------------------------------------
if (!__ENV.API_KEY) {
  throw new Error(
    'API_KEY environment variable is required.\n' +
    'Pass it with: k6 run -e API_KEY=<your-key> k6/sustained.js'
  );
}

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------
const TARGET_URL      = __ENV.TARGET_URL      || 'http://localhost:8000/webhooks/inbound';
const API_KEY         = __ENV.API_KEY;
const REQUEST_TIMEOUT = __ENV.REQUEST_TIMEOUT || '10s';

export const options = {
  vus:      50,
  duration: '2m',

  thresholds: {
    // Mirrors RUNBOOK.md §2.2 alert threshold: success rate >= 95%
    http_req_failed:   ['rate<0.05'],        // < 5% error rate
    http_req_duration: ['p(95)<500'],         // p95 < 500 ms
  },
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** UUID v4 — works in all k6 versions without external imports. */
function uuidv4() {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = Math.random() * 16 | 0;
    const v = c === 'x' ? r : (r & 0x3 | 0x8);
    return v.toString(16);
  });
}

// ---------------------------------------------------------------------------
// Default function — executed by each VU on each iteration
// ---------------------------------------------------------------------------
export default function () {
  const requestId      = uuidv4();
  const idempotencyKey = uuidv4();  // unique per request; tests normal delivery, not dedup

  const payload = JSON.stringify({
    event_type:      'test.sustained',
    idempotency_key: idempotencyKey,
    data: {
      source:    'k6-sustained',
      timestamp: new Date().toISOString(),
    },
  });

  const params = {
    timeout: REQUEST_TIMEOUT,
    headers: {
      'Content-Type':    'application/json',
      'X-Request-Id':    requestId,
      'Idempotency-Key': idempotencyKey,
      // TODO: confirm the exact header name your API uses for the inbound API key.
      //       Common options: 'X-Api-Key', 'Authorization: Bearer <key>', 'X-Webhook-Secret'
      'X-Api-Key':       API_KEY,
    },
  };

  const res = http.post(TARGET_URL, payload, params);

  check(res, {
    // TODO: confirm your API returns 200 or 202 on successful ingest.
    'status is 200 or 202': (r) => r.status === 200 || r.status === 202,

    // TODO: update 'event_id' to match your actual API response body field name.
    'response has event_id': (r) => {
      try { return r.json('event_id') !== undefined; }
      catch (_) { return false; }
    },
  });

  // No sleep: drive maximum natural throughput per VU to measure the
  // real sustained capacity of the service at 50 concurrent senders.
}
