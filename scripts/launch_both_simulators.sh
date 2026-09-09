#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Launching Both iPhone and Watch Simulators ==="

# 1. Identify active paired devices
PAIR_INFO=$(python3 -c '
import json, subprocess, sys
try:
    out = subprocess.check_output(["xcrun", "simctl", "list", "pairs", "-j"])
    data = json.loads(out)
    for pair_id, pair in data.get("pairs", {}).items():
        phone = pair.get("phone", {})
        watch = pair.get("watch", {})
        if phone.get("state") == "Booted" or pair.get("state") == "(active, connected)":
            print(f"{phone.get(\"udid\")}:{watch.get(\"udid\")}")
            sys.exit(0)
    for pair_id, pair in data.get("pairs", {}).items():
        phone = pair.get("phone", {})
        watch = pair.get("watch", {})
        if phone.get("udid") and watch.get("udid"):
            print(f"{phone.get(\"udid\")}:{watch.get(\"udid\")}")
            sys.exit(0)
except Exception:
    pass
sys.exit(1)
')

if [ -z "$PAIR_INFO" ]; then
    echo "Error: No paired iPhone + Apple Watch simulator found."
    echo "Create or select a paired simulator in Xcode (Window > Devices and Simulators)."
    exit 1
fi

PHONE_UDID=$(echo "$PAIR_INFO" | cut -d':' -f1)
WATCH_UDID=$(echo "$PAIR_INFO" | cut -d':' -f2)

echo "Phone UDID: $PHONE_UDID"
echo "Watch UDID: $WATCH_UDID"

# 2. Boot both simulators
echo "Ensuring both simulators are booted..."
xcrun simctl boot "$PHONE_UDID" 2>/dev/null || true
xcrun simctl boot "$WATCH_UDID" 2>/dev/null || true

# 3. Bring Simulator window to front with both devices
open -a Simulator --args -CurrentDeviceUDID "$PHONE_UDID"
open -a Simulator --args -CurrentDeviceUDID "$WATCH_UDID"

# 4. Build once via RadarMap scheme (which automatically compiles both Phone and Watch apps with identical build numbers)
echo "Building project (RadarMap scheme)..."
xcodebuild -project "$ROOT_DIR/RadarMap.xcodeproj" \
    -scheme "RadarMap" \
    -destination "platform=iOS Simulator,id=$PHONE_UDID" \
    -quiet build

# 5. Launch both applications
echo "Launching iOS app (com.radarmap.watch)..."
xcrun simctl launch "$PHONE_UDID" com.radarmap.watch

echo "Launching Watch app (com.radarmap.watch.watchkitapp)..."
xcrun simctl launch "$WATCH_UDID" com.radarmap.watch.watchkitapp

BUILD_NUM=$(cat "$ROOT_DIR/build_number.txt" | tr -d '[:space:]')
echo "=== Successfully launched both simulators with Build #$BUILD_NUM ==="
