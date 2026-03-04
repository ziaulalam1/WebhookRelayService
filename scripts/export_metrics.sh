#!/usr/bin/env bash
# export_metrics.sh — Capture a point-in-time snapshot of system metrics to JSON.
#
# Fetches current values for all metrics listed in RUNBOOK.md §2.2 and writes
# them to a JSON file suitable for inclusion in a compliance evidence package.
#
# Usage:
#   export_metrics.sh --output <file.json>
#
# Required env:
#   METRICS_ENDPOINT  — Base URL of the metrics API, e.g. http://localhost:9090
#                       TODO: Set this to your actual metrics server address.
#
# Optional env:
#   METRICS_API_TOKEN — Bearer token if the metrics endpoint requires auth.
#                       TODO: Confirm whether your metrics endpoint requires auth
#                       and set this variable accordingly.

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

die() {
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  grep '^#' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

check_deps() {
  for cmd in curl jq; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
  done
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

OUTPUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)   OUTPUT="$2"; shift 2 ;;
    --help|-h)  usage ;;
    *) die "Unknown argument: $1. Run with --help for usage." ;;
  esac
done

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

check_deps

[[ -n "$OUTPUT" ]] || die "--output is required (path to destination JSON file)"

[[ -n "${METRICS_ENDPOINT:-}" ]] || die "METRICS_ENDPOINT environment variable is not set.
       TODO: Set METRICS_ENDPOINT to your metrics server base URL.
       Example: export METRICS_ENDPOINT=http://localhost:9090"

OUTPUT_DIR="$(dirname "$OUTPUT")"
[[ -d "$OUTPUT_DIR" ]] || die "Output directory does not exist: $OUTPUT_DIR"

# ---------------------------------------------------------------------------
# Build auth header (optional)
# ---------------------------------------------------------------------------

AUTH_HEADER=""
if [[ -n "${METRICS_API_TOKEN:-}" ]]; then
  AUTH_HEADER="Authorization: Bearer ${METRICS_API_TOKEN}"
fi

# ---------------------------------------------------------------------------
# TODO: The metric names and query paths below match the names defined in
#       RUNBOOK.md §2.2. Update these to match your actual metrics backend.
#
#       If using Prometheus, replace the fetch_metric() calls with PromQL
#       instant queries against /api/v1/query, e.g.:
#         curl ".../api/v1/query?query=webhook_ingestion_rate"
#
#       If using a custom /metrics JSON endpoint, adjust the jq path in
#       each fetch_metric() call to match your response shape.
#
#       If using StatsD or another push-based system with no query API,
#       this script will need to be replaced with a direct DB or log query.
# ---------------------------------------------------------------------------

SNAPSHOT_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

fetch_metric() {
  local metric_name="$1"
  local query_path="$2"   # URL path or query string appended to METRICS_ENDPOINT

  local url="${METRICS_ENDPOINT}${query_path}"
  local response

  if [[ -n "$AUTH_HEADER" ]]; then
    response=$(curl -sf --max-time 10 -H "$AUTH_HEADER" "$url") || {
      echo "null"
      echo "  WARNING: Failed to fetch metric '${metric_name}' from ${url}" >&2
      return
    }
  else
    response=$(curl -sf --max-time 10 "$url") || {
      echo "null"
      echo "  WARNING: Failed to fetch metric '${metric_name}' from ${url}" >&2
      return
    }
  fi

  # TODO: Adjust the jq expression below to extract the scalar value from
  #       your metrics API response format.
  #       Prometheus example: echo "$response" | jq '.data.result[0].value[1] | tonumber'
  echo "$response" | jq '.value // empty' 2>/dev/null || echo "null"
}

echo "Fetching metrics snapshot..."
echo "  Endpoint: ${METRICS_ENDPOINT}"
echo "  Output:   ${OUTPUT}"

# ---------------------------------------------------------------------------
# Fetch each metric
# TODO: Replace each query_path with the correct path or PromQL query for
#       your metrics backend. Paths below are illustrative placeholders.
# ---------------------------------------------------------------------------

INGESTION_RATE=$(fetch_metric \
  "webhook.ingestion.rate" \
  "/api/v1/query?query=webhook_ingestion_rate")   # TODO: real query

DELIVERY_SUCCESS_RATE=$(fetch_metric \
  "webhook.delivery.success_rate" \
  "/api/v1/query?query=webhook_delivery_success_rate")  # TODO: real query

QUEUE_DEPTH=$(fetch_metric \
  "webhook.queue.depth" \
  "/api/v1/query?query=webhook_queue_depth")  # TODO: real query

DEAD_LETTER_COUNT=$(fetch_metric \
  "webhook.retry.dead_letter_count" \
  "/api/v1/query?query=webhook_retry_dead_letter_count")  # TODO: real query

RATE_LIMIT_COUNT=$(fetch_metric \
  "webhook.rate_limit.enforced_count" \
  "/api/v1/query?query=webhook_rate_limit_enforced_count")  # TODO: real query

P95_LATENCY_MS=$(fetch_metric \
  "http.p95_latency_ms" \
  "/api/v1/query?query=histogram_quantile(0.95,http_request_duration_ms_bucket)")  # TODO: real query

# ---------------------------------------------------------------------------
# Write output JSON
# ---------------------------------------------------------------------------

jq -n \
  --arg snapshot_time    "$SNAPSHOT_TIME" \
  --arg metrics_endpoint "$METRICS_ENDPOINT" \
  --argjson ingestion_rate      "${INGESTION_RATE}" \
  --argjson delivery_success    "${DELIVERY_SUCCESS_RATE}" \
  --argjson queue_depth         "${QUEUE_DEPTH}" \
  --argjson dead_letter_count   "${DEAD_LETTER_COUNT}" \
  --argjson rate_limit_count    "${RATE_LIMIT_COUNT}" \
  --argjson p95_latency_ms      "${P95_LATENCY_MS}" \
  '{
    snapshot_time:      $snapshot_time,
    metrics_endpoint:   $metrics_endpoint,
    metrics: {
      "webhook.ingestion.rate":            $ingestion_rate,
      "webhook.delivery.success_rate":     $delivery_success,
      "webhook.queue.depth":               $queue_depth,
      "webhook.retry.dead_letter_count":   $dead_letter_count,
      "webhook.rate_limit.enforced_count": $rate_limit_count,
      "http.p95_latency_ms":               $p95_latency_ms
    },
    alert_thresholds: {
      "webhook.ingestion.rate":            "< 0 events/min for 5 min during business hours",
      "webhook.delivery.success_rate":     "< 95% over 10 min window",
      "webhook.queue.depth":               "> 1000 pending",
      "webhook.retry.dead_letter_count":   "> 0 in any 1 hour window",
      "webhook.rate_limit.enforced_count": "spike > 50/min from a single source",
      "http.p95_latency_ms":               "> 500 ms on ingestion endpoint"
    }
  }' > "$OUTPUT"

echo "Snapshot written to: ${OUTPUT}"
echo ""
echo "NOTE: Any metric showing null failed to fetch. Check METRICS_ENDPOINT"
echo "      and TODOs in this script before using this snapshot as evidence."
