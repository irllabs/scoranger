# Scoranger for iPad

Native SwiftUI app with the **entire Scoranger engine embedded on-device** —
no laptop, no server:

- **Embedded engine**: CPython 3.14 + music21 run inside the app
  (`PythonApp/app/bridge.py` behind a C shim + Swift actor). Every arrangement
  op, harmony analysis, and the versioned workspace (SQLite, in the app's
  Documents) work offline.
- **On-device engraving**: Verovio (compiled in via SPM) renders MusicXML to
  SVG; a preprocessing pass adapts it for SwiftDraw, which produces the PDF
  pages.
- **Native chat agent**: a Swift tool loop over OpenRouter mirroring the
  engine's 21 arrangement tools. Add your OpenRouter API key in Settings
  (stored in the Keychain) and pick a model in the chat header.
- **Apple Pencil annotations** (pencil draws, fingers scroll; per page, per
  version), Files-app import (+), semitone transposition, version history.

A Settings toggle can still point the app at a Mac running
`scor serve --host 0.0.0.0` (remote mode, the original thin-client setup).

## Build & run

Two vendored pieces are gitignored and fetched by script; the Xcode project is
generated (not checked in):

```sh
brew install xcodegen              # once
cd ios
scripts/fetch_python.sh            # BeeWare Python.xcframework + verovio clone into Vendor/
scripts/vendor_engine.sh           # music21 + engine sources into PythonApp/
xcodegen generate
open Scoranger.xcodeproj
```

Re-run `vendor_engine.sh` whenever engine Python changes. In Xcode: select the
**Scoranger** target → *Signing & Capabilities* → pick your team, choose your
iPad, Run.

## TestFlight

Deploys are headless — no Xcode Organizer, no signed-in Apple account:

```sh
scripts/bootstrap_signing.sh      # once, ever: certificate + keychain + profile
scripts/deploy_testflight.sh      # every release: bump, archive, sign, upload
scripts/deploy_testflight.sh --preflight   # check readiness, change nothing
```

See `DEPLOY.md` for how signing is set up and what to do when Apple needs a
human.

## Notes

- Annotations are stored on-device (Documents/annotations) keyed by
  score/version/page.
- The on-device workspace lives in the app's Documents/workspace (visible in
  the Files app); every mutation is an immutable version, same as the desktop
  engine.
- OMR (PDF → MusicXML) stays off-device — run Audiveris on a Mac and import
  the resulting `.mxl` via the Files picker.

## Launch time

```
scripts/measure_launch.sh              # 10 cold launches, Release, median
scripts/measure_launch.sh -n 20 --budget 300
```

Process start to the first frame with library rows (`LaunchTiming`), on its
own simulator, `scoranger-launch-ipad`, with a library the size of a working
musician's (`scripts/make_launch_library.py`: 48 pieces, 141 arrangements, 495
versions). It also prints when the engine's own library arrived and the
breakdown of the median run. Not in the gate: a wall-clock budget on a loaded
host measures the host. On a device the same reading is in Settings >
Diagnostics, from the launch after the switch is turned on, and in the unified
log under `SCORANGER-LAUNCH`.

## The gate

```
scripts/gate.sh              # 4 simulators, ~13 minutes
scripts/gate.sh -j 6         # more workers
scripts/gate.sh --serial     # one simulator, the old behaviour
```

It builds once, enumerates the test METHODS, deals them across simulators it
owns by name (`scoranger-gate-1`…), and runs one `xcodebuild` per simulator.
Two runs against the SAME simulator collide and execute zero tests while
reporting success, so the run fails unless the number of tests that executed
equals the number enumerated.

The split is longest-processing-time greedy over `scripts/gate-durations.tsv`,
which the gate rewrites after every run. A test with no recorded duration is
assumed median, so a new test never unbalances the run.

Sharding is done here rather than with `-parallel-testing-enabled` because
xcodebuild's own parallel testing distributes test CLASSES, and most of this
suite is in one class.
