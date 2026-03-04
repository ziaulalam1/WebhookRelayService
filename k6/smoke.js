/**
 * smoke.js — Smoke test: basic correctness at low load.
 *
 * 10 VUs, 10 seconds. Run after every deployment to catch regressions
 * before running heavier load tests.
 *
 * Thresholds are strict: any error rate above 1% or p95 above 500ms fails the test.
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
 *     --summary-export=k6/results/smoke_$(date +%Y-%m-%d).json \
 *     k6/smoke.js
 */

import http from 'k6/http';
import { check, sleep } from 'k6';

// ---------------------------------------------------------------------------
// Fail fast — checked before any VU starts
// ---------------------------------------------------------------------------
if (!__ENV.API_KEY) {
  throw new Error(
    'API_KEY environment variable is required.\n' +
    'Pass it with: k6 run -e API_KEY=<your-key> k6/smoke.js'
  );
}

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------
const TARGET_URL      = __ENV.TARGET_URL      || 'http://localhost:8000/webhooks/inbound';
const API_KEY         = __ENV.API_KEY;
const REQUEST_TIMEOUT = __ENV.REQUEST_TIMEOUT || '10s';

export const options = {
  vus:      10,
  duration: '10s',

  thresholds: {
    // Smoke is strict: nearly zero tolerance for errors
    http_req_failed:   ['rate<0.01'],        // < 1% error rate
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
  const requestId     = uuidv4();
  const idempotencyKey = uuidv4();  // unique per request; smoke test does not exercise dedup

  const payload = JSON.stringify({
    event_type:       'test.smoke',
    idempotency_key:  idempotencyKey,   // also sent in header; include in body if schema requires it
    data: {
      source:    'k6-smoke',
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
    //       202 Accepted is typical for async webhook receivers.
    'status is 200 or 202': (r) => r.status === 200 || r.status === 202,

    // TODO: confirm the response body field name for the persisted event identifier.
    //       Update 'event_id' to match your actual API response schema.
    'response has event_id': (r) => {
      try { return r.json('event_id') !== undefined; }
      catch (_) { return false; }
    },
  });

  sleep(1);
}
