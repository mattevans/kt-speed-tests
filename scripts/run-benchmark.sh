#!/usr/bin/env bash
set -euo pipefail

# run-benchmark.sh — Run a kurtosis boot benchmark and record timing + APIC phases.
#
# Usage: ./scripts/run-benchmark.sh <config-file> <run-label> <image-download-mode>
#
# Env vars:
#   KURTOSIS_BIN            Path to kurtosis binary (default: kurtosis)
#   PACKAGE_REF             Package to run (default: github.com/ethpandaops/ethereum-package)
#   KURTOSIS_PARALLEL       Enable --parallel flag (default: true)
#   KURTOSIS_PARALLELISM    Parallelism count (default: 100)
#   KURTOSIS_RESOURCE_CHECK Enable resource check (default: false)
#   RESULTS_DIR             Output directory (default: ./results)

CONFIG_FILE="${1:?Usage: run-benchmark.sh <config-file> <run-label> <image-download-mode>}"
RUN_LABEL="${2:?Usage: run-benchmark.sh <config-file> <run-label> <image-download-mode>}"
IMAGE_DOWNLOAD="${3:?Usage: run-benchmark.sh <config-file> <run-label> <image-download-mode>}"

KT="${KURTOSIS_BIN:-kurtosis}"
PACKAGE_REF="${PACKAGE_REF:-github.com/ethpandaops/ethereum-package}"
KURTOSIS_PARALLEL="${KURTOSIS_PARALLEL:-true}"
KURTOSIS_PARALLELISM="${KURTOSIS_PARALLELISM:-100}"
KURTOSIS_RESOURCE_CHECK="${KURTOSIS_RESOURCE_CHECK:-false}"
RESULTS_DIR="${RESULTS_DIR:-./results}"
ENCLAVE_NAME="bench-${RUN_LABEL}"

mkdir -p "${RESULTS_DIR}"

echo "========================================"
echo "Benchmark: ${RUN_LABEL}"
echo "Config:    ${CONFIG_FILE}"
echo "Image DL:  ${IMAGE_DOWNLOAD}"
echo "Enclave:   ${ENCLAVE_NAME}"
echo "Binary:    ${KT}"
echo "Package:   ${PACKAGE_REF}"
echo "Parallel:  ${KURTOSIS_PARALLEL} (${KURTOSIS_PARALLELISM})"
echo "========================================"

# Clean up any previous enclave with same name.
"${KT}" enclave rm "${ENCLAVE_NAME}" -f 2>/dev/null || true

# Also remove the Docker network directly — if a previous run crashed mid-creation,
# the enclave may not be registered but the network still exists.
docker network rm "kt-${ENCLAVE_NAME}" 2>/dev/null || true

# Build kurtosis run flags.
RUN_FLAGS=()
RUN_FLAGS+=(--enclave "${ENCLAVE_NAME}")
RUN_FLAGS+=(--image-download "${IMAGE_DOWNLOAD}")
RUN_FLAGS+=(--args-file "${CONFIG_FILE}")

# --parallel and --parallelism are only safe on the patched branch. The baseline
# branch has broken parallel execution that causes store_service_files races.
# KURTOSIS_ENABLE_PARALLEL must be explicitly set (run-suite.sh sets it for patched only).
if [[ "${KURTOSIS_ENABLE_PARALLEL:-false}" == "true" ]]; then
  if "${KT}" run --help 2>&1 | grep -q -- '--parallel'; then
    if [[ "${KURTOSIS_PARALLEL}" == "true" ]]; then
      RUN_FLAGS+=(--parallel)
    fi
    RUN_FLAGS+=(--parallelism "${KURTOSIS_PARALLELISM}")
  fi
fi

if "${KT}" run --help 2>&1 | grep -q -- '--resource-check'; then
  if [[ "${KURTOSIS_RESOURCE_CHECK}" == "false" ]]; then
    RUN_FLAGS+=(--resource-check=false)
  fi
fi

# Snapshot docker image IDs before.
IMAGE_IDS_BEFORE=$(docker images --format '{{.ID}}' | sort -u)

# Time the full kurtosis run.
START_TS=$(date +%s%N)

# Record the full command for the report.
RUN_COMMAND="${KT} run ${RUN_FLAGS[*]} ${PACKAGE_REF}"

set +e
"${KT}" run "${RUN_FLAGS[@]}" "${PACKAGE_REF}" 2>&1 | tee "${RESULTS_DIR}/${RUN_LABEL}.log"
RUN_EXIT_CODE="${PIPESTATUS[0]}"
set -e

END_TS=$(date +%s%N)

# Calculate duration.
DURATION_NS=$((END_TS - START_TS))
DURATION_S=$(echo "scale=2; ${DURATION_NS} / 1000000000" | bc)

# Snapshot docker image IDs after.
IMAGE_IDS_AFTER=$(docker images --format '{{.ID}}' | sort -u)

# Count genuinely new image IDs.
NEW_IDS=$(comm -13 <(echo "${IMAGE_IDS_BEFORE}") <(echo "${IMAGE_IDS_AFTER}") | grep -v '^$' || true)
if [ -z "${NEW_IDS}" ]; then
  NUM_NEW_IMAGES=0
else
  NUM_NEW_IMAGES=$(echo "${NEW_IDS}" | wc -l | tr -d ' ')
fi

# Count services in enclave.
NUM_SERVICES=$("${KT}" enclave inspect "${ENCLAVE_NAME}" 2>/dev/null | grep -cE "RUNNING|STOPPED" || echo "0")

# --- APIC [BENCH] phase extraction ---
APIC_PHASES_JSON="{}"

# Get enclave UUID.
ENCLAVE_UUID=$("${KT}" enclave ls 2>/dev/null | command grep -F "${ENCLAVE_NAME}" | awk '{print $1}' || true)

if [[ -n "${ENCLAVE_UUID}" ]]; then
  # Find the APIC container.
  APIC_CONTAINER=$(docker ps -a --filter "name=kurtosis-api--${ENCLAVE_UUID}" --format '{{.Names}}' | head -1)

  if [[ -n "${APIC_CONTAINER}" ]]; then
    echo ""
    echo "--- APIC [BENCH] phases ---"

    # Extract [BENCH] lines and parse into JSON.
    BENCH_LINES=$(docker logs "${APIC_CONTAINER}" 2>&1 | command grep '\[BENCH\]' | sed -E 's/.*\[BENCH\] //' || true)

    if [[ -n "${BENCH_LINES}" ]]; then
      echo "${BENCH_LINES}"

      # Parse "[BENCH] <phase> completed in <go-duration>" lines into JSON.
      # Go duration format: "2.357844097s", "9.484414ms", "2.625µs", "42ns"
      # We extract only "completed in" lines, use the phase name as key,
      # and convert the duration to seconds.
      APIC_PHASES_JSON=$(echo "${BENCH_LINES}" | awk '
        /completed in / {
          # Split on " completed in " to get phase and duration.
          idx = index($0, " completed in ")
          if (idx == 0) next
          phase = substr($0, 1, idx - 1)
          rest = substr($0, idx + 14)

          # Extract the duration token (first whitespace-delimited token).
          split(rest, parts, /[[:space:]]/)
          raw = parts[1]

          # Convert Go duration to seconds.
          if (raw ~ /ns$/) {
            gsub(/ns$/, "", raw)
            secs = raw / 1000000000
          } else if (raw ~ /µs$/ || raw ~ /μs$/) {
            gsub(/(µ|μ)s$/, "", raw)
            secs = raw / 1000000
          } else if (raw ~ /ms$/) {
            gsub(/ms$/, "", raw)
            secs = raw / 1000
          } else if (raw ~ /m[0-9]/) {
            # Handle "1m30.5s" format
            split(raw, mp, "m")
            mins = mp[1]
            gsub(/s$/, "", mp[2])
            secs = (mins * 60) + mp[2]
          } else if (raw ~ /s$/) {
            gsub(/s$/, "", raw)
            secs = raw + 0
          } else {
            secs = raw + 0
          }

          printf "%s\t%.4f\n", phase, secs
        }
      ' | jq -R -s 'split("\n") | map(select(length > 0)) | map(split("\t")) | map({(.[0]): (.[1] | tonumber)}) | add // {}')
    fi
  else
    echo "(could not find APIC container for enclave '${ENCLAVE_NAME}')"
  fi
else
  echo "(could not find enclave UUID for '${ENCLAVE_NAME}')"
fi

# Write result JSON.
jq -n \
  --arg label "${RUN_LABEL}" \
  --arg config "${CONFIG_FILE}" \
  --arg mode "${IMAGE_DOWNLOAD}" \
  --arg package_ref "${PACKAGE_REF}" \
  --arg command "${RUN_COMMAND}" \
  --argjson duration "${DURATION_S}" \
  --argjson new_images "${NUM_NEW_IMAGES}" \
  --arg services "${NUM_SERVICES}" \
  --argjson exit_code "${RUN_EXIT_CODE}" \
  --argjson apic_phases "${APIC_PHASES_JSON}" \
  '{
    label: $label,
    config: $config,
    image_download_mode: $mode,
    package_ref: $package_ref,
    command: $command,
    duration_seconds: $duration,
    new_images_pulled: $new_images,
    num_services: $services,
    exit_code: $exit_code,
    apic_phases: $apic_phases
  }' > "${RESULTS_DIR}/${RUN_LABEL}.json"

echo ""
echo "--- Result: ${RUN_LABEL} ---"
echo "Duration:       ${DURATION_S}s"
echo "Exit code:      ${RUN_EXIT_CODE}"
echo "New images:     ${NUM_NEW_IMAGES}"
echo "Services:       ${NUM_SERVICES}"
echo "APIC phases:    $(echo "${APIC_PHASES_JSON}" | jq -c '.')"
echo ""

# Clean up enclave to free resources for next run.
"${KT}" enclave rm "${ENCLAVE_NAME}" -f 2>/dev/null || true
docker network rm "kt-${ENCLAVE_NAME}" 2>/dev/null || true
