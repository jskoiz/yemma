#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_ID="${BUNDLE_ID:-com.avmillabs.yemma4}"
MODEL_NAME="${MODEL_NAME:-gemma-4-e4b-it-q4km.gguf}"
MODEL_PATH="${MODEL_PATH:-$ROOT_DIR/.local-models/$MODEL_NAME}"
DEVICE_ID="${1:-booted}"

if [[ ! -f "$MODEL_PATH" ]]; then
  echo "Local model file not found: $MODEL_PATH" >&2
  echo "Place the GGUF there or set MODEL_PATH=/absolute/path/to/model.gguf" >&2
  exit 1
fi

DATA_CONTAINER="$(xcrun simctl get_app_container "$DEVICE_ID" "$BUNDLE_ID" data)"
DOCUMENTS_DIR="$DATA_CONTAINER/Documents"
TARGET_PATH="$DOCUMENTS_DIR/$MODEL_NAME"

mkdir -p "$DOCUMENTS_DIR"
rm -f "$TARGET_PATH"
ln -s "$MODEL_PATH" "$TARGET_PATH"

echo "Seeded simulator model link:"
echo "  $TARGET_PATH -> $MODEL_PATH"
