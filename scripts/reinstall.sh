#!/bin/bash
# Rebuild and reinstall the iOS client on a connected iPhone.
#
# Free Personal Team provisioning profiles expire after 7 days, after which the
# app refuses to launch. Running this renews the profile and reinstalls.
#
#   ./scripts/reinstall.sh            # auto-detect the connected device
#   ./scripts/reinstall.sh <udid>     # target a specific device
set -euo pipefail

cd "$(dirname "$0")/../Client"

UDID="${1:-}"
if [[ -z "$UDID" ]]; then
  # Pick a device that is actually reachable. `devicectl list devices` also
  # lists simulators and offline phones, and a plain grep can select one of
  # those instead of the connected iPhone.
  xcrun devicectl list devices --json-output /tmp/oriel-devices.json >/dev/null 2>&1
  UDID="$(python3 - /tmp/oriel-devices.json <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit
for dev in data.get("result", {}).get("devices", []):
    udid = dev.get("hardwareProperties", {}).get("udid")
    transport = dev.get("connectionProperties", {}).get("transportType")
    if udid and transport in ("wired", "localNetwork"):
        print(udid)
        break
PY
)"
fi

if [[ -z "$UDID" ]]; then
  echo "No connected iPhone found."
  echo "Plug it in (or enable wireless debugging), unlock it, then run this again."
  exit 1
fi

echo "==> Building for $UDID"
if ! xcodebuild -project OrielClient.xcodeproj -scheme Oriel \
      -destination "id=$UDID" -allowProvisioningUpdates -configuration Debug build \
      | grep -E "error:|BUILD (SUCCEEDED|FAILED)"; then
  echo "Build failed. If it mentions provisioning, open the project in Xcode once."
  exit 1
fi

APP="$(find "$HOME/Library/Developer/Xcode/DerivedData" -name "Oriel.app" \
  -path "*Debug-iphoneos*" | head -1)"
if [[ -z "$APP" ]]; then
  echo "Built app not found in DerivedData."
  exit 1
fi

echo "==> Installing"
xcrun devicectl device install app --device "$UDID" "$APP"

echo "==> Launching"
if ! xcrun devicectl device process launch --device "$UDID" com.omk.oriel.ios >/dev/null 2>&1; then
  echo "Installed, but iOS refused to launch it."
  echo "Re-trust the developer: Settings > General > VPN & Device Management."
fi

EXPIRY="$(security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null \
  | plutil -extract ExpirationDate raw - 2>/dev/null || echo unknown)"
echo "==> Profile valid until $EXPIRY"
