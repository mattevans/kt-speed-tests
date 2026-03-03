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

# Snapshot docker image IDs (not tags — IDs are unique per digest).
IMAGE_IDS_BEFORE=$(docker images --format '{{.ID}}' | sort -u)

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

# Snapshot docker image IDs after.
IMAGE_IDS_AFTER=$(docker images --format '{{.ID}}' | sort -u)

# Count genuinely new image IDs (layers actually downloaded).
NEW_IDS=$(comm -13 <(echo "${IMAGE_IDS_BEFORE}") <(echo "${IMAGE_IDS_AFTER}") | grep -v '^$' || true)
if [ -z "${NEW_IDS}" ]; then
  NUM_NEW_IMAGES=0
else
  NUM_NEW_IMAGES=$(echo "${NEW_IDS}" | wc -l | tr -d ' ')
fi

# List all images present now (for reference in cold runs).
ALL_IMAGES=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -v '<none>' | sort -u)
ALL_IMAGES_JSON=$(echo "${ALL_IMAGES}" | jq -R '[.,inputs] | map(select(length > 0))' 2>/dev/null || echo '[]')

# Count services in enclave.
NUM_SERVICES=$(kurtosis enclave inspect "${ENCLAVE_NAME}" 2>/dev/null | grep -cE "RUNNING|STOPPED" || echo "0")

# Write result JSON via jq to guarantee valid output.
jq -n \
  --arg label "${RUN_LABEL}" \
  --arg config "${CONFIG_FILE}" \
  --arg mode "${IMAGE_DOWNLOAD}" \
  --argjson duration "${DURATION_S}" \
  --argjson new_images "${NUM_NEW_IMAGES}" \
  --arg services "${NUM_SERVICES}" \
  --argjson all_images "${ALL_IMAGES_JSON}" \
  '{
    label: $label,
    config: $config,
    image_download_mode: $mode,
    duration_seconds: $duration,
    new_images_pulled: $new_images,
    num_services: $services,
    all_images: $all_images
  }' > "${RESULTS_DIR}/${RUN_LABEL}.json"

echo ""
echo "--- Result: ${RUN_LABEL} ---"
echo "Duration:       ${DURATION_S}s"
echo "New images:     ${NUM_NEW_IMAGES}"
echo "Services:       ${NUM_SERVICES}"
echo ""

# Clean up enclave to free resources for next run.
kurtosis enclave rm "${ENCLAVE_NAME}" -f 2>/dev/null || true
