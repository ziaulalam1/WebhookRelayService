#!/usr/bin/env bash
# export_audit_log.sh — Export delivery attempt records to CSV for compliance evidence.
#
# Usage:
#   export_audit_log.sh --from <ISO8601> --to <ISO8601> --output <file.csv> [--status <status>]
#
# --status values:
#   pending        — queued, not yet attempted
#   succeeded      — delivered successfully
#   failed         — failed at least once but retries remaining
#   dead_lettered  — failed and exhausted all retry attempts (derived, not a raw DB value)
#   (omit)         — export all statuses
#
# Required env:
#   DATABASE_URL   — Postgres connection string, e.g. postgres://user:pass@host:5432/dbname
#
# Output columns (per RUNBOOK.md §4.1):
#   event_id, source_id, destination_url, attempt_number, http_status,
#   status, duration_ms, created_at, request_id

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
  for cmd in psql; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
  done
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

FROM=""
TO=""
OUTPUT=""
STATUS_FILTER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)           FROM="$2";          shift 2 ;;
    --to)             TO="$2";            shift 2 ;;
    --output)         OUTPUT="$2";        shift 2 ;;
    --status)         STATUS_FILTER="$2"; shift 2 ;;
    --help|-h)        usage ;;
    *) die "Unknown argument: $1. Run with --help for usage." ;;
  esac
done

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

check_deps

[[ -n "$FROM"   ]] || die "--from is required (ISO 8601 timestamp, e.g. 2026-01-01T00:00:00Z)"
[[ -n "$TO"     ]] || die "--to is required (ISO 8601 timestamp, e.g. 2026-02-24T23:59:59Z)"
[[ -n "$OUTPUT" ]] || die "--output is required (path to destination CSV file)"

[[ -n "${DATABASE_URL:-}" ]] || die "DATABASE_URL environment variable is not set"

# Validate --status value if provided
case "${STATUS_FILTER:-}" in
  pending|succeeded|failed|dead_lettered|"") ;;
  *) die "Invalid --status value: '$STATUS_FILTER'. Valid values: pending, succeeded, failed, dead_lettered" ;;
esac

# Ensure output directory exists
OUTPUT_DIR="$(dirname "$OUTPUT")"
[[ -d "$OUTPUT_DIR" ]] || die "Output directory does not exist: $OUTPUT_DIR"

# ---------------------------------------------------------------------------
# TODO: Verify the following against your actual schema before running
#       in production. These names are drawn from RUNBOOK.md §1 and §4.1.
#
#   Table:   delivery_attempts
#   Columns: event_id, source_id, destination_url, attempt_number,
#            http_status, status, duration_ms, created_at, request_id,
#            max_attempts
#
# If your schema differs, update the SELECT and WHERE clauses below.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Build WHERE clause
# ---------------------------------------------------------------------------

# Base time filter
WHERE="created_at >= '${FROM}' AND created_at <= '${TO}'"

# Status filter
case "${STATUS_FILTER}" in
  dead_lettered)
    # Dead-lettered = failed with no remaining retry budget.
    # TODO: Confirm that max_attempts is a column on delivery_attempts, not
    #       a config value joined from elsewhere.
    WHERE="${WHERE} AND status = 'failed' AND attempt_number >= max_attempts"
    ;;
  "")
    # No status filter — export all rows in the time window
    ;;
  *)
    WHERE="${WHERE} AND status = '${STATUS_FILTER}'"
    ;;
esac

# ---------------------------------------------------------------------------
# Build and run query
# ---------------------------------------------------------------------------

SQL="COPY (
  SELECT
    event_id,
    source_id,
    destination_url,
    attempt_number,
    http_status,
    status,
    duration_ms,
    created_at,
    request_id
  FROM delivery_attempts
  WHERE ${WHERE}
  ORDER BY created_at ASC
) TO STDOUT WITH (FORMAT csv, HEADER true);"

echo "Exporting delivery attempts..."
echo "  From:   ${FROM}"
echo "  To:     ${TO}"
echo "  Status: ${STATUS_FILTER:-all}"
echo "  Output: ${OUTPUT}"

psql "$DATABASE_URL" --no-psqlrc --tuples-only -c "$SQL" > "$OUTPUT"

ROW_COUNT=$(( $(wc -l < "$OUTPUT") - 1 ))  # subtract header line
echo "Export complete. Rows written (excluding header): ${ROW_COUNT}"
echo ""
echo "Next step — generate chain-of-custody checksum:"
echo "  sha256sum '${OUTPUT}' > '${OUTPUT}.sha256'"
