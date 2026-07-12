#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/Yemma4.xcodeproj"
SCHEME="${SCHEME:-Yemma4}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/codex-xcode-derived-data/yemma-validation}"
DEFAULT_DEVICE_NAME="${DEVICE_NAME:-iPhone 17 Pro}"

DEVICE_ID="$(xcrun simctl list devices booted available | awk -F '[()]' '/Booted/ {print $2; exit}')"
if [[ -z "$DEVICE_ID" ]]; then
  DEVICE_ID="$(xcrun simctl list devices available | awk -v name="$DEFAULT_DEVICE_NAME" -F '[()]' '$0 ~ name {print $2; exit}')"
fi

if [[ -z "$DEVICE_ID" ]]; then
  echo "No available simulator matched \"$DEFAULT_DEVICE_NAME\"." >&2
  exit 1
fi

echo "Running Yemma tests on simulator $DEVICE_ID"
xcodebuild test \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -destination "platform=iOS Simulator,id=$DEVICE_ID" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -quiet

echo "Building unsigned Yemma Release for generic iOS device"
xcodebuild build \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  -quiet
