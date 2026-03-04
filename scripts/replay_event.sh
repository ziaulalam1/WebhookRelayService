#!/usr/bin/env bash
# replay_event.sh — Trigger redelivery of persisted events via the admin API.
#
# Two modes:
#
#   Single event:
#     replay_event.sh --event-id <uuid> --destination-url <url>
#
#   Batch (by source, status, and time window):
#     replay_event.sh --source-id <id> --status <status> --from <ISO8601> --to <ISO8601>
#
# Each replay creates a NEW delivery attempt record. The original event record
# is not modified. This preserves the full delivery history for audit purposes.
#
# Required env:
#   ADMIN_API_URL    — Base URL of the admin API, e.g. https://internal.example.com
#                      TODO: Set this to your actual admin API base URL.
#   ADMIN_API_TOKEN  — Bearer token for admin API authentication.
#                      TODO: Set this to a valid, short-lived admin token.
#                      Do not hardcode. Rotate after each use if policy requires.
#
# --status values for batch mode:
#   dead_lettered   — events that exhausted all retry attempts
#   failed          — events with at least one failed attempt and retries remaining
#   succeeded       — (unusual) re-deliver already-succeeded events; use with caution

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

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

EVENT_ID=""
DESTINATION_URL=""
SOURCE_ID=""
STATUS_FILTER=""
FROM=""
TO=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --event-id)         EVENT_ID="$2";         shift 2 ;;
    --destination-url)  DESTINATION_URL="$2";  shift 2 ;;
    --source-id)        SOURCE_ID="$2";         shift 2 ;;
    --status)           STATUS_FILTER="$2";     shift 2 ;;
    --from)             FROM="$2";              shift 2 ;;
    --to)               TO="$2";                shift 2 ;;
    --help|-h)          usage ;;
    *) die "Unknown argument: $1. Run with --help for usage." ;;
  esac
done

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

check_deps

[[ -n "${ADMIN_API_URL:-}" ]] || die "ADMIN_API_URL environment variable is not set.
       TODO: Set ADMIN_API_URL to your admin API base URL.
       Example: export ADMIN_API_URL=https://internal.example.com"

[[ -n "${ADMIN_API_TOKEN:-}" ]] || die "ADMIN_API_TOKEN environment variable is not set.
       TODO: Set ADMIN_API_TOKEN to a valid admin bearer token.
       Do not hardcode this value in scripts or commit it to version control."

# Determine mode: single or batch
if [[ -n "$EVENT_ID" ]]; then
  MODE="single"
  [[ -z "$SOURCE_ID" && -z "$STATUS_FILTER" && -z "$FROM" && -z "$TO" ]] || \
    die "In single-event mode (--event-id), do not pass --source-id, --status, --from, or --to"
  # destination-url is optional in single mode (API may use the original destination)
elif [[ -n "$SOURCE_ID" ]]; then
  MODE="batch"
  [[ -n "$STATUS_FILTER" ]] || die "--status is required in batch mode"
  [[ -n "$FROM" ]]          || die "--from is required in batch mode (ISO 8601 timestamp)"
  [[ -n "$TO"   ]]          || die "--to is required in batch mode (ISO 8601 timestamp)"
  [[ -z "$EVENT_ID" && -z "$DESTINATION_URL" ]] || \
    die "In batch mode (--source-id), do not pass --event-id or --destination-url"
else
  die "Either --event-id (single mode) or --source-id (batch mode) is required"
fi

# ---------------------------------------------------------------------------
# TODO: The API endpoints and request shapes below are illustrative.
#       Replace with your actual admin API paths and payload schema.
#
#   Single replay endpoint:  POST /admin/events/{event_id}/replay
#   Batch replay endpoint:   POST /admin/events/replay
#
#   Confirm the following with your API implementation:
#   - Whether destination_url override is supported in single mode
#   - Whether the batch endpoint accepts source_id + status + time range
#   - Whether the API returns a job ID for async batch replays
#   - Whether the API requires a CSRF token in addition to the bearer token
# ---------------------------------------------------------------------------

AUTH_HEADER="Authorization: Bearer ${ADMIN_API_TOKEN}"

# ---------------------------------------------------------------------------
# Single-event replay
# ---------------------------------------------------------------------------

if [[ "$MODE" == "single" ]]; then
  log "Replaying single event: ${EVENT_ID}"

  PAYLOAD_ARGS=()
  if [[ -n "$DESTINATION_URL" ]]; then
    PAYLOAD_ARGS+=(--argjson destination_url "\"${DESTINATION_URL}\"")
  fi

  # TODO: Adjust JSON payload keys to match your admin API schema
  PAYLOAD=$(jq -n \
    --arg event_id "$EVENT_ID" \
    ${DESTINATION_URL:+--arg destination_url "$DESTINATION_URL"} \
    '{
      event_id: $event_id
    } + (if $ENV.destination_url? then {destination_url: $ENV.destination_url} else {} end)'
  )

  # Simpler approach: build payload conditionally
  if [[ -n "$DESTINATION_URL" ]]; then
    PAYLOAD=$(jq -n \
      --arg event_id        "$EVENT_ID" \
      --arg destination_url "$DESTINATION_URL" \
      '{ event_id: $event_id, destination_url: $destination_url }')
  else
    PAYLOAD=$(jq -n \
      --arg event_id "$EVENT_ID" \
      '{ event_id: $event_id }')
  fi

  # TODO: Replace path with your actual single-event replay endpoint
  ENDPOINT="${ADMIN_API_URL}/admin/events/${EVENT_ID}/replay"

  HTTP_STATUS=$(curl -sf \
    --max-time 30 \
    -w "%{http_code}" \
    -o /tmp/replay_response.json \
    -X POST \
    -H "$AUTH_HEADER" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "$ENDPOINT") || die "Request to admin API failed. Check ADMIN_API_URL and ADMIN_API_TOKEN."

  if [[ "$HTTP_STATUS" -ge 200 && "$HTTP_STATUS" -lt 300 ]]; then
    log "Replay accepted (HTTP ${HTTP_STATUS})"
    jq . /tmp/replay_response.json
  else
    die "Admin API returned HTTP ${HTTP_STATUS}. Response: $(cat /tmp/replay_response.json)"
  fi

  log "Verify delivery by querying:"
  log "  SELECT event_id, attempt_number, status, http_status, created_at"
  log "  FROM delivery_attempts WHERE event_id = '${EVENT_ID}' ORDER BY created_at DESC;"

# ---------------------------------------------------------------------------
# Batch replay
# ---------------------------------------------------------------------------

elif [[ "$MODE" == "batch" ]]; then
  log "Batch replay:"
  log "  Source:  ${SOURCE_ID}"
  log "  Status:  ${STATUS_FILTER}"
  log "  From:    ${FROM}"
  log "  To:      ${TO}"
  echo ""
  echo "WARNING: This will enqueue redelivery for ALL matching events."
  echo "         Confirm the destination is healthy before proceeding."
  echo "         Press Ctrl-C within 10 seconds to cancel."
  sleep 10

  # TODO: Replace path and payload schema with your actual batch replay endpoint
  PAYLOAD=$(jq -n \
    --arg source_id "$SOURCE_ID" \
    --arg status    "$STATUS_FILTER" \
    --arg from      "$FROM" \
    --arg to        "$TO" \
    '{
      source_id: $source_id,
      status:    $status,
      from:      $from,
      to:        $to
    }')

  ENDPOINT="${ADMIN_API_URL}/admin/events/replay"  # TODO: confirm path

  HTTP_STATUS=$(curl -sf \
    --max-time 60 \
    -w "%{http_code}" \
    -o /tmp/replay_batch_response.json \
    -X POST \
    -H "$AUTH_HEADER" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "$ENDPOINT") || die "Request to admin API failed. Check ADMIN_API_URL and ADMIN_API_TOKEN."

  if [[ "$HTTP_STATUS" -ge 200 && "$HTTP_STATUS" -lt 300 ]]; then
    log "Batch replay accepted (HTTP ${HTTP_STATUS})"
    jq . /tmp/replay_batch_response.json
    # TODO: If the API returns an async job_id, poll for completion here
  else
    die "Admin API returned HTTP ${HTTP_STATUS}. Response: $(cat /tmp/replay_batch_response.json)"
  fi

  log "Confirm delivery progress by querying delivery_attempts for source_id='${SOURCE_ID}'"
  log "within the time window ${FROM} to ${TO}."
fi
