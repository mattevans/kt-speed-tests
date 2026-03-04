#!/usr/bin/env bash
set -euo pipefail

# pull-images.sh — Pre-pull all Docker images needed by benchmark configs.
#
# Usage: ./scripts/pull-images.sh [configs...]
#
# Parses the YAML config files to determine which EL/CL clients are used,
# resolves their default images (accounting for minimal preset), and pulls
# them all in parallel via the docker cache proxy.
#
# Env vars:
#   DOCKER_CACHE_URL  Cache proxy URL (default: docker.ethquokkaops.io)
#   EP_DIR            ethereum-package checkout (default: ./ethereum-package)

DOCKER_CACHE_URL="${DOCKER_CACHE_URL:-docker.ethquokkaops.io}"
EP_DIR="${EP_DIR:-./ethereum-package}"

CONFIGS=("$@")
if [[ ${#CONFIGS[@]} -eq 0 ]]; then
  echo "Usage: pull-images.sh <config1.yaml> [config2.yaml ...]"
  exit 1
fi

# ── Default image maps (must match ethereum-package/src/package_io/input_parser.star) ──

declare -A EL_IMAGES=(
  [geth]="ethereum/client-go:latest"
  [erigon]="erigontech/erigon:latest"
  [nethermind]="nethermind/nethermind:latest"
  [besu]="hyperledger/besu:latest"
  [reth]="ghcr.io/paradigmxyz/reth"
  [ethereumjs]="ethpandaops/ethereumjs:master"
)

declare -A CL_IMAGES=(
  [lighthouse]="sigp/lighthouse:latest"
  [teku]="consensys/teku:latest"
  [nimbus]="statusim/nimbus-eth2:multiarch-latest"
  [prysm]="offchainlabs/prysm-beacon-chain:stable"
  [lodestar]="chainsafe/lodestar:latest"
  [grandine]="sifrai/grandine:stable"
)

declare -A CL_IMAGES_MINIMAL=(
  [lighthouse]="ethpandaops/lighthouse:unstable"
  [teku]="ethpandaops/teku:master"
  [nimbus]="ethpandaops/nimbus-eth2:unstable-minimal"
  [prysm]="ethpandaops/prysm-beacon-chain:develop-minimal"
  [lodestar]="ethpandaops/lodestar:unstable"
  [grandine]="ethpandaops/grandine:develop-minimal"
)

declare -A VC_IMAGES=(
  [lighthouse]="sigp/lighthouse:latest"
  [teku]="consensys/teku:latest"
  [nimbus]="statusim/nimbus-validator-client:multiarch-latest"
  [prysm]="offchainlabs/prysm-validator:stable"
  [lodestar]="chainsafe/lodestar:latest"
  [grandine]="sifrai/grandine:stable"
)

declare -A VC_IMAGES_MINIMAL=(
  [lighthouse]="ethpandaops/lighthouse:unstable"
  [teku]="ethpandaops/teku:master"
  [nimbus]="ethpandaops/nimbus-validator-client:unstable-minimal"
  [prysm]="ethpandaops/prysm-validator:develop-minimal"
  [lodestar]="ethpandaops/lodestar:unstable"
  [grandine]="ethpandaops/grandine:develop-minimal"
)

# Tool images always needed.
TOOL_IMAGES=(
  "ethpandaops/ethereum-genesis-generator:5.3.0"
  "protolambda/eth2-val-tools:latest"
)

# ── Parse configs and collect unique images ──

declare -A IMAGES_MAP

add_image() {
  IMAGES_MAP["$1"]=1
}

for tool_img in "${TOOL_IMAGES[@]}"; do
  add_image "${tool_img}"
done

for config in "${CONFIGS[@]}"; do
  if [[ ! -f "${config}" ]]; then
    echo "Warning: config file not found: ${config}, skipping"
    continue
  fi

  # Detect preset.
  PRESET=$(yq '.network_params.preset // "mainnet"' "${config}" 2>/dev/null || echo "mainnet")
  IS_MINIMAL=false
  [[ "${PRESET}" == "minimal" ]] && IS_MINIMAL=true

  # Extract EL/CL types from participants.
  EL_TYPES=$(yq '.participants[].el_type' "${config}" 2>/dev/null || true)
  CL_TYPES=$(yq '.participants[].cl_type' "${config}" 2>/dev/null || true)

  # Resolve EL images.
  for el in ${EL_TYPES}; do
    img="${EL_IMAGES[${el}]:-}"
    [[ -n "${img}" ]] && add_image "${img}"
  done

  # Resolve CL images (minimal vs mainnet).
  for cl in ${CL_TYPES}; do
    if [[ "${IS_MINIMAL}" == "true" ]]; then
      img="${CL_IMAGES_MINIMAL[${cl}]:-}"
    else
      img="${CL_IMAGES[${cl}]:-}"
    fi
    [[ -n "${img}" ]] && add_image "${img}"

    # VC image — CL clients that run VC in-process (nimbus, teku, grandine) don't
    # need a separate VC pull by default. Others (prysm, lighthouse, lodestar) do.
    case "${cl}" in
      nimbus|teku|grandine) ;; # VC runs in CL process
      *)
        if [[ "${IS_MINIMAL}" == "true" ]]; then
          vc_img="${VC_IMAGES_MINIMAL[${cl}]:-}"
        else
          vc_img="${VC_IMAGES[${cl}]:-}"
        fi
        [[ -n "${vc_img}" ]] && add_image "${vc_img}"
        ;;
    esac
  done

  # Additional service images specified directly in config.
  ADDITIONAL=$(yq '.additional_services[]' "${config}" 2>/dev/null || true)
  for svc in ${ADDITIONAL}; do
    case "${svc}" in
      dora)
        img=$(yq '.dora_params.image // "ethpandaops/dora:latest"' "${config}" 2>/dev/null)
        add_image "${img}"
        ;;
      spamoor)
        img=$(yq '.spamoor_params.image // "ethpandaops/spamoor:latest"' "${config}" 2>/dev/null)
        add_image "${img}"
        ;;
    esac
  done
done

UNIQUE_IMAGES=("${!IMAGES_MAP[@]}")

echo "============================================"
echo "Pre-pulling ${#UNIQUE_IMAGES[@]} images"
echo "Cache proxy: ${DOCKER_CACHE_URL}"
echo "============================================"

# ── Pull through cache in parallel, then tag to original name ──

pull_and_tag() {
  local img="$1"
  local cache_url="$2"

  # Build cache URL: replace registry prefix or prepend dh/ for Docker Hub images.
  local cache_img
  if [[ "${img}" == ghcr.io/* ]]; then
    cache_img="${cache_url}/ghcr/${img#ghcr.io/}"
  elif [[ "${img}" == */* ]]; then
    cache_img="${cache_url}/dh/${img}"
  else
    cache_img="${cache_url}/dh/library/${img}"
  fi

  echo "  Pulling ${cache_img} -> ${img}"
  if docker pull "${cache_img}" >/dev/null 2>&1; then
    docker tag "${cache_img}" "${img}" 2>/dev/null || true
    echo "  OK: ${img}"
  else
    echo "  WARN: cache pull failed for ${img}, pulling direct"
    docker pull "${img}" >/dev/null 2>&1 || echo "  FAIL: ${img}"
  fi
}

PIDS=()
for img in "${UNIQUE_IMAGES[@]}"; do
  pull_and_tag "${img}" "${DOCKER_CACHE_URL}" &
  PIDS+=($!)
done

# Wait for all pulls.
FAILED=0
for pid in "${PIDS[@]}"; do
  if ! wait "${pid}"; then
    FAILED=$((FAILED + 1))
  fi
done

echo ""
echo "Pre-pull complete. ${#UNIQUE_IMAGES[@]} images, ${FAILED} failures."
echo ""
