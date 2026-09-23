#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/Yemma4.xcodeproj"
SCHEME="${SCHEME:-Yemma4}"
BUNDLE_ID="${BUNDLE_ID:-com.avmillabs.yemma4}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/codex-xcode-derived-data/yemma-simulator}"
DEFAULT_DEVICE_NAME="${DEVICE_NAME:-}"

# An explicit device name wins; otherwise reuse a booted iPhone or the first available iPhone.
DEVICE_ID="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
name = sys.argv[1]
devices = [d for group in json.load(sys.stdin)["devices"].values() for d in group if d.get("isAvailable")]
if name:
    candidates = [d for d in devices if d["name"] == name]
else:
    candidates = sorted([d for d in devices if d["name"].startswith("iPhone")], key=lambda d: d["state"] != "Booted")
print(candidates[0]["udid"] if candidates else "")
' "$DEFAULT_DEVICE_NAME")"
if [[ -z "$DEVICE_ID" ]]; then
  echo "No available iPhone simulator matched ${DEFAULT_DEVICE_NAME:-the default selection}." >&2
  exit 1
fi

open -a Simulator
xcrun simctl boot "$DEVICE_ID" >/dev/null 2>&1 || true

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
echo "Launching simulator build in UI-test mode (mock chat replies, no local model download)."

xcrun simctl launch "$DEVICE_ID" "$BUNDLE_ID"
