#!/usr/bin/env bash
set -euo pipefail

# summarize.sh — Generate benchmark comparison tables (baseline vs patched).
#
# Usage: ./scripts/summarize.sh <results-dir>
#
# Detects whether results contain baseline/patched pairs and renders accordingly.
# Falls back to a simple table if no pairs are found (backwards compat).

RESULTS_DIR="${1:?Usage: summarize.sh <results-dir>}"
SUMMARY_FILE="${RESULTS_DIR}/summary.md"

# Helper: format seconds with 2 decimal places.
fmt_s() { printf "%.2f" "$1"; }

# Helper: compute delta and improvement percentage.
# Args: baseline_s patched_s
# Output: "delta improvement_pct" (e.g. "-8.40 25.1")
compute_delta() {
  local base="$1" patch="$2"
  echo | awk -v b="${base}" -v p="${patch}" '{
    delta = p - b
    if (b != 0) pct = ((b - p) / b) * 100
    else pct = 0
    printf "%.2f %.1f", delta, pct
  }'
}

{
  echo "# Kurtosis Benchmark: Baseline vs Patched"
  echo ""
  echo "**Runner:** $(uname -m) / $(uname -s)"
  echo "**Date:** $(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Load build info if available.
  BUILD_INFO="${RESULTS_DIR}/build-info.json"
  if [[ -f "${BUILD_INFO}" ]]; then
    BASELINE_BRANCH=$(jq -r '.baseline_branch' "${BUILD_INFO}")
    BASELINE_SHA=$(jq -r '.baseline_sha' "${BUILD_INFO}")
    PATCHED_BRANCH=$(jq -r '.patched_branch' "${BUILD_INFO}")
    PATCHED_SHA=$(jq -r '.patched_sha' "${BUILD_INFO}")
    echo "**Baseline:** ${BASELINE_BRANCH} (${BASELINE_SHA})"
    echo "**Patched:** ${PATCHED_BRANCH} (${PATCHED_SHA})"
  fi
  echo ""

  # Check for failed runs.
  shopt -s nullglob
  ALL_CHECK_FILES=("${RESULTS_DIR}"/*.json)
  shopt -u nullglob
  FAILED_RUNS=()
  for f in "${ALL_CHECK_FILES[@]}"; do
    [[ "$(basename "$f")" == "build-info.json" ]] && continue
    EXIT_CODE=$(jq -r '.exit_code // 0' "$f")
    if [[ "${EXIT_CODE}" != "0" ]]; then
      LABEL=$(jq -r '.label // "unknown"' "$f")
      FAILED_RUNS+=("${LABEL} (exit ${EXIT_CODE})")
    fi
  done
  if [[ ${#FAILED_RUNS[@]} -gt 0 ]]; then
    echo "> **WARNING: Benchmark failures detected.** Results below are **not valid** for comparison — a failed run terminates early, making it appear artificially faster. Fix the failing runs and try again."
    echo ">"
    for fr in "${FAILED_RUNS[@]}"; do
      echo "> - \`${fr}\`"
    done
    echo ""
  fi

  # Collect baseline/patched pairs.
  # File naming: baseline-<config>-<pkg>.json / patched-<config>-<pkg>.json
  shopt -s nullglob
  BASELINE_FILES=("${RESULTS_DIR}"/baseline-*.json)
  shopt -u nullglob

  if [[ ${#BASELINE_FILES[@]} -gt 0 ]]; then
    # ── Comparison mode ──

    echo "## Wall Clock Comparison"
    echo ""
    echo "| Config | Package | Baseline | Patched | Delta | Improvement |"
    echo "|--------|---------|----------|---------|-------|-------------|"

    # Track pairs for phase breakdown later.
    PAIRS=()

    for baseline_file in "${BASELINE_FILES[@]}"; do
      base_name=$(basename "${baseline_file}" .json)
      suffix="${base_name#baseline-}"
      patched_file="${RESULTS_DIR}/patched-${suffix}.json"

      if [[ ! -f "${patched_file}" ]]; then
        continue
      fi

      PAIRS+=("${suffix}")

      CONFIG=$(jq -r '.config' "${baseline_file}" | xargs basename | sed 's/\.yaml$//')
      # Extract package label from the suffix (e.g. "single-local" → "local").
      PKG_LABEL="${suffix##*-}"

      BASE_DUR=$(jq -r '.duration_seconds' "${baseline_file}")
      PATCH_DUR=$(jq -r '.duration_seconds' "${patched_file}")

      read -r DELTA PCT <<< "$(compute_delta "${BASE_DUR}" "${PATCH_DUR}")"

      echo "| ${CONFIG} | ${PKG_LABEL} | $(fmt_s "${BASE_DUR}")s | $(fmt_s "${PATCH_DUR}")s | ${DELTA}s | ${PCT}% |"
    done

    echo ""

    # ── Phase breakdowns for each pair ──

    for suffix in "${PAIRS[@]}"; do
      baseline_file="${RESULTS_DIR}/baseline-${suffix}.json"
      patched_file="${RESULTS_DIR}/patched-${suffix}.json"

      CONFIG=$(jq -r '.config' "${baseline_file}" | xargs basename | sed 's/\.yaml$//')
      PKG_LABEL="${suffix##*-}"

      # Get phase keys from both files (union).
      BASE_PHASES=$(jq -r '.apic_phases // {} | keys[]' "${baseline_file}" 2>/dev/null || true)
      PATCH_PHASES=$(jq -r '.apic_phases // {} | keys[]' "${patched_file}" 2>/dev/null || true)
      ALL_PHASES=$(printf '%s\n%s\n' "${BASE_PHASES}" "${PATCH_PHASES}" | sort -u | grep -v '^$' || true)

      if [[ -z "${ALL_PHASES}" ]]; then
        continue
      fi

      echo "## APIC Phase Breakdown: ${CONFIG} / ${PKG_LABEL}"
      echo ""
      echo "| Phase | Baseline | Patched | Delta |"
      echo "|-------|----------|---------|-------|"

      while IFS= read -r phase; do
        BASE_VAL=$(jq -r --arg p "${phase}" '.apic_phases[$p] // 0' "${baseline_file}")
        PATCH_VAL=$(jq -r --arg p "${phase}" '.apic_phases[$p] // 0' "${patched_file}")
        read -r DELTA _ <<< "$(compute_delta "${BASE_VAL}" "${PATCH_VAL}")"
        echo "| ${phase} | $(fmt_s "${BASE_VAL}")s | $(fmt_s "${PATCH_VAL}")s | ${DELTA}s |"
      done <<< "${ALL_PHASES}"

      echo ""
    done

  else
    # ── Fallback: simple table (no baseline/patched pairs) ──

    echo "## Timing Summary"
    echo ""
    echo "| Run | Config | Image Mode | Duration (s) | New Images | Services |"
    echo "|-----|--------|------------|--------------|------------|----------|"

    shopt -s nullglob
    JSON_FILES=("${RESULTS_DIR}"/*.json)
    shopt -u nullglob

    for result_file in "${JSON_FILES[@]}"; do
      # Skip build-info.json.
      [[ "$(basename "${result_file}")" == "build-info.json" ]] && continue

      LABEL=$(jq -r '.label // "unknown"' "${result_file}")
      CONFIG=$(basename "$(jq -r '.config // "unknown"' "${result_file}")")
      MODE=$(jq -r '.image_download_mode // "unknown"' "${result_file}")
      DURATION=$(jq -r '.duration_seconds // 0' "${result_file}")
      IMAGES=$(jq -r '.new_images_pulled // 0' "${result_file}")
      SERVICES=$(jq -r '.num_services // "0"' "${result_file}")
      echo "| ${LABEL} | ${CONFIG} | ${MODE} | ${DURATION} | ${IMAGES} | ${SERVICES} |"
    done

    echo ""

    # APIC phases if present in any result.
    for result_file in "${JSON_FILES[@]}"; do
      [[ "$(basename "${result_file}")" == "build-info.json" ]] && continue

      PHASES=$(jq -r '.apic_phases // {} | keys[]' "${result_file}" 2>/dev/null || true)
      if [[ -n "${PHASES}" ]]; then
        LABEL=$(jq -r '.label // "unknown"' "${result_file}")
        echo "### APIC Phases: ${LABEL}"
        echo ""
        echo "| Phase | Duration |"
        echo "|-------|----------|"
        while IFS= read -r phase; do
          VAL=$(jq -r --arg p "${phase}" '.apic_phases[$p] // 0' "${result_file}")
          echo "| ${phase} | $(fmt_s "${VAL}")s |"
        done <<< "${PHASES}"
        echo ""
      fi
    done
  fi

} > "${SUMMARY_FILE}"

echo "Summary written to ${SUMMARY_FILE}"
cat "${SUMMARY_FILE}"
