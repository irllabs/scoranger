#!/usr/bin/env bash
# Launch to library: process start to the first frame with library rows, on a
# simulator holding a library the size of a working musician's.
#
# The budget is 300 ms (Ali, 2026-10-21: "There is a slight delay when I open
# the app before I can see my pieces"). The number is `LaunchTiming`'s: the
# kernel's start time for the process to the render server committing the
# frame with the first row. The app writes it to Library/Caches under
# -launchTiming, and this collects it from the data container.
#
# NOT in the gate. The gate runs four simulators at once, and a wall-clock
# budget measured on a loaded host measures the host. Run this on a quiet Mac.
#
# What a run does:
#   1. builds the app (Release by default: the configuration a reader installs)
#   2. boots its OWN simulator, scoranger-launch-ipad, made on first use, so
#      nothing here touches a gate worker or another session's device
#   3. installs the library made by make_launch_library.py into the app's
#      Documents/workspace (made once and kept under DerivedData-Launch)
#   4. launches once to let one-time migrations run, as on any device that has
#      launched before, and discards that reading
#   5. launches N more times, terminating between them, and prints each
#      reading, the median, and the breakdown of the median run
#
# "Cold" here is a NEW PROCESS with a warm file cache: `simctl terminate`
# cannot evict the Mac's page cache, and `purge` needs root. A launch after a
# reboot, or after iOS has evicted the app's files, reads them from flash too.
#
# Usage:
#   scripts/measure_launch.sh                 # 10 runs, Release
#   scripts/measure_launch.sh -n 20
#   scripts/measure_launch.sh -c Debug
#   scripts/measure_launch.sh --no-build      # reuse the last build
#   scripts/measure_launch.sh --budget 300    # exit 1 if the median is over
set -euo pipefail
cd "$(dirname "$0")/.."

RUNS=10
CONFIG=Release
BUILD=1
BUDGET=""
DEVICE_NAME=scoranger-launch-ipad
DEVICE_TYPE="iPad Pro 11-inch (M5)"
RUNTIME=com.apple.CoreSimulator.SimRuntime.iOS-26-5
BUNDLE=com.irllabs.scoranger
DD=DerivedData-Launch
LIBRARY="$DD/launch-library"
while (( $# )); do
  case "$1" in
    -n)          RUNS="$2"; shift 2 ;;
    -c)          CONFIG="$2"; shift 2 ;;
    --no-build)  BUILD=""; shift ;;
    --budget)    BUDGET="$2"; shift 2 ;;
    --device)    DEVICE_NAME="$2"; shift 2 ;;
    *)           echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

UDID=$(xcrun simctl list devices -j | /usr/bin/python3 -c "
import json, sys
for runtime, devices in json.load(sys.stdin)['devices'].items():
    for d in devices:
        if d['name'] == '$DEVICE_NAME' and d['isAvailable']:
            print(d['udid']); sys.exit()
")
if [[ -z "$UDID" ]]; then
  UDID=$(xcrun simctl create "$DEVICE_NAME" "$DEVICE_TYPE" "$RUNTIME")
  echo "==> made $DEVICE_NAME ($UDID)"
fi

if [[ -n "$BUILD" ]]; then
  echo "==> building $CONFIG"
  xcodebuild build -project Scoranger.xcodeproj -scheme Scoranger \
    -configuration "$CONFIG" -destination "platform=iOS Simulator,id=$UDID" \
    -derivedDataPath "$DD" -quiet
fi
APP="$DD/Build/Products/$CONFIG-iphonesimulator/Scoranger.app"
[[ -d "$APP" ]] || { echo "no build at $APP" >&2; exit 1; }

if [[ ! -f "$LIBRARY/manifest.json" ]]; then
  echo "==> making the launch library"
  rm -rf "$LIBRARY"
  ../engine/.venv/bin/python scripts/make_launch_library.py "$LIBRARY"
fi

xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
xcrun simctl uninstall "$UDID" "$BUNDLE" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"
DATA=$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)
mkdir -p "$DATA/Documents"
cp -R "$LIBRARY" "$DATA/Documents/workspace"
READING="$DATA/Library/Caches/launch-timing.json"
# Kept, one folder per run of this script, for comparing steps afterwards.
OUT="$DD/readings/$(date +%Y%m%d-%H%M%S)-$CONFIG"
mkdir -p "$OUT"

launch_once() {   # -> the reading's path, or nothing on a timeout
  local dest="$1"
  rm -f "$READING"
  xcrun simctl launch "$UDID" "$BUNDLE" -launchTiming >/dev/null
  for _ in $(seq 1 600); do
    [[ -s "$READING" ]] && break
    /bin/sleep 0.1
  done
  # The reading is written again when the engine's own library arrives.
  for _ in $(seq 1 300); do
    grep -q '"engineMs"' "$READING" 2>/dev/null && break
    /bin/sleep 0.1
  done
  if [[ -s "$READING" ]]; then cp "$READING" "$dest"; fi
  # Let the launch's own engine work finish before the kill, so the next
  # launch does not inherit a half-done pass.
  /bin/sleep 2
  xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
  /bin/sleep 1
}

echo "==> warm-up launch (one-time migrations; not counted)"
launch_once "$OUT/warmup.json"
[[ -s "$OUT/warmup.json" ]] || { echo "the library never appeared" >&2; exit 1; }

echo "==> $RUNS launches"
for i in $(seq 1 "$RUNS"); do
  launch_once "$OUT/run-$i.json"
  if [[ -s "$OUT/run-$i.json" ]]; then
    /usr/bin/python3 -c "import json,sys; print(f'  run $i: {json.load(open(sys.argv[1]))[\"totalMs\"]:.0f} ms')" "$OUT/run-$i.json"
  else
    echo "  run $i: no reading (timed out)"
  fi
done

echo "==> readings kept in $OUT"
/usr/bin/python3 - "$OUT" "$BUDGET" <<'PY'
import json, statistics, sys
from pathlib import Path
out, budget = Path(sys.argv[1]), sys.argv[2]
runs = [json.loads(p.read_text()) for p in sorted(out.glob("run-*.json"))]
if not runs:
    print("no readings"); sys.exit(1)
totals = sorted(r["totalMs"] for r in runs)
median = statistics.median(totals)
print(f"\nmedian {median:.0f} ms   min {totals[0]:.0f}   max {totals[-1]:.0f}   "
      f"({len(runs)} runs, {runs[0]['rows']} rows)")
engines = sorted(r["engineMs"] for r in runs if r.get("engineMs") is not None)
if engines:
    print(f"engine's own library: median {statistics.median(engines):.0f} ms   "
          f"min {engines[0]:.0f}   max {engines[-1]:.0f}   ({len(engines)} runs)")
nearest = min(runs, key=lambda r: abs(r["totalMs"] - median))
print("\nthe run nearest the median, ms since process start:")
for s in sorted(nearest["spans"], key=lambda s: s["start"]):
    length = s["end"] - s["start"]
    print(f"  {s['start']:7.1f}  {'+%.1f' % length if length else '':>8}  {s['name']}")
if budget and median > float(budget):
    print(f"\nOVER BUDGET: median {median:.0f} ms > {budget} ms"); sys.exit(1)
PY
