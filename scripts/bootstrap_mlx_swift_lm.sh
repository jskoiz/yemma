#!/bin/sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

MLX_SWIFT_LM_DIR="${MLX_SWIFT_LM_DIR:-${REPO_ROOT}/Dependencies/mlx-swift-lm}"
MLX_SWIFT_LM_SOURCE_DIR="${MLX_SWIFT_LM_SOURCE_DIR:-${REPO_ROOT}/../mlx-vlm-swift/mlx-swift-lm}"
MLX_SWIFT_LM_BASE_REVISION="8b5eef7c9c1a698deb00f2699cb847988491163b"
PATCH_FILE="${REPO_ROOT}/ci_scripts/patches/001-mlx-swift-lm-yemma-gemma4-port.patch"

echo "Bootstrapping mlx-swift-lm into ${MLX_SWIFT_LM_DIR}"

if [ ! -d "${MLX_SWIFT_LM_SOURCE_DIR}/.git" ]; then
    echo "Missing validated mlx-swift-lm seed checkout at ${MLX_SWIFT_LM_SOURCE_DIR}" >&2
    echo "Set MLX_SWIFT_LM_SOURCE_DIR to a local clone at ${MLX_SWIFT_LM_BASE_REVISION}." >&2
    exit 1
fi

SOURCE_HEAD="$(git -C "${MLX_SWIFT_LM_SOURCE_DIR}" rev-parse HEAD)"
if [ "${SOURCE_HEAD}" != "${MLX_SWIFT_LM_BASE_REVISION}" ]; then
    echo "Seed checkout is at ${SOURCE_HEAD}, expected ${MLX_SWIFT_LM_BASE_REVISION}" >&2
    exit 1
fi

rm -rf "${MLX_SWIFT_LM_DIR}"
mkdir -p "$(dirname "${MLX_SWIFT_LM_DIR}")"

git clone "${MLX_SWIFT_LM_SOURCE_DIR}" "${MLX_SWIFT_LM_DIR}"
git -C "${MLX_SWIFT_LM_DIR}" checkout --detach "${MLX_SWIFT_LM_BASE_REVISION}"
echo "Seed checkout already carries the Gemma 4 port recorded in ${PATCH_FILE}"

echo "Ready: ${MLX_SWIFT_LM_DIR}"
