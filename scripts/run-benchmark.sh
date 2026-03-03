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
IMAGES_PULLED=$(comm -13 <(echo "${IMAGES_BEFORE}") <(echo "${IMAGES_AFTER}"))
NUM_IMAGES_PULLED=$(echo "${IMAGES_PULLED}" | grep -c . || echo 0)

# Count services in enclave.
NUM_SERVICES=$(kurtosis enclave inspect "${ENCLAVE_NAME}" 2>/dev/null | grep -c "RUNNING\|STOPPED" || echo "unknown")

# Write result JSON.
cat > "${RESULTS_DIR}/${RUN_LABEL}.json" <<EOF
{
  "label": "${RUN_LABEL}",
  "config": "${CONFIG_FILE}",
  "image_download_mode": "${IMAGE_DOWNLOAD}",
  "duration_seconds": ${DURATION_S},
  "num_images_pulled": ${NUM_IMAGES_PULLED},
  "num_services": "${NUM_SERVICES}",
  "images_pulled": $(echo "${IMAGES_PULLED}" | jq -R -s 'split("\n") | map(select(length > 0))')
}
EOF

echo ""
echo "--- Result: ${RUN_LABEL} ---"
echo "Duration:      ${DURATION_S}s"
echo "Images pulled: ${NUM_IMAGES_PULLED}"
echo "Services:      ${NUM_SERVICES}"
echo ""

# Clean up enclave to free resources for next run.
kurtosis enclave rm "${ENCLAVE_NAME}" -f 2>/dev/null || true
