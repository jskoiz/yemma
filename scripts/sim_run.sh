#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/Yemma4.xcodeproj"
SCHEME="${SCHEME:-Yemma4}"
BUNDLE_ID="${BUNDLE_ID:-com.avmillabs.yemma4}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/.deriveddata}"
DEFAULT_DEVICE_NAME="${DEVICE_NAME:-iPhone 17 Pro}"

BOOTED_DEVICE_ID="$(xcrun simctl list devices booted available | awk -F '[()]' '/Booted/ {print $2; exit}')"

if [[ -n "$BOOTED_DEVICE_ID" ]]; then
  DEVICE_ID="$BOOTED_DEVICE_ID"
else
  DEVICE_ID="$(xcrun simctl list devices available | awk -v name="$DEFAULT_DEVICE_NAME" -F '[()]' '$0 ~ name {print $2; exit}')"
  if [[ -z "$DEVICE_ID" ]]; then
    echo "No available simulator matched \"$DEFAULT_DEVICE_NAME\"." >&2
    exit 1
  fi
  open -a Simulator
  xcrun simctl boot "$DEVICE_ID" >/dev/null 2>&1 || true
fi

xcrun simctl bootstatus "$DEVICE_ID" -b

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -destination "id=$DEVICE_ID" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build

APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug-iphonesimulator/$SCHEME.app"

xcrun simctl terminate "$DEVICE_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$DEVICE_ID" "$APP_PATH"

if [[ -f "$ROOT_DIR/.local-models/gemma-4-e4b-it-q4km.gguf" ]]; then
  "$ROOT_DIR/scripts/sim_seed_model.sh" "$DEVICE_ID"
else
  echo "No local model found at $ROOT_DIR/.local-models/gemma-4-e4b-it-q4km.gguf"
  echo "The app will fall back to its normal download screen."
fi

xcrun simctl launch "$DEVICE_ID" "$BUNDLE_ID"
