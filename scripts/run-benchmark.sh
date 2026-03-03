#!/usr/bin/env bash
set -euo pipefail

# run-benchmark.sh — Run a kurtosis boot benchmark and record timing.
#
# Usage: ./scripts/run-benchmark.sh <config-file> <run-label> <image-download-mode>
#
# Arguments:
#   config-file          Path to the kurtosis args YAML file
#   run-label            Human-readable label for this run (e.g. "cold-cache", "warm-cache")
#   image-download-mode  "always" or "missing"

CONFIG_FILE="${1:?Usage: run-benchmark.sh <config-file> <run-label> <image-download-mode>}"
RUN_LABEL="${2:?Usage: run-benchmark.sh <config-file> <run-label> <image-download-mode>}"
IMAGE_DOWNLOAD="${3:?Usage: run-benchmark.sh <config-file> <run-label> <image-download-mode>}"

ENCLAVE_NAME="bench-${RUN_LABEL}"
RESULTS_DIR="${RESULTS_DIR:-./results}"
mkdir -p "${RESULTS_DIR}"

echo "========================================"
echo "Benchmark: ${RUN_LABEL}"
echo "Config:    ${CONFIG_FILE}"
echo "Image DL:  ${IMAGE_DOWNLOAD}"
echo "Enclave:   ${ENCLAVE_NAME}"
echo "========================================"

# Clean up any previous enclave with same name.
kurtosis enclave rm "${ENCLAVE_NAME}" -f 2>/dev/null || true

# Record docker image state before run.
IMAGES_BEFORE=$(docker images --format '{{.Repository}}:{{.Tag}}' | sort)

# Time the full kurtosis run.
START_TS=$(date +%s%N)

kurtosis run \
  --enclave "${ENCLAVE_NAME}" \
  --image-download "${IMAGE_DOWNLOAD}" \
  --args-file "${CONFIG_FILE}" \
  github.com/ethpandaops/ethereum-package 2>&1 | tee "${RESULTS_DIR}/${RUN_LABEL}.log"

END_TS=$(date +%s%N)

# Calculate duration.
DURATION_NS=$((END_TS - START_TS))
DURATION_S=$(echo "scale=2; ${DURATION_NS} / 1000000000" | bc)

# Record docker image state after run.
IMAGES_AFTER=$(docker images --format '{{.Repository}}:{{.Tag}}' | sort)

# Determine which images were pulled during this run.
IMAGES_PULLED=$(comm -13 <(echo "${IMAGES_BEFORE}") <(echo "${IMAGES_AFTER}") | grep -v '^$' || true)
if [ -z "${IMAGES_PULLED}" ]; then
  NUM_IMAGES_PULLED=0
  IMAGES_PULLED_JSON="[]"
else
  NUM_IMAGES_PULLED=$(echo "${IMAGES_PULLED}" | wc -l | tr -d ' ')
  IMAGES_PULLED_JSON=$(echo "${IMAGES_PULLED}" | jq -R '[.,inputs] | map(select(length > 0))')
fi

# Count services in enclave.
NUM_SERVICES=$(kurtosis enclave inspect "${ENCLAVE_NAME}" 2>/dev/null | grep -cE "RUNNING|STOPPED" || echo "0")

# Write result JSON via jq to guarantee valid output.
jq -n \
  --arg label "${RUN_LABEL}" \
  --arg config "${CONFIG_FILE}" \
  --arg mode "${IMAGE_DOWNLOAD}" \
  --argjson duration "${DURATION_S}" \
  --argjson images_pulled_count "${NUM_IMAGES_PULLED}" \
  --arg services "${NUM_SERVICES}" \
  --argjson images_pulled "${IMAGES_PULLED_JSON}" \
  '{
    label: $label,
    config: $config,
    image_download_mode: $mode,
    duration_seconds: $duration,
    num_images_pulled: $images_pulled_count,
    num_services: $services,
    images_pulled: $images_pulled
  }' > "${RESULTS_DIR}/${RUN_LABEL}.json"

echo ""
echo "--- Result: ${RUN_LABEL} ---"
echo "Duration:      ${DURATION_S}s"
echo "Images pulled: ${NUM_IMAGES_PULLED}"
echo "Services:      ${NUM_SERVICES}"
echo ""

# Clean up enclave to free resources for next run.
kurtosis enclave rm "${ENCLAVE_NAME}" -f 2>/dev/null || true
