#!/bin/bash
set -e

# Log output for debugging
LOG_FILE="/tmp/launch_companion_simulator.log"
exec >> "$LOG_FILE" 2>&1
echo "=== $(date): Launching Companion Watch Simulator ==="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# TARGET_DEVICE_IDENTIFIER is passed by Xcode Scheme PostAction
PHONE_UDID="${TARGET_DEVICE_IDENTIFIER}"

# Use python to find the paired watch UDID and phone UDID
READ_PAIRS_PY=$(cat << 'PYEOF'
import json, subprocess, sys

target_phone = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else None

try:
    out = subprocess.check_output(["xcrun", "simctl", "list", "pairs", "-j"], timeout=5)
    data = json.loads(out)
except Exception as e:
    sys.exit(1)

pairs = data.get("pairs", {})

# 1. If target_phone provided, find matching pair
if target_phone:
    for pair_id, pair in pairs.items():
        phone = pair.get("phone", {})
        if phone.get("udid") == target_phone:
            watch = pair.get("watch", {})
            print(f"{phone.get('udid')}:{watch.get('udid')}")
            sys.exit(0)

# 2. Otherwise find booted pair or active pair
for pair_id, pair in pairs.items():
    phone = pair.get("phone", {})
    watch = pair.get("watch", {})
    if phone.get("state") == "Booted" or pair.get("state") == "(active, connected)":
        print(f"{phone.get('udid')}:{watch.get('udid')}")
        sys.exit(0)

# 3. Fallback: first pair
for pair_id, pair in pairs.items():
    phone = pair.get("phone", {})
    watch = pair.get("watch", {})
    if phone.get("udid") and watch.get("udid"):
        print(f"{phone.get('udid')}:{watch.get('udid')}")
        sys.exit(0)

sys.exit(1)
PYEOF
)

PAIR_INFO=$(python3 -c "$READ_PAIRS_PY" "$PHONE_UDID" 2>/dev/null || true)

if [ -z "$PAIR_INFO" ]; then
    echo "No paired watch simulator found."
    exit 0
fi

PHONE_UDID=$(echo "$PAIR_INFO" | cut -d':' -f1)
WATCH_UDID=$(echo "$PAIR_INFO" | cut -d':' -f2)

echo "Phone UDID: $PHONE_UDID"
echo "Watch UDID: $WATCH_UDID"

# 1. Boot watch simulator if not booted
echo "Booting Watch Simulator ($WATCH_UDID)..."
xcrun simctl boot "$WATCH_UDID" 2>/dev/null || true

# 2. Open Simulator app and ensure both windows are active
open -a Simulator --args -CurrentDeviceUDID "$WATCH_UDID"
if [ -n "$PHONE_UDID" ]; then
    open -a Simulator --args -CurrentDeviceUDID "$PHONE_UDID"
fi

# 3. If BUILT_PRODUCTS_DIR is provided, install watch app
WATCH_BUNDLE_ID="com.radarmap.watch.watchkitapp"
if [ -n "$BUILT_PRODUCTS_DIR" ]; then
    EMBEDDED_WATCH_APP="$BUILT_PRODUCTS_DIR/RadarMap.app/Watch/RadarMap Watch App.app"
    STANDALONE_WATCH_APP="$BUILT_PRODUCTS_DIR/../Debug-watchsimulator/RadarMap Watch App.app"
    
    if [ -d "$EMBEDDED_WATCH_APP" ]; then
        echo "Installing embedded watch app from $EMBEDDED_WATCH_APP..."
        xcrun simctl install "$WATCH_UDID" "$EMBEDDED_WATCH_APP" 2>/dev/null || true
    elif [ -d "$STANDALONE_WATCH_APP" ]; then
        echo "Installing standalone watch app from $STANDALONE_WATCH_APP..."
        xcrun simctl install "$WATCH_UDID" "$STANDALONE_WATCH_APP" 2>/dev/null || true
    fi
fi

# 4. Wait up to 5 seconds for watch simulator to be booted
for i in {1..5}; do
    STATUS=$(xcrun simctl list devices -j | python3 -c '
import json, sys
data = json.load(sys.stdin)
watch_id = sys.argv[1]
for runtime, dev_list in data.get("devices", {}).items():
    for dev in dev_list:
        if dev.get("udid") == watch_id:
            print(dev.get("state"))
            sys.exit(0)
print("Unknown")
' "$WATCH_UDID" 2>/dev/null || echo "Unknown")
    if [ "$STATUS" = "Booted" ]; then
        break
    fi
    sleep 1
done

# 5. Launch the Watch App
echo "Launching Watch App ($WATCH_BUNDLE_ID)..."
xcrun simctl launch "$WATCH_UDID" "$WATCH_BUNDLE_ID" 2>/dev/null || {
    echo "Initial launch failed, retrying in 1 second..."
    sleep 1
    xcrun simctl launch "$WATCH_UDID" "$WATCH_BUNDLE_ID" 2>/dev/null || true
}

echo "Companion watch launch complete."
