#!/usr/bin/env bash
# summarize_k6_results.sh — Convert a k6 summary export JSON into a human-readable
#                           Markdown report for inclusion in a compliance evidence package.
#
# The input file must be produced by k6 using the --summary-export flag:
#   k6 run --summary-export=k6/results/sustained_load_2026-02-24.json script.js
#
# Usage:
#   summarize_k6_results.sh --input <k6-summary.json> --output <summary.md> [--label <name>]
#
# --label   Human-readable test name used in the report title.
#           Example: "Sustained Load — 2026-02-24" or "Spike Load — 2026-02-24"
#           Defaults to the input filename.
#
# Output columns covered:
#   p50 / p95 / p99 latency (http_req_duration)
#   Max latency
#   Request error rate        (http_req_failed)
#   Total requests            (http_reqs)
#   Throughput (req/s)
#   Virtual users peak        (vus_max)
#   Test duration             (iteration_duration)

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
  for cmd in jq; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
  done
}

fmt_ms() {
  # Format a millisecond float value to 2 decimal places with unit
  printf "%.2f ms" "$1"
}

fmt_pct() {
  # Format a rate (0.0–1.0) as a percentage
  printf "%.2f%%" "$(echo "$1 * 100" | bc -l)"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

INPUT=""
OUTPUT=""
LABEL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input)    INPUT="$2";  shift 2 ;;
    --output)   OUTPUT="$2"; shift 2 ;;
    --label)    LABEL="$2";  shift 2 ;;
    --help|-h)  usage ;;
    *) die "Unknown argument: $1. Run with --help for usage." ;;
  esac
done

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

check_deps

[[ -n "$INPUT"  ]] || die "--input is required (path to k6 --summary-export JSON file)"
[[ -n "$OUTPUT" ]] || die "--output is required (path to destination Markdown file)"
[[ -f "$INPUT"  ]] || die "Input file not found: $INPUT"

OUTPUT_DIR="$(dirname "$OUTPUT")"
[[ -d "$OUTPUT_DIR" ]] || die "Output directory does not exist: $OUTPUT_DIR"

LABEL="${LABEL:-$(basename "$INPUT")}"
GENERATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ---------------------------------------------------------------------------
# Validate input is a k6 summary export
# ---------------------------------------------------------------------------

jq -e '.metrics' "$INPUT" >/dev/null 2>&1 || \
  die "Input does not appear to be a k6 --summary-export JSON file (missing .metrics key).
       Produce the input with: k6 run --summary-export=<file.json> <script.js>"

# ---------------------------------------------------------------------------
# TODO: The jq paths below match the k6 --summary-export schema as of k6 v0.45+.
#       If you are using an older version of k6, the schema may differ.
#       Reference: https://k6.io/docs/results-output/end-of-test/custom-summary/
#
#       Key paths used:
#         .metrics.http_req_duration.values."p(50)"   — median latency
#         .metrics.http_req_duration.values."p(95)"   — p95 latency
#         .metrics.http_req_duration.values."p(99)"   — p99 latency
#         .metrics.http_req_duration.values.max       — max latency
#         .metrics.http_req_failed.values.rate        — fraction of failed requests (0.0–1.0)
#         .metrics.http_reqs.values.count             — total request count
#         .metrics.http_reqs.values.rate              — requests per second
#         .metrics.vus_max.values.max                 — peak concurrent virtual users
#         .metrics.iteration_duration.values."p(95)"  — p95 iteration duration
#
#       If a metric key is absent (e.g. vus_max not tracked), the script
#       will emit "N/A" for that row rather than failing.
# ---------------------------------------------------------------------------

extract() {
  # Extract a numeric value from the JSON; emit "N/A" if missing or null
  local path="$1"
  jq -r "${path} // \"N/A\"" "$INPUT"
}

P50=$(extract '.metrics.http_req_duration.values."p(50)"')
P95=$(extract '.metrics.http_req_duration.values."p(95)"')
P99=$(extract '.metrics.http_req_duration.values."p(99)"')
MAX=$(extract '.metrics.http_req_duration.values.max')
ERR_RATE=$(extract '.metrics.http_req_failed.values.rate')
TOTAL_REQS=$(extract '.metrics.http_reqs.values.count')
THROUGHPUT=$(extract '.metrics.http_reqs.values.rate')
VUS_MAX=$(extract '.metrics.vus_max.values.max')
ITER_P95=$(extract '.metrics.iteration_duration.values."p(95)"')

# Format numeric values when present
format_or_na() {
  local val="$1"
  local unit="$2"
  if [[ "$val" == "N/A" ]]; then
    echo "N/A"
  else
    printf "%.2f %s" "$val" "$unit"
  fi
}

format_pct_or_na() {
  local val="$1"
  if [[ "$val" == "N/A" ]]; then
    echo "N/A"
  else
    printf "%.4f%%" "$(echo "$val * 100" | bc -l)"
  fi
}

# ---------------------------------------------------------------------------
# Derive pass/fail verdicts against thresholds from RUNBOOK.md §2.2
# ---------------------------------------------------------------------------

# p95 latency threshold: 500 ms on ingestion endpoint (used as proxy here)
p95_verdict="PASS"
if [[ "$P95" != "N/A" ]]; then
  if (( $(echo "$P95 > 500" | bc -l) )); then p95_verdict="FAIL"; fi
fi

# Error rate threshold: < 5% sustained
err_verdict="PASS"
if [[ "$ERR_RATE" != "N/A" ]]; then
  if (( $(echo "$ERR_RATE > 0.05" | bc -l) )); then err_verdict="FAIL"; fi
fi

# ---------------------------------------------------------------------------
# Write Markdown report
# ---------------------------------------------------------------------------

cat > "$OUTPUT" <<MARKDOWN
# Load Test Summary — ${LABEL}

**Generated:** ${GENERATED_AT}
**Input file:** \`${INPUT}\`
**Produced by:** \`scripts/summarize_k6_results.sh\`

---

## Latency — \`http_req_duration\`

| Percentile | Value | Threshold | Verdict |
|------------|-------|-----------|---------|
| p50 (median) | $(format_or_na "$P50" "ms") | — | — |
| p95 | $(format_or_na "$P95" "ms") | ≤ 500 ms | ${p95_verdict} |
| p99 | $(format_or_na "$P99" "ms") | — | — |
| Max | $(format_or_na "$MAX" "ms") | — | — |

---

## Error Rate — \`http_req_failed\`

| Metric | Value | Threshold | Verdict |
|--------|-------|-----------|---------|
| Request error rate | $(format_pct_or_na "$ERR_RATE") | < 5.00% | ${err_verdict} |

---

## Throughput — \`http_reqs\`

| Metric | Value |
|--------|-------|
| Total requests | ${TOTAL_REQS} |
| Throughput (req/s) | $(format_or_na "$THROUGHPUT" "req/s") |

---

## Concurrency and Duration

| Metric | Value |
|--------|-------|
| Peak virtual users (\`vus_max\`) | ${VUS_MAX} |
| p95 iteration duration | $(format_or_na "$ITER_P95" "ms") |

---

## Overall Verdict

MARKDOWN

# Determine overall pass/fail
if [[ "$p95_verdict" == "PASS" && "$err_verdict" == "PASS" ]]; then
  echo "**PASS** — All measured thresholds met." >> "$OUTPUT"
else
  {
    echo "**FAIL** — One or more thresholds were breached:"
    [[ "$p95_verdict" == "FAIL" ]] && echo "- p95 latency exceeded 500 ms"
    [[ "$err_verdict"  == "FAIL" ]] && echo "- Error rate exceeded 5%"
  } >> "$OUTPUT"
fi

cat >> "$OUTPUT" <<MARKDOWN

---

## Notes

- Thresholds are drawn from RUNBOOK.md §2.2.
- This summary covers HTTP-layer metrics only. Application-layer metrics
  (queue depth, dead-letter count) must be captured separately via
  \`scripts/export_metrics.sh\` during the test window.
- Raw k6 output is preserved at \`${INPUT}\` and should be retained alongside
  this summary as the authoritative evidence artifact.
MARKDOWN

echo "Summary written to: ${OUTPUT}"

# Emit a non-zero exit code if any threshold failed, so CI pipelines can gate on it
if [[ "$p95_verdict" == "FAIL" || "$err_verdict" == "FAIL" ]]; then
  echo "WARNING: One or more thresholds FAILED. Review the report before using as evidence." >&2
  exit 1
fi
