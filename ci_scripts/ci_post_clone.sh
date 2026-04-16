#!/bin/sh

set -euo pipefail

echo "Preparing mlx-swift-lm local dependency for Xcode Cloud"

REPO_ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"
"${REPO_ROOT}/scripts/bootstrap_mlx_swift_lm.sh"

echo "Prepared mlx-swift-lm dependency checkout"
