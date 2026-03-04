#!/usr/bin/env bash
set -euo pipefail

# build-kurtosis.sh — Clone a kurtosis fork branch and build CLI + Docker images.
#
# Usage: ./scripts/build-kurtosis.sh <branch> <install-dir>
#
# Env vars:
#   KURTOSIS_REPO  Git URL to clone (default: https://github.com/mattevans/kurtosis.git)
#
# Outputs:
#   - kurtosistech/engine:<sha> Docker image
#   - kurtosistech/core:<sha> Docker image
#   - <install-dir>/kurtosis CLI binary
#   - Last line of stdout is the git SHA (caller captures with `tail -1`)

BRANCH="${1:?Usage: build-kurtosis.sh <branch> <install-dir>}"
INSTALL_DIR="${2:?Usage: build-kurtosis.sh <branch> <install-dir>}"
KURTOSIS_REPO="${KURTOSIS_REPO:-https://github.com/mattevans/kurtosis.git}"

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_BASE}"' EXIT

echo "=== Building kurtosis from ${KURTOSIS_REPO} @ ${BRANCH} ==="

# Shallow clone the branch.
git clone --depth 1 --branch "${BRANCH}" "${KURTOSIS_REPO}" "${TMPDIR_BASE}/kurtosis"
cd "${TMPDIR_BASE}/kurtosis"

GIT_SHA="$(git rev-parse --short HEAD)"
echo "Git SHA: ${GIT_SHA}"

# Generate version info.
if [[ -f scripts/generate-kurtosis-version.sh ]]; then
  bash scripts/generate-kurtosis-version.sh
fi

# Build engine Docker image.
echo "--- Building engine image ---"
bash engine/scripts/build.sh false false

# Build core Docker image.
echo "--- Building core image ---"
bash core/scripts/build.sh false false

# Build CLI binary.
echo "--- Building CLI binary ---"
mkdir -p "${INSTALL_DIR}"
(cd cli/cli && go build -o "${INSTALL_DIR}/kurtosis" .)

echo "--- Build complete ---"
echo "CLI:    ${INSTALL_DIR}/kurtosis"
echo "Engine: kurtosistech/engine (latest build)"
echo "Core:   kurtosistech/core (latest build)"

# Last line: git SHA for caller to capture.
echo "${GIT_SHA}"
