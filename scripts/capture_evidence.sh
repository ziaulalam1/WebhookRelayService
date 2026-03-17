#!/usr/bin/env bash
# capture_evidence.sh — Collect point-in-time operational evidence.
#
# Writes all artifacts to out/evidence/ relative to the repo root.
# No credentials or secrets are written to any output file; API keys
# are masked to show only the last 4 characters.
#
# Usage:
#   ./scripts/capture_evidence.sh [--project <compose-project-name>]
#
# Options:
#   --project   Docker Compose project name (default: webhook-relay)
#
# Requirements:
#   docker      Docker CLI with Compose plugin (no psql or DATABASE_URL needed;
#               all DB queries run inside the db container)

set -euo pipefail

# ---------------------------------------------------------------------------
# Locate repo root
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT_DIR="${REPO_ROOT}/out/evidence"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
PROJECT="webhook-relay"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
die() { echo "ERROR: $*" >&2; exit 1; }

header() {
  echo "# $1"
  echo "# Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "# ---------------------------------------------------------------"
  echo ""
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --help|-h) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
command -v docker >/dev/null 2>&1 || die "docker is not installed or not on PATH"

DB_CONTAINER="${PROJECT}-db-1"

docker inspect "${DB_CONTAINER}" >/dev/null 2>&1 \
  || die "Container '${DB_CONTAINER}' not found. Is the stack running? Try: docker compose -p ${PROJECT} up -d"

mkdir -p "${OUT_DIR}"

echo "Capturing evidence → ${OUT_DIR}"
echo ""

# ---------------------------------------------------------------------------
# 1. compose_ps.txt — running container status
# ---------------------------------------------------------------------------
echo "[1/5] compose_ps.txt"
{
  header "Docker Compose service status — project: ${PROJECT}"
  docker compose -p "${PROJECT}" ps
} > "${OUT_DIR}/compose_ps.txt"

# ---------------------------------------------------------------------------
# 2. api_logs_tail.txt — last 120 lines of api container logs
# ---------------------------------------------------------------------------
echo "[2/5] api_logs_tail.txt"
{
  header "API container logs (tail 120) — project: ${PROJECT}"
  docker compose -p "${PROJECT}" logs --no-color --tail=120 api
} > "${OUT_DIR}/api_logs_tail.txt"

# ---------------------------------------------------------------------------
# 3. idempotency_proof.txt
#    Events grouped by (api_key, idempotency_key); row_count must be 1 for
#    every pair — proves the UNIQUE constraint is enforced end-to-end.
# ---------------------------------------------------------------------------
echo "[3/5] idempotency_proof.txt"
{
  header "Idempotency proof — events grouped by (api_key, idempotency_key)"
  docker exec "${DB_CONTAINER}" psql -U relay -d webhook_relay \
    --no-psqlrc -P pager=off -c "
SELECT
  repeat('*', GREATEST(0, LENGTH(api_key) - 4)) || RIGHT(api_key, 4) AS api_key_masked,
  idempotency_key,
  COUNT(*)      AS row_count,
  MIN(created_at) AS first_seen,
  status
FROM events
GROUP BY api_key, idempotency_key, status
ORDER BY first_seen DESC;
"
} > "${OUT_DIR}/idempotency_proof.txt"

# ---------------------------------------------------------------------------
# 4. audit_log_tail.txt — last 20 rows, no raw secrets
# ---------------------------------------------------------------------------
echo "[4/5] audit_log_tail.txt"
{
  header "Audit log — last 20 rows"
  docker exec "${DB_CONTAINER}" psql -U relay -d webhook_relay \
    --no-psqlrc -P pager=off -c "
SELECT
  id,
  ts,
  repeat('*', GREATEST(0, LENGTH(actor) - 4)) || RIGHT(actor, 4) AS actor_masked,
  action,
  entity_type,
  entity_id,
  request_id,
  new_json
FROM audit_log
ORDER BY id DESC
LIMIT 20;
"
} > "${OUT_DIR}/audit_log_tail.txt"

# ---------------------------------------------------------------------------
# 5. api_keys_inventory.txt — masked keys, name, enabled flag
# ---------------------------------------------------------------------------
echo "[5/5] api_keys_inventory.txt"
{
  header "API key inventory — keys masked (last 4 chars visible)"
  docker exec "${DB_CONTAINER}" psql -U relay -d webhook_relay \
    --no-psqlrc -P pager=off -c "
SELECT
  repeat('*', GREATEST(0, LENGTH(key) - 4)) || RIGHT(key, 4) AS key_masked,
  name,
  enabled
FROM api_keys
ORDER BY name;
"
} > "${OUT_DIR}/api_keys_inventory.txt"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "Artifacts written:"
ls -lh "${OUT_DIR}"
