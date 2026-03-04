#!/usr/bin/env bash
# export_events.sh — Export raw event metadata to CSV for compliance evidence.
#
# Exports event receipt records WITHOUT raw payload or parsed field content.
# If a regulatory request explicitly requires payload data, re-run with --include-payload
# and ensure the output is handled under appropriate data handling controls.
#
# Usage:
#   export_events.sh --from <ISO8601> --to <ISO8601> --output <file.csv> [--include-payload]
#
# Required env:
#   DATABASE_URL   — Postgres connection string, e.g. postgres://user:pass@host:5432/dbname
#
# Output columns (default, no payload):
#   event_id, source_id, idempotency_key, received_at, is_duplicate
#
# Output columns (--include-payload):
#   event_id, source_id, idempotency_key, received_at, is_duplicate, raw_payload

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
INCLUDE_PAYLOAD=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)             FROM="$2";           shift 2 ;;
    --to)               TO="$2";             shift 2 ;;
    --output)           OUTPUT="$2";         shift 2 ;;
    --include-payload)  INCLUDE_PAYLOAD=true; shift 1 ;;
    --help|-h)          usage ;;
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

OUTPUT_DIR="$(dirname "$OUTPUT")"
[[ -d "$OUTPUT_DIR" ]] || die "Output directory does not exist: $OUTPUT_DIR"

if [[ "$INCLUDE_PAYLOAD" == true ]]; then
  echo "WARNING: --include-payload is set. Output will contain raw webhook payloads." >&2
  echo "         Ensure the output file is handled under appropriate data controls." >&2
  echo ""
fi

# ---------------------------------------------------------------------------
# TODO: Verify the following against your actual schema before running
#       in production. Column names are inferred from system design docs.
#
#   Table:   events
#   Columns:
#     event_id        — UUID primary key
#     source_id       — FK to api_keys / sources table
#     idempotency_key — caller-supplied dedup key
#     received_at     — server-side receipt timestamp (UTC)
#     is_duplicate    — boolean; true if this event was suppressed as a duplicate
#     raw_payload     — JSONB; the verbatim inbound request body
#
# If your schema uses different column names (e.g. `id` instead of `event_id`,
# `created_at` instead of `received_at`), update the SELECT below.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Build SELECT list
# ---------------------------------------------------------------------------

if [[ "$INCLUDE_PAYLOAD" == true ]]; then
  SELECT_COLS="event_id, source_id, idempotency_key, received_at, is_duplicate, raw_payload"
else
  SELECT_COLS="event_id, source_id, idempotency_key, received_at, is_duplicate"
fi

# ---------------------------------------------------------------------------
# Build and run query
# ---------------------------------------------------------------------------

SQL="COPY (
  SELECT ${SELECT_COLS}
  FROM events
  WHERE received_at >= '${FROM}'
    AND received_at <= '${TO}'
  ORDER BY received_at ASC
) TO STDOUT WITH (FORMAT csv, HEADER true);"

echo "Exporting event records..."
echo "  From:            ${FROM}"
echo "  To:              ${TO}"
echo "  Include payload: ${INCLUDE_PAYLOAD}"
echo "  Output:          ${OUTPUT}"

psql "$DATABASE_URL" --no-psqlrc --tuples-only -c "$SQL" > "$OUTPUT"

ROW_COUNT=$(( $(wc -l < "$OUTPUT") - 1 ))
echo "Export complete. Rows written (excluding header): ${ROW_COUNT}"
echo ""
echo "Next step — generate chain-of-custody checksum:"
echo "  sha256sum '${OUTPUT}' > '${OUTPUT}.sha256'"
