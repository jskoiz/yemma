#!/bin/sh

set -euo pipefail

echo "Preparing mlx-swift-lm local dependency for Xcode Cloud"

REPO_ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$(pwd)}"
WORKSPACE_ROOT="$(cd "${REPO_ROOT}/.." && pwd)"

MLX_PARENT_DIR="${WORKSPACE_ROOT}/mlx-vlm-swift"
MLX_SWIFT_LM_DIR="${MLX_PARENT_DIR}/mlx-swift-lm"

MLX_SWIFT_LM_URL="https://github.com/ml-explore/mlx-swift-lm.git"
MLX_SWIFT_LM_BASE_REVISION="7d9a6ab38f20778aae9f04d231b05315269303c7"

rm -rf "${MLX_SWIFT_LM_DIR}"
mkdir -p "${MLX_PARENT_DIR}"

git clone "${MLX_SWIFT_LM_URL}" "${MLX_SWIFT_LM_DIR}"
git -C "${MLX_SWIFT_LM_DIR}" checkout --detach "${MLX_SWIFT_LM_BASE_REVISION}"
git -C "${MLX_SWIFT_LM_DIR}" apply \
  "${REPO_ROOT}/ci_scripts/patches/001-mlx-swift-lm-yemma-gemma4-port.patch"

echo "Prepared ${MLX_SWIFT_LM_DIR}"
