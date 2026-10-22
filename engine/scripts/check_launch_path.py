"""The engine's part of a launch: the library answers before music21 loads,
and the bytecode the app ships is bytecode the interpreter will use.

Ali, 2026-10-21: "There is a slight delay when I open the app before I can
see my pieces." Measured on the simulator (ios/scripts/measure_launch.sh), the
library waited 3.8 s for the engine, and two engine-side causes were found:

1. `configure` imported music21 -- 2.1 s of it, most of the wait -- although
   listing the library needs only the database. The bridge now answers
   `configure`, `sweep`, `tidy-pieces` and `manifest` from `workspace` alone
   and imports music21 at the first op that needs it. A module-level
   `import music21` added anywhere on that path would put the 2 s back with
   every test still green, so this check asserts the import has not happened.

2. Every .pyc the app shipped was stale. They were compiled in timestamp mode,
   Xcode's copy into the bundle stamps each .py with the build time, and so
   the interpreter compiled music21 from source on every launch (and could
   not cache it: `write_bytecode` is off). vendor_engine.sh now compiles in
   checked-hash mode, which a copy does not invalidate. This check fails if
   any shipped .pyc is in timestamp mode again, or if any .py has none.

The app's half -- the library drawn from manifest.json before the engine
answers -- is measured by ios/scripts/measure_launch.sh and unit-tested in
LibrarySnapshotTests.

Run: engine/.venv/bin/python engine/scripts/check_launch_path.py
"""

import json
import struct
import subprocess
import sys
import tempfile
import textwrap
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "ios" / "PythonApp" / "app"
APP_PACKAGES = ROOT / "ios" / "PythonApp" / "app_packages"

FAILURES: list[str] = []


def check(condition: bool, message: str) -> None:
    if condition:
        print(f"  ok   {message}")
    else:
        print(f"  FAIL {message}")
        FAILURES.append(message)


# Driven on the device's own sys.path, as check_bridge_coverage drives it.
CHILD = r'''
import json, os, sys
sys.path = [p for p in sys.path
            if p and "site-packages" not in p and "dist-packages" not in p]
sys.path += [APP, PACKAGES]
os.environ["SCORANGER_WORKSPACE"] = WORKSPACE

import bridge

def call(op, **args):
    return json.loads(bridge.handle(json.dumps({"op": op, "args": args})))

out = {"configure": call("configure", workspace=WORKSPACE)}
out["light"] = {op: call(op).get("ok") for op in ("sweep", "tidy-pieces", "manifest")}
out["music21_after_light"] = "music21" in sys.modules
out["manifest_file"] = os.path.exists(os.path.join(WORKSPACE, "manifest.json"))
heavy = call("number-bars-from-one")
out["heavy_ok"] = heavy.get("ok")
out["heavy_error"] = heavy.get("error")
out["music21_after_heavy"] = "music21" in sys.modules
print("RESULT" + json.dumps(out))
'''


def run_child(workspace: Path) -> dict:
    header = "\n".join(f"{k} = {v!r}" for k, v in {
        "APP": str(APP), "PACKAGES": str(APP_PACKAGES), "WORKSPACE": str(workspace)}.items())
    proc = subprocess.run([sys.executable, "-I", "-c", header + "\n" + textwrap.dedent(CHILD)],
                          capture_output=True, text=True)
    line = next((l for l in proc.stdout.splitlines() if l.startswith("RESULT")), None)
    if line is None:
        raise AssertionError("the app's bridge never answered: "
                             + (proc.stderr or proc.stdout).strip()[-800:])
    return json.loads(line[len("RESULT"):])


def pyc_mode(path: Path) -> str:
    """timestamp, unchecked-hash or checked-hash, from the .pyc header (PEP 552)."""
    flags = struct.unpack("<I", path.read_bytes()[4:8])[0]
    if not flags & 1:
        return "timestamp"
    return "checked-hash" if flags & 2 else "unchecked-hash"


def main() -> int:
    if not APP_PACKAGES.exists():
        print(f"  FAIL {APP_PACKAGES} is missing -- run ios/scripts/vendor_engine.sh")
        return 1

    print("the library answers before music21 is imported")
    answer = run_child(Path(tempfile.mkdtemp()) / "workspace")
    configured = answer["configure"]
    check(bool(configured.get("ok")), f"configure answered: {configured.get('error') or 'ok'}")
    check(bool(configured.get("music21")),
          f"configure still reports music21's version: {configured.get('music21')}")
    for op, ok in answer["light"].items():
        check(bool(ok), f"'{op}' answered")
    check(not answer["music21_after_light"],
          "configure, sweep, tidy-pieces and manifest left music21 unimported")
    check(answer["manifest_file"], "manifest.json was written for the app to read at launch")
    check(bool(answer["heavy_ok"]),
          f"an op that needs music21 imports it and answers: {answer['heavy_error'] or 'ok'}")
    check(answer["music21_after_heavy"], "music21 is loaded once such an op has run")

    print("\nevery .py the app ships has bytecode a copy cannot make stale")
    sources = [p for root in (APP, APP_PACKAGES) for p in root.rglob("*.py")]
    missing, modes = [], {}
    for py in sources:
        pyc = py.parent / "__pycache__" / f"{py.stem}.cpython-314.pyc"
        if not pyc.exists():
            missing.append(py.relative_to(ROOT))
            continue
        modes.setdefault(pyc_mode(pyc), []).append(py.relative_to(ROOT))
    check(not missing, f"{len(sources)} sources, each with a .pyc"
          + (f"; missing: {[str(m) for m in missing[:5]]}" if missing else ""))
    stale_prone = modes.get("timestamp", [])
    check(not stale_prone,
          f"all in checked-hash mode ({len(modes.get('checked-hash', []))})"
          + (f"; timestamp mode, which the bundle copy invalidates: "
             f"{[str(m) for m in stale_prone[:5]]}" if stale_prone else ""))
    unchecked = modes.get("unchecked-hash", [])
    check(not unchecked,
          "none unchecked, which would run an edited source's OLD bytecode"
          + (f": {[str(m) for m in unchecked[:5]]}" if unchecked else ""))

    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILED")
        for f in FAILURES:
            print(f"  - {f}")
        return 1
    print("OK: the engine's start-up stays off the library's launch path")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
