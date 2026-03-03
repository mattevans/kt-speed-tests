#!/usr/bin/env bash
set -euo pipefail

# summarize.sh — Combine all benchmark result JSON files into a markdown summary.
#
# Usage: ./scripts/summarize.sh <results-dir>

RESULTS_DIR="${1:?Usage: summarize.sh <results-dir>}"
SUMMARY_FILE="${RESULTS_DIR}/summary.md"

echo "# Kurtosis Boot Speed Benchmark Results" > "${SUMMARY_FILE}"
echo "" >> "${SUMMARY_FILE}"
echo "**Runner:** $(uname -m) / $(uname -s)" >> "${SUMMARY_FILE}"
echo "**Date:** $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${SUMMARY_FILE}"
echo "**Kurtosis:** $(kurtosis version 2>/dev/null | head -1 || echo 'unknown')" >> "${SUMMARY_FILE}"
echo "" >> "${SUMMARY_FILE}"

echo "## Timing Summary" >> "${SUMMARY_FILE}"
echo "" >> "${SUMMARY_FILE}"
echo "| Run | Config | Image Mode | Duration (s) | Images Pulled | Services |" >> "${SUMMARY_FILE}"
echo "|-----|--------|------------|--------------|---------------|----------|" >> "${SUMMARY_FILE}"

for result_file in "${RESULTS_DIR}"/*.json; do
  [ -f "${result_file}" ] || continue
  LABEL=$(jq -r '.label' "${result_file}")
  CONFIG=$(jq -r '.config' "${result_file}" | xargs basename)
  MODE=$(jq -r '.image_download_mode' "${result_file}")
  DURATION=$(jq -r '.duration_seconds' "${result_file}")
  IMAGES=$(jq -r '.num_images_pulled' "${result_file}")
  SERVICES=$(jq -r '.num_services' "${result_file}")
  echo "| ${LABEL} | ${CONFIG} | ${MODE} | ${DURATION} | ${IMAGES} | ${SERVICES} |" >> "${SUMMARY_FILE}"
done

echo "" >> "${SUMMARY_FILE}"

# Add comparison between cold and warm if both exist.
for prefix in "single" "multi"; do
  COLD_FILE="${RESULTS_DIR}/${prefix}-cold.json"
  WARM_FILE="${RESULTS_DIR}/${prefix}-warm.json"
  if [ -f "${COLD_FILE}" ] && [ -f "${WARM_FILE}" ]; then
    COLD=$(jq -r '.duration_seconds' "${COLD_FILE}")
    WARM=$(jq -r '.duration_seconds' "${WARM_FILE}")
    DIFF=$(echo "scale=2; ${COLD} - ${WARM}" | bc)
    PCT=$(echo "scale=1; (${DIFF} / ${COLD}) * 100" | bc)
    echo "### ${prefix}-client: Cold vs Warm" >> "${SUMMARY_FILE}"
    echo "" >> "${SUMMARY_FILE}"
    echo "- Cold (always pull): **${COLD}s**" >> "${SUMMARY_FILE}"
    echo "- Warm (missing/cached): **${WARM}s**" >> "${SUMMARY_FILE}"
    echo "- Difference: **${DIFF}s** (${PCT}% faster)" >> "${SUMMARY_FILE}"
    echo "" >> "${SUMMARY_FILE}"
  fi
done

# Add images pulled detail for cold runs.
echo "## Images Pulled (Cold Runs)" >> "${SUMMARY_FILE}"
echo "" >> "${SUMMARY_FILE}"
for result_file in "${RESULTS_DIR}"/*-cold.json; do
  [ -f "${result_file}" ] || continue
  LABEL=$(jq -r '.label' "${result_file}")
  echo "### ${LABEL}" >> "${SUMMARY_FILE}"
  echo '```' >> "${SUMMARY_FILE}"
  jq -r '.images_pulled[]' "${result_file}" >> "${SUMMARY_FILE}"
  echo '```' >> "${SUMMARY_FILE}"
  echo "" >> "${SUMMARY_FILE}"
done

echo "Summary written to ${SUMMARY_FILE}"
cat "${SUMMARY_FILE}"
