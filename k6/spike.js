/**
 * spike.js — Spike test: burst behavior at 5× expected peak load.
 *
 * Ramps from baseline (10 VUs) to spike (250 VUs = 5× the 50-VU sustained peak),
 * holds the spike for 1 minute, then ramps back down. Validates that:
 *   - Rate limiting engages and returns 429s rather than crashing the service
 *   - The service recovers cleanly after the spike (error rate returns to baseline)
 *   - No events are permanently lost (dead-letter count stays at zero post-spike)
 *
 * Thresholds are relaxed during the spike window: some 429s are expected and
 * acceptable as evidence that rate limiting is functioning. The overall error
 * rate threshold accounts for this.
 *
 * Stages:
 *   0:00 –  0:10   Warm up:   0  → 10 VUs
 *   0:10 –  0:40   Ramp up:  10 → 250 VUs  (spike begins)
 *   0:40 –  1:40   Hold:    250 VUs for 60s (peak spike)
 *   1:40 –  2:00   Ramp down: 250 → 10 VUs
 *   2:00 –  2:10   Cool down:  10 →  0 VUs
 *   Total: ~2m10s
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
 *     --summary-export=k6/results/spike_$(date +%Y-%m-%d).json \
 *     k6/spike.js
 *
 * After the test, verify no events were dead-lettered during the spike window:
 *   psql $DATABASE_URL -c "
 *     SELECT source_id, COUNT(*) AS dead_letter_count
 *     FROM delivery_attempts
 *     WHERE status = 'failed' AND attempt_number >= max_attempts
 *       AND created_at > NOW() - INTERVAL '1 hour'
 *     GROUP BY source_id;"
 */

import http from 'k6/http';
import { check } from 'k6';

// ---------------------------------------------------------------------------
// Fail fast — checked before any VU starts
// ---------------------------------------------------------------------------
if (!__ENV.API_KEY) {
  throw new Error(
    'API_KEY environment variable is required.\n' +
    'Pass it with: k6 run -e API_KEY=<your-key> k6/spike.js'
  );
}

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------
const TARGET_URL      = __ENV.TARGET_URL      || 'http://localhost:8000/webhooks/inbound';
const API_KEY         = __ENV.API_KEY;
const REQUEST_TIMEOUT = __ENV.REQUEST_TIMEOUT || '10s';

export const options = {
  stages: [
    { duration: '10s', target: 10  },  // warm up
    { duration: '30s', target: 250 },  // ramp to 5× peak (250 = 5 × 50 sustained VUs)
    { duration: '60s', target: 250 },  // hold spike
    { duration: '20s', target: 10  },  // ramp down
    { duration: '10s', target: 0   },  // cool down
  ],

  thresholds: {
    // Relaxed during spike: 429s from rate limiting are expected.
    // The critical assertion is that the service does not crash (5xx).
    // Tune this threshold after observing actual spike behavior.
    http_req_failed: ['rate<0.20'],      // < 20% total errors (including 429s)

    // p95 latency budget is wider during spike; 2s is the ceiling before
    // the service is considered degraded rather than rate-limiting correctly.
    http_req_duration: ['p(95)<2000'],   // p95 < 2000 ms

    // Separately track 5xx errors (service errors vs. expected 429s).
    // A non-zero 5xx rate during or after the spike is a test failure.
    // This requires a custom metric; see TODO below.
    // 'http_req_failed{status:5xx}': ['rate<0.01'],
    // TODO: enable the above threshold once your k6 version supports tag-based thresholds,
    //       or add a Counter metric for 5xx responses in the default function below.
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
  const idempotencyKey = uuidv4();  // unique per request

  const payload = JSON.stringify({
    event_type:      'test.spike',
    idempotency_key: idempotencyKey,
    data: {
      source:    'k6-spike',
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
    // During spike: 200, 202, and 429 (rate limited) are all acceptable.
    // 5xx responses indicate the service is failing rather than rate-limiting.
    // TODO: confirm your API returns 429 (not 503) when rate limit is enforced.
    'status not 5xx': (r) => r.status < 500,

    // 429 is a positive signal: it proves rate limiting is engaged.
    'rate limit or success': (r) =>
      r.status === 200 || r.status === 202 || r.status === 429,

    // TODO: update 'event_id' to match your actual API response body field name.
    //       Skip this check on 429 responses (no body expected).
    'accepted responses have event_id': (r) => {
      if (r.status === 429) return true;  // 429 has no event_id; skip
      try { return r.json('event_id') !== undefined; }
      catch (_) { return false; }
    },
  });

  // No sleep: maximum pressure to trigger rate limiting and measure behavior
  // under burst conditions. Sleep would suppress the spike effect.
}
