#!/usr/bin/env bash
set -euo pipefail

# run-suite.sh — Orchestrate baseline vs patched benchmark comparison.
#
# Usage: ./scripts/run-suite.sh [patched-branch]
#
# Env vars:
#   BASELINE_BRANCH   Baseline kurtosis branch (default: bench-baseline)
#   PATCHED_BRANCH    Patched kurtosis branch (default: arg $1 or refactor/boot-perf)
#   CONFIGS           Space-separated config files (default: configs/single-client.yaml configs/multi-client.yaml)
#   PACKAGE_REFS      Space-separated package refs (default: local github.com/ethpandaops/ethereum-package)
#   EP_REPO           ethereum-package git URL for local clone (default: https://github.com/ethpandaops/ethereum-package.git)
#   EP_DIR            Path to local ethereum-package checkout (default: ./ethereum-package)
#   SKIP_BUILD        Skip build phase (default: false)
#   RESULTS_DIR       Output directory (default: ./results)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BASELINE_BRANCH="${BASELINE_BRANCH:-bench-baseline}"
PATCHED_BRANCH="${PATCHED_BRANCH:-${1:-refactor/boot-perf}}"
CONFIGS="${CONFIGS:-configs/single-client.yaml configs/multi-client.yaml}"
PACKAGE_REFS="${PACKAGE_REFS:-local github.com/ethpandaops/ethereum-package}"
SKIP_BUILD="${SKIP_BUILD:-false}"
RESULTS_DIR="${RESULTS_DIR:-./results}"
EP_REPO="${EP_REPO:-https://github.com/ethpandaops/ethereum-package.git}"
EP_DIR="${EP_DIR:-./ethereum-package}"

BUILDS_DIR="${RESULTS_DIR}/builds"
BASELINE_DIR="${BUILDS_DIR}/baseline"
PATCHED_DIR="${BUILDS_DIR}/patched"

echo "============================================"
echo "Kurtosis Benchmark Suite"
echo "============================================"
echo "Baseline branch: ${BASELINE_BRANCH}"
echo "Patched branch:  ${PATCHED_BRANCH}"
echo "Configs:         ${CONFIGS}"
echo "Package refs:    ${PACKAGE_REFS}"
echo "Results dir:     ${RESULTS_DIR}"
echo "Skip build:      ${SKIP_BUILD}"
echo "============================================"
echo ""

mkdir -p "${RESULTS_DIR}" "${BASELINE_DIR}" "${PATCHED_DIR}"

# Helper to derive a short label from a config file path.
config_label() {
  basename "$1" .yaml | sed 's/-client//'
}

# Helper to derive a short label from a package ref.
pkg_label() {
  local ref="$1"
  if [[ "${ref}" == "local" || "${ref}" == "." ]]; then
    echo "local"
  else
    echo "remote"
  fi
}

# Resolve a package ref to the actual path/URL for kurtosis run.
resolve_pkg_ref() {
  local ref="$1"
  if [[ "${ref}" == "local" ]]; then
    echo "${EP_DIR}"
  else
    echo "${ref}"
  fi
}

# ── Phase 1: Build ──────────────────────────────────────────────────

BASELINE_SHA=""
PATCHED_SHA=""

if [[ "${SKIP_BUILD}" != "true" ]]; then
  echo "=== Phase 1: Building kurtosis binaries ==="
  echo ""

  echo "--- Building baseline (${BASELINE_BRANCH}) ---"
  BASELINE_SHA=$("${SCRIPT_DIR}/build-kurtosis.sh" "${BASELINE_BRANCH}" "$(cd "${BASELINE_DIR}" && pwd)" | tail -1)
  echo "Baseline SHA: ${BASELINE_SHA}"
  echo ""

  echo "--- Building patched (${PATCHED_BRANCH}) ---"
  PATCHED_SHA=$("${SCRIPT_DIR}/build-kurtosis.sh" "${PATCHED_BRANCH}" "$(cd "${PATCHED_DIR}" && pwd)" | tail -1)
  echo "Patched SHA: ${PATCHED_SHA}"
  echo ""
else
  echo "=== Phase 1: Skipping builds (SKIP_BUILD=true) ==="
  # Try to detect SHAs from existing builds.
  if [[ -x "${BASELINE_DIR}/kurtosis" ]]; then
    BASELINE_SHA=$("${BASELINE_DIR}/kurtosis" version 2>/dev/null | grep -oE '[0-9a-f]{7,}' | head -1 || echo "unknown")
  fi
  if [[ -x "${PATCHED_DIR}/kurtosis" ]]; then
    PATCHED_SHA=$("${PATCHED_DIR}/kurtosis" version 2>/dev/null | grep -oE '[0-9a-f]{7,}' | head -1 || echo "unknown")
  fi
  echo ""
fi

# Save build metadata for summarize.sh.
jq -n \
  --arg baseline_branch "${BASELINE_BRANCH}" \
  --arg baseline_sha "${BASELINE_SHA}" \
  --arg patched_branch "${PATCHED_BRANCH}" \
  --arg patched_sha "${PATCHED_SHA}" \
  '{
    baseline_branch: $baseline_branch,
    baseline_sha: $baseline_sha,
    patched_branch: $patched_branch,
    patched_sha: $patched_sha
  }' > "${RESULTS_DIR}/build-info.json"

# ── Clone ethereum-package for local benchmarks ─────────────────────

# Check if any PACKAGE_REFS need a local checkout.
if echo "${PACKAGE_REFS}" | grep -qw "local"; then
  if [[ -d "${EP_DIR}/.git" ]]; then
    echo "=== Using existing ethereum-package at ${EP_DIR} ==="
  else
    echo "=== Cloning ethereum-package for local benchmarks ==="
    git clone --depth 1 "${EP_REPO}" "${EP_DIR}"
  fi
  echo ""
fi

# ── Phase 1b: Pre-pull images ───────────────────────────────────────

echo "=== Phase 1b: Pre-pulling Docker images ==="
echo ""

# shellcheck disable=SC2086
EP_DIR="${EP_DIR}" "${SCRIPT_DIR}/pull-images.sh" ${CONFIGS}

# ── Phase 2: Run baseline matrix ────────────────────────────────────

echo "=== Phase 2: Running baseline benchmarks ==="
echo ""

# Fully tear down any existing kurtosis state before starting baseline.
echo "--- Cleaning up any existing kurtosis state ---"
"${BASELINE_DIR}/kurtosis" engine stop 2>/dev/null || true
"${PATCHED_DIR}/kurtosis" engine stop 2>/dev/null || true
docker rm -f $(docker ps -aq --filter "label=com.kurtosistech.enclave-id") 2>/dev/null || true
docker rm -f $(docker ps -aq --filter "name=kurtosis") 2>/dev/null || true
docker network ls --filter "name=kt-" --format '{{.Name}}' | xargs -r docker network rm 2>/dev/null || true
docker volume ls --filter "name=kurtosis" --format '{{.Name}}' | xargs -r docker volume rm 2>/dev/null || true
echo ""

"${BASELINE_DIR}/kurtosis" analytics disable 2>/dev/null || true
"${BASELINE_DIR}/kurtosis" engine start
echo ""

for config in ${CONFIGS}; do
  for pkg_ref in ${PACKAGE_REFS}; do
    resolved_ref="$(resolve_pkg_ref "${pkg_ref}")"
    label="baseline-$(config_label "${config}")-$(pkg_label "${pkg_ref}")"
    echo "--- Running: ${label} ---"
    KURTOSIS_BIN="${BASELINE_DIR}/kurtosis" \
    KURTOSIS_ENABLE_PARALLEL=false \
    PACKAGE_REF="${resolved_ref}" \
    RESULTS_DIR="${RESULTS_DIR}" \
      "${SCRIPT_DIR}/run-benchmark.sh" "${config}" "${label}" missing || true
    echo ""
  done
done

# ── Phase 3: Run patched matrix ─────────────────────────────────────

echo "=== Phase 3: Running patched benchmarks ==="
echo ""

# Fully tear down baseline kurtosis — engine, enclaves, containers, networks.
# This ensures the patched engine starts completely clean with no leftover state.
echo "--- Tearing down baseline kurtosis ---"
"${BASELINE_DIR}/kurtosis" engine stop 2>/dev/null || true
docker rm -f $(docker ps -aq --filter "label=com.kurtosistech.enclave-id") 2>/dev/null || true
docker rm -f $(docker ps -aq --filter "name=kurtosis") 2>/dev/null || true
docker network ls --filter "name=kt-" --format '{{.Name}}' | xargs -r docker network rm 2>/dev/null || true
docker volume ls --filter "name=kurtosis" --format '{{.Name}}' | xargs -r docker volume rm 2>/dev/null || true
echo ""

"${PATCHED_DIR}/kurtosis" analytics disable 2>/dev/null || true
"${PATCHED_DIR}/kurtosis" engine start
echo ""

for config in ${CONFIGS}; do
  for pkg_ref in ${PACKAGE_REFS}; do
    resolved_ref="$(resolve_pkg_ref "${pkg_ref}")"
    label="patched-$(config_label "${config}")-$(pkg_label "${pkg_ref}")"
    echo "--- Running: ${label} ---"
    KURTOSIS_BIN="${PATCHED_DIR}/kurtosis" \
    KURTOSIS_ENABLE_PARALLEL=true \
    PACKAGE_REF="${resolved_ref}" \
    RESULTS_DIR="${RESULTS_DIR}" \
      "${SCRIPT_DIR}/run-benchmark.sh" "${config}" "${label}" missing || true
    echo ""
  done
done

# ── Phase 4: Report ─────────────────────────────────────────────────

echo "=== Phase 4: Generating summary ==="
echo ""

"${SCRIPT_DIR}/summarize.sh" "${RESULTS_DIR}"
"${SCRIPT_DIR}/generate-report.sh" "${RESULTS_DIR}"

echo ""
echo "Suite complete. Results in ${RESULTS_DIR}/"
