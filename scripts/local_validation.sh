#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/Yemma4.xcodeproj"
SCHEME="${SCHEME:-Yemma4}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/codex-xcode-derived-data/yemma-validation}"
DEFAULT_DEVICE_NAME="${DEVICE_NAME:-iPhone 17 Pro}"

IOS_SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
FOUNDATION_MODELS_FRAMEWORK="$IOS_SDK_PATH/System/Library/Frameworks/FoundationModels.framework"
if [[ ! -d "$FOUNDATION_MODELS_FRAMEWORK" ]]; then
  echo "Yemma requires Xcode 26 or newer with an iOS 26 SDK containing FoundationModels.framework." >&2
  exit 1
fi

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

RELEASE_PRODUCTS_DIR="$DERIVED_DATA_PATH/Build/Products/Release-iphoneos"
APP_PATH="$(find "$RELEASE_PRODUCTS_DIR" -maxdepth 1 -type d -name '*.app' -print -quit 2>/dev/null || true)"
if [[ -z "$APP_PATH" ]]; then
  echo "Could not find the Release iPhone app under $RELEASE_PRODUCTS_DIR." >&2
  exit 1
fi

EXECUTABLE_NAME="$(plutil -extract CFBundleExecutable raw -o - "$APP_PATH/Info.plist" 2>/dev/null || true)"
if [[ -z "$EXECUTABLE_NAME" ]]; then
  echo "Could not read CFBundleExecutable from $APP_PATH/Info.plist." >&2
  exit 1
fi
APP_BINARY="$APP_PATH/$EXECUTABLE_NAME"
if [[ ! -f "$APP_BINARY" ]]; then
  echo "Could not find the Release app executable at $APP_BINARY." >&2
  exit 1
fi

if ! xcrun otool -l "$APP_BINARY" | awk '
  $1 == "cmd" { loadCommand = $2 }
  $1 == "name" && $2 ~ /FoundationModels\.framework\/FoundationModels$/ {
    foundFoundationModels = 1
    if (loadCommand == "LC_LOAD_WEAK_DYLIB") {
      foundWeakFoundationModels = 1
    }
  }
  END { exit !(foundFoundationModels && foundWeakFoundationModels) }
'; then
  echo "FoundationModels.framework is missing or is not weak-linked in $APP_BINARY." >&2
  exit 1
fi

echo "Verified FoundationModels.framework is weak-linked for iOS 17 compatibility"
