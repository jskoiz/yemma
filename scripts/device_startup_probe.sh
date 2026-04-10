#!/bin/zsh
set -euo pipefail

DEVICE_NAME="${DEVICE_NAME:-Jerry’s iPhone}"
BUNDLE_ID="${BUNDLE_ID:-com.avmillabs.yemma4}"
FORCE_ONBOARDING="${FORCE_ONBOARDING:-0}"
OS_ACTIVITY_DT_MODE_VALUE="${OS_ACTIVITY_DT_MODE_VALUE:-1}"
LOCK_STATE_JSON="$(mktemp)"
trap 'rm -f "$LOCK_STATE_JSON"' EXIT

environment_json="{\"OS_ACTIVITY_DT_MODE\":\"$OS_ACTIVITY_DT_MODE_VALUE\""
launch_args=()

if [[ "$FORCE_ONBOARDING" == "1" ]]; then
  environment_json+=",\"YEMMA_FORCE_ONBOARDING\":\"1\""
  launch_args+=(--yemma-force-onboarding)
fi

environment_json+="}"

xcrun devicectl --json-output "$LOCK_STATE_JSON" device info lockState --device "$DEVICE_NAME" >/dev/null 2>/dev/null

if [[ "$(plutil -extract result.passcodeRequired raw -o - "$LOCK_STATE_JSON" 2>/dev/null || echo false)" == "true" ]]; then
  echo "Unlock $DEVICE_NAME and rerun this probe." >&2
  exit 1
fi

echo "Launching $BUNDLE_ID on $DEVICE_NAME"
if [[ "$FORCE_ONBOARDING" == "1" ]]; then
  echo "Forcing onboarding path for startup verification."
fi

xcrun devicectl device process launch \
  --device "$DEVICE_NAME" \
  --environment-variables "$environment_json" \
  --terminate-existing \
  --console \
  "$BUNDLE_ID" \
  "${launch_args[@]}"
