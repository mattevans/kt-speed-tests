#!/usr/bin/env bash
set -euo pipefail

# summarize.sh — Combine all benchmark result JSON files into a markdown summary.
#
# Usage: ./scripts/summarize.sh <results-dir>

RESULTS_DIR="${1:?Usage: summarize.sh <results-dir>}"
SUMMARY_FILE="${RESULTS_DIR}/summary.md"

{
  echo "# Kurtosis Boot Speed Benchmark Results"
  echo ""
  echo "**Runner:** $(uname -m) / $(uname -s)"
  echo "**Date:** $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "**Kurtosis:** $(kurtosis version 2>/dev/null | head -1 || echo 'unknown')"
  echo ""

  # Timing table.
  echo "## Timing Summary"
  echo ""
  echo "| Run | Config | Image Mode | Duration (s) | New Images | Services |"
  echo "|-----|--------|------------|--------------|------------|----------|"

  shopt -s nullglob
  JSON_FILES=("${RESULTS_DIR}"/*.json)
  shopt -u nullglob

  for result_file in "${JSON_FILES[@]}"; do
    LABEL=$(jq -r '.label // "unknown"' "${result_file}")
    CONFIG=$(basename "$(jq -r '.config // "unknown"' "${result_file}")")
    MODE=$(jq -r '.image_download_mode // "unknown"' "${result_file}")
    DURATION=$(jq -r '.duration_seconds // 0' "${result_file}")
    IMAGES=$(jq -r '.new_images_pulled // 0' "${result_file}")
    SERVICES=$(jq -r '.num_services // "0"' "${result_file}")
    echo "| ${LABEL} | ${CONFIG} | ${MODE} | ${DURATION} | ${IMAGES} | ${SERVICES} |"
  done

  echo ""

  # Pairwise comparisons.
  echo "## Analysis"
  echo ""

  for prefix in "single" "multi"; do
    COLD_FILE="${RESULTS_DIR}/${prefix}-cold.json"
    WARM_FILE="${RESULTS_DIR}/${prefix}-warm.json"
    WARM_ALWAYS_FILE="${RESULTS_DIR}/${prefix}-warm-always-pull.json"

    if [ ! -f "${COLD_FILE}" ]; then
      continue
    fi

    COLD=$(jq -r '.duration_seconds' "${COLD_FILE}")
    echo "### ${prefix}-client"
    echo ""

    if [ -f "${WARM_FILE}" ]; then
      WARM=$(jq -r '.duration_seconds' "${WARM_FILE}")
      DIFF_CW=$(echo "scale=2; ${COLD} - ${WARM}" | bc)
      PCT_CW=$(echo "scale=1; (${DIFF_CW} / ${COLD}) * 100" | bc)
      echo "| Comparison | Time | Delta |"
      echo "|------------|------|-------|"
      echo "| Cold (pull all from scratch) | **${COLD}s** | baseline |"
      echo "| Warm (\`--image-download missing\`) | **${WARM}s** | **-${DIFF_CW}s** (${PCT_CW}% faster) |"

      if [ -f "${WARM_ALWAYS_FILE}" ]; then
        WARM_ALWAYS=$(jq -r '.duration_seconds' "${WARM_ALWAYS_FILE}")
        DIFF_WA=$(echo "scale=2; ${WARM_ALWAYS} - ${WARM}" | bc)
        echo "| Warm (\`--image-download always\`) | **${WARM_ALWAYS}s** | **+${DIFF_WA}s** vs warm (registry check overhead) |"
      fi

      echo ""
      echo "**Image pull cost:** ${DIFF_CW}s of the cold boot is spent pulling images."
      echo ""

      if [ -f "${WARM_ALWAYS_FILE}" ]; then
        WARM_ALWAYS=$(jq -r '.duration_seconds' "${WARM_ALWAYS_FILE}")
        DIFF_WA=$(echo "scale=2; ${WARM_ALWAYS} - ${WARM}" | bc)
        echo "**Registry check overhead:** Even with cached images, \`always\` mode adds ${DIFF_WA}s just verifying digests against registries."
        echo ""
      fi

      echo "**Pure orchestration time:** ${WARM}s (warm cache, no registry checks)."
      echo ""
    fi
  done

  # Images list for cold runs.
  echo "## Docker Images Used"
  echo ""
  shopt -s nullglob
  COLD_FILES=("${RESULTS_DIR}"/*-cold.json)
  shopt -u nullglob

  for result_file in "${COLD_FILES[@]}"; do
    LABEL=$(jq -r '.label // "unknown"' "${result_file}")
    echo "### ${LABEL}"
    echo '```'
    jq -r '.all_images[]?' "${result_file}" 2>/dev/null || echo "(none)"
    echo '```'
    echo ""
  done

} > "${SUMMARY_FILE}"

echo "Summary written to ${SUMMARY_FILE}"
cat "${SUMMARY_FILE}"
