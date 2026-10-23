#!/usr/bin/env bash
# How long a score takes to open: from the reader asking for an arrangement
# to its first page on the glass, on a simulator, for each score of a corpus.
#
# The budget is about 200 ms (Ali, 2026-10-22: "Espresso" takes more than a
# second). The numbers are `OpenTiming`'s, in ms since the open was requested:
#   first page  the frame that commits the first page's pixels
#   geometry    the hit-test model published (a lasso can select)
#   all pages   the first published document holding every page
# plus the PerfMetrics stages that fell inside the open. The app writes them
# to Library/Caches under -openTiming <slug>; this collects them.
#
# NOT in the gate, for the reason measure_launch.sh gives: a wall-clock number
# from a loaded host measures the host. This Mac is shared, so every launch
# records `uptime`, and --ab exists so that load lands on both builds alike.
#
# What a run does:
#   1. builds the app (Release: what a reader installs), or takes --app
#   2. boots its OWN simulator, scoranger-open-ipad, made on first use, so
#      nothing here touches a gate worker or another session's device
#   3. makes the library from the corpus (make_open_library.py; remade when
#      the corpus or that script changes) under DerivedData-Open. It holds a
#      decoy that the app engraves by itself at launch -- see
#      make_open_library.py and RootView.openForTiming
#   4. for each score, N launches, each a new process, so the in-memory
#      engraving cache is empty. Before EVERY launch the app is installed
#      again over itself (so --ab can swap builds without a cost one side
#      alone pays), the library is copied in fresh, and whatever the app
#      wrote to Library/Caches and tmp is removed (the system's Metal shader
#      cache is kept): every open is the first open of that version.
#      `--keep-caches` keeps Library/Caches, for measuring a build with a
#      disk cache on a REPEAT open; it must be measured both ways.
#      The app waits for its own library and a second with no render in
#      flight, then opens the score the way a row tap does.
#   5. prints per score the median first page, geometry and all pages, and
#      the stage breakdown of the run nearest the median first page
#
# "Cold" is a new process with a warm Mac file cache, as in measure_launch.sh,
# and a Verovio toolkit already warmed by the decoy's engrave, as in an app
# that has been open a while. The open's own engine calls (version-file,
# playback) and the library poll every 2 s run as they do for a reader.
#
# Usage:
#   scripts/measure_open.sh                         # 7 runs a score, Release
#   scripts/measure_open.sh -n 11 --scores espresso-sabrina-carpenter,drowsy-maggie-9
#   scripts/measure_open.sh --app path/Scoranger.app
#   scripts/measure_open.sh --ab build/open-bench/baseline-app/Scoranger.app
#   scripts/measure_open.sh --fidelity build/open-bench/candidate-fidelity
#   scripts/measure_open.sh --no-build              # reuse the last build
# Score names are the corpus file stems. A run's readings are kept under
# DerivedData-Open/readings/<stamp>/.
set -euo pipefail
cd "$(dirname "$0")/.."
IOS="$(pwd)"

RUNS=7
CONFIG=Release
BUILD=1
APP=""
BASELINE=""
FIDELITY=""
SCORES=""
KEEP_CACHES=""
DEVICE_NAME=scoranger-open-ipad
DEVICE_TYPE="iPad Pro 11-inch (M5)"
RUNTIME=com.apple.CoreSimulator.SimRuntime.iOS-26-5
BUNDLE=com.irllabs.scoranger
DD=DerivedData-Open
CORPUS="$IOS/build/open-bench/corpus"
LIBRARY="$DD/open-library"
# the app waits up to 120 s for a quiet moment, then opens
TIMEOUT_S=200
while (( $# )); do
  case "$1" in
    -n)              RUNS="$2"; shift 2 ;;
    -c)              CONFIG="$2"; shift 2 ;;
    --no-build)      BUILD=""; shift ;;
    --app)           APP="$2"; BUILD=""; shift 2 ;;
    --ab)            BASELINE="$2"; shift 2 ;;
    --fidelity)      FIDELITY="$2"; shift 2 ;;
    --scores)        SCORES="$2"; shift 2 ;;
    --keep-caches)   KEEP_CACHES=1; shift ;;
    --corpus)        CORPUS="$2"; shift 2 ;;
    --device)        DEVICE_NAME="$2"; shift 2 ;;
    *)               echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$BASELINE" && -n "$FIDELITY" ]] && { echo "--ab and --fidelity do not mix" >&2; exit 2; }

echo "==> host: $(uptime)"

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
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null

if [[ -n "$BUILD" ]]; then
  echo "==> building $CONFIG ($(git rev-parse --short HEAD)$(git diff --quiet HEAD -- . || echo ' + uncommitted changes'))"
  xcodebuild build -project Scoranger.xcodeproj -scheme Scoranger \
    -configuration "$CONFIG" -destination "platform=iOS Simulator,id=$UDID" \
    -derivedDataPath "$DD" -quiet
fi
[[ -n "$APP" ]] || APP="$DD/Build/Products/$CONFIG-iphonesimulator/Scoranger.app"
[[ -d "$APP" ]] || { echo "no build at $APP" >&2; exit 1; }
APP="$(cd "$APP" && pwd)"
if [[ -n "$BASELINE" ]]; then
  [[ -d "$BASELINE" ]] || { echo "no baseline at $BASELINE" >&2; exit 1; }
  BASELINE="$(cd "$BASELINE" && pwd)"
fi

# The library, remade whenever the corpus or the script that makes it is not
# the one it was made from.
DIGEST=$(/usr/bin/python3 - "$CORPUS" "$IOS/scripts/make_open_library.py" <<'PY'
import hashlib, sys
from pathlib import Path
h = hashlib.sha256()
for f in sorted(Path(sys.argv[1]).glob("*.musicxml")):
    h.update(f.name.encode()); h.update(f.read_bytes())
h.update(Path(sys.argv[2]).read_bytes())
print(h.hexdigest())
PY
)
if [[ "$(cat "$LIBRARY.made-from" 2>/dev/null || true)" != "$DIGEST" ]]; then
  echo "==> making the library from $CORPUS"
  rm -rf "$LIBRARY" "$LIBRARY.made-from"
  ../engine/.venv/bin/python scripts/make_open_library.py "$CORPUS" "$LIBRARY"
  echo "$DIGEST" > "$LIBRARY.made-from"
fi

# corpus stems to open, and the slug each one has in the library
ALL_STEMS=$(/usr/bin/python3 -c "import json,sys; print(' '.join(sorted(json.load(open(sys.argv[1]))['slugs'])))" "$LIBRARY/open-bench.json")
STEMS="${SCORES//,/ }"
[[ -n "$STEMS" ]] || STEMS="$ALL_STEMS"
slug_of() {
  /usr/bin/python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['slugs'][sys.argv[2]])" \
    "$LIBRARY/open-bench.json" "$1" 2>/dev/null \
    || { echo "no score '$1' in the corpus (have: $ALL_STEMS)" >&2; exit 2; }
}
for stem in $STEMS; do slug_of "$stem" >/dev/null; done

xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
xcrun simctl uninstall "$UDID" "$BUNDLE" 2>/dev/null || true

STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$DD/readings/$STAMP"
mkdir -p "$OUT"
uptime > "$OUT/uptime-start.txt"
{
  echo "app: $APP"
  [[ -n "$BASELINE" ]] && echo "baseline: $BASELINE"
  echo "device: $DEVICE_NAME $UDID"
  echo "runs: $RUNS  keep-caches: ${KEEP_CACHES:-no}"
} > "$OUT/setup.txt"

# launch_once <app> <slug> <dest-dir> [-openFidelity]: one fresh process
# opening one score; leaves reading.json (and the dump) in dest-dir.
launch_once() {
  local app="$1" slug="$2" dest="$3"; shift 3
  mkdir -p "$dest"
  xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
  xcrun simctl install "$UDID" "$app"
  # An install moves the app to a NEW data container (the contents go with
  # it), so the path is asked for again every time.
  local data
  data=$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)
  rm -rf "$data/Documents/workspace" "$data/Documents/playback"
  mkdir -p "$data/Documents" "$data/Library/Caches"
  cp -R "$LIBRARY" "$data/Documents/workspace"
  rm -f "$data/Documents/workspace/open-bench.json"
  if [[ -z "$KEEP_CACHES" ]]; then
    find "$data/Library/Caches" -mindepth 1 -maxdepth 1 ! -name "$BUNDLE" -exec rm -rf {} +
    if [[ -d "$data/Library/Caches/$BUNDLE" ]]; then
      find "$data/Library/Caches/$BUNDLE" -mindepth 1 -maxdepth 1 ! -name 'com.apple.metal*' -exec rm -rf {} +
    fi
    find "$data/tmp" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
  fi
  local reading="$data/Library/Caches/open-timing.json"
  local dump="$data/Library/Caches/open-fidelity"
  rm -rf "$reading" "$dump"
  uptime > "$dest/uptime.txt"
  xcrun simctl launch "$UDID" "$BUNDLE" -openTiming "$slug" "$@" >/dev/null
  local ok=""
  for _ in $(seq 1 $((TIMEOUT_S * 10))); do
    if grep -q '"complete" : true' "$reading" 2>/dev/null; then
      if [[ " $* " != *" -openFidelity "* || -f "$dump/done" ]]; then ok=1; break; fi
    fi
    /bin/sleep 0.1
  done
  if [[ -n "$ok" ]]; then
    cp "$reading" "$dest/reading.json"
    if [[ -d "$dump" ]]; then cp -R "$dump/." "$dest/"; fi
  else
    echo "    no reading in ${TIMEOUT_S}s" >&2
  fi
  # let the open's own background work (playback, polling) finish before the
  # kill, so the next launch does not inherit a half-written workspace
  /bin/sleep 1
  xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
  /bin/sleep 0.5
}

one_line() {  # reading.json -> "first X  geometry Y  all Z  (N pages)"
  /usr/bin/python3 - "$1" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
f = lambda k: "-" if r.get(k) is None else f"{r[k]:.0f}"
err = f"  ERROR {r['error']}" if r.get("error") else ""
hit = "  CACHE HIT (selected before the open)" if r.get("selectedBefore") == r["slug"] else ""
print(f"first page {f('firstPageMs'):>6} ms  geometry {f('geometryMs'):>6}  "
      f"all pages {f('allPagesMs'):>6}  ({r.get('pages')} pages){err}{hit}")
PY
}

first_stem=${STEMS%% *}
echo "==> warm-up launch (one-time migrations; not counted)"
launch_once "$APP" "$(slug_of "$first_stem")" "$OUT/warmup"
[[ -s "$OUT/warmup/reading.json" ]] || { echo "the warm-up open never finished" >&2; exit 1; }

if [[ -n "$FIDELITY" ]]; then
  mkdir -p "$FIDELITY"
  for stem in $STEMS; do
    echo "==> fidelity dump: $stem"
    rm -rf "${FIDELITY:?}/$stem"
    launch_once "$APP" "$(slug_of "$stem")" "$FIDELITY/$stem" -openFidelity
    [[ -f "$FIDELITY/$stem/done" ]] || { echo "no dump for $stem" >&2; exit 1; }
    echo "    $(one_line "$FIDELITY/$stem/reading.json"), $(ls "$FIDELITY/$stem/svg" | wc -l | tr -d ' ') SVG pages"
  done
  { echo "app: $APP"; uptime; } > "$FIDELITY/made-by.txt"
  echo "==> dumps in $FIDELITY ($(uptime))"
  exit 0
fi

LABELS="candidate"
[[ -n "$BASELINE" ]] && LABELS="baseline candidate"
app_for() { [[ "$1" == baseline ]] && echo "$BASELINE" || echo "$APP"; }

for stem in $STEMS; do
  slug=$(slug_of "$stem")
  echo "==> $stem: $RUNS runs"
  for i in $(seq 1 "$RUNS"); do
    # which build goes first alternates, so a host growing busier through a
    # pair does not always land on the same side
    order="$LABELS"
    if [[ -n "$BASELINE" && $((i % 2)) -eq 0 ]]; then order="candidate baseline"; fi
    for label in $order; do
      dest="$OUT/$label/$stem/run-$i"
      launch_once "$(app_for "$label")" "$slug" "$dest"
      if [[ -s "$dest/reading.json" ]]; then
        echo "  run $i $(printf '%-9s' "$label") $(one_line "$dest/reading.json")   [load $(awk -F'load averages: ' '{print $2}' "$dest/uptime.txt")]"
      else
        echo "  run $i $label: no reading"
      fi
    done
  done
done
uptime > "$OUT/uptime-end.txt"

echo "==> readings kept in $OUT"
/usr/bin/python3 - "$OUT" "$LABELS" "$STEMS" <<'PY'
import json, statistics, sys
from pathlib import Path
out, labels, stems = Path(sys.argv[1]), sys.argv[2].split(), sys.argv[3].split()

def runs(label, stem):
    got = []
    for p in sorted((out / label / stem).glob("run-*/reading.json")):
        r = json.loads(p.read_text())
        r["_load"] = (p.parent / "uptime.txt").read_text().split("load averages:")[-1].strip()
        # an open of the arrangement the launch had already engraved is a
        # cache hit, not an open; it is reported and left out
        if r.get("selectedBefore") == r["slug"] or r.get("error"):
            print(f"  excluded: {p.parent.relative_to(out)} "
                  f"({'error ' + r['error'] if r.get('error') else 'cache hit'})")
            continue
        got.append(r)
    return got

def med(rs, key):
    xs = [r[key] for r in rs if r.get(key) is not None]
    return statistics.median(xs) if xs else None

def ms(x):
    return "     -" if x is None else f"{x:6.0f}"

cols = {(l, s): runs(l, s) for l in labels for s in stems}
print(f"\nhost at start: {(out / 'uptime-start.txt').read_text().strip()}")
print(f"host at end:   {(out / 'uptime-end.txt').read_text().strip()}")
print("\nmedians, ms from the open being requested"
      + ("  (baseline | candidate)" if len(labels) > 1 else ""))
print(f"{'score':34} {'first page':>15} {'geometry':>15} {'all pages':>15}  pages  runs")
for stem in stems:
    def cell(key):
        return " |".join(ms(med(cols[(l, stem)], key)) for l in labels)
    pages = "/".join(",".join(str(p) for p in sorted({r.get("pages") for r in cols[(l, stem)]}))
                     for l in labels)
    n = "/".join(str(len(cols[(l, stem)])) for l in labels)
    print(f"{stem:34} {cell('firstPageMs'):>15} {cell('geometryMs'):>15} "
          f"{cell('allPagesMs'):>15}  {pages:>5}  {n}")

for label in labels:
    for stem in stems:
        rs = cols[(label, stem)]
        if not rs:
            continue
        m = med(rs, "firstPageMs")
        firsts = sorted(r["firstPageMs"] for r in rs if r.get("firstPageMs") is not None)
        nearest = min(rs, key=lambda r: abs((r.get("firstPageMs") or 1e9) - (m or 0)))
        print(f"\n[{label}] {stem}: first page median {ms(m).strip()} ms, "
              f"min {firsts[0]:.0f}, max {firsts[-1]:.0f}; the run nearest the median "
              f"(load {nearest['_load']}), stages inside the open:")
        for s in sorted(nearest["stages"], key=lambda s: -s["totalMs"]):
            print(f"    {s['totalMs']:8.1f} ms  x{s['count']:<3} {s['name']}")
        print("  timeline (ms since the request; per-page spans summed above):")
        for s in nearest["spans"]:
            if s["name"] in ("engrave: SVG -> PDF (swiftdraw)", "engrave: SVG (verovio)"):
                continue
            print(f"    {s['start']:8.1f} +{s['end'] - s['start']:7.1f}  {s['name']}")
        for key, name in (("geometryMs", "geometry published"),
                          ("allPagesMs", "every page published"),
                          ("firstPageMs", "first page on glass")):
            if nearest.get(key) is not None:
                print(f"    {nearest[key]:8.1f}           {name}")
PY
