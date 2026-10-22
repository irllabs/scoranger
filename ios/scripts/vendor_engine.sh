#!/bin/bash
# Vendors the pure-Python engine into the iOS app tree.
#   PythonApp/app/           bridge.py + scoranger_engine (copied from ../engine)
#   PythonApp/app_packages/  music21 + pure-Python deps
#   Licences/python/         each of those deps' licence text, by distribution
# Re-run after changing engine code. Requires python3.14 on PATH (bytecode
# magic must match the embedded 3.14 runtime).
set -euo pipefail
cd "$(dirname "$0")/.."

PY=../engine/.venv/bin/python
APP=PythonApp/app
PKGS=PythonApp/app_packages
LICENCES=Licences/python

rm -rf "$PKGS" "$APP/scoranger_engine"
mkdir -p "$APP" "$PKGS"

# Engine sources: the CLOSURE of what bridge.py actually reaches, worked out
# from the imports rather than listed here.
#
# It was a hand-kept list, and it went stale the moment stage 0 added ids.py:
# workspace.py gained `from . import ids` at module scope, the list did not,
# and the app shipped an engine that could not import at all. Every UI test
# failed with "the seeded library never appeared" -- correct, and a long way
# from the cause. A list of modules maintained by hand next to an import graph
# maintained by the compiler will diverge again.
#
# server/render/chat/cli/sync stay out because nothing in the closure reaches
# them: rendering is the Swift engraver's job on device, `scor serve` is the
# desktop viewer's API, and sync is not wired up yet.
mkdir -p "$APP/scoranger_engine"
"$PY" - "$APP/scoranger_engine" <<'CLOSURE'
import ast, shutil, sys
from pathlib import Path

dest = Path(sys.argv[1])
src = Path("../engine/scoranger_engine")

def intra(module: str) -> set[str]:
    """Package-relative imports of one module, lazy ones included."""
    found = set()
    for node in ast.walk(ast.parse((src / f"{module}.py").read_text())):
        if isinstance(node, ast.ImportFrom) and node.level == 1:
            if node.module is None:                 # from . import a, b
                found |= {alias.name for alias in node.names}
            else:                                   # from .a import b
                found.add(node.module.split(".")[0])
    return found

# what the bridge names, then everything those reach, transitively. The seeds
# are READ from bridge.py too: they were a hand-kept set, and 0.14.0's
# `from scoranger_engine import booksplit` inside a bridge branch was missing
# from it -- the host passed and the device would have raised ModuleNotFoundError.
bridge = Path("PythonApp/app/bridge.py")
seeds = {"__init__"}
for node in ast.walk(ast.parse(bridge.read_text())):
    if isinstance(node, ast.ImportFrom) and node.module == "scoranger_engine":
        seeds |= {alias.name for alias in node.names}
    elif isinstance(node, ast.ImportFrom) and (node.module or "").startswith("scoranger_engine."):
        seeds.add(node.module.split(".")[1])
    elif isinstance(node, ast.Import):
        seeds |= {a.name.split(".")[1] for a in node.names
                  if a.name.startswith("scoranger_engine.")}
closure, queue = set(), list(seeds)
while queue:
    module = queue.pop()
    if module in closure or not (src / f"{module}.py").exists():
        continue
    closure.add(module)
    queue.extend(intra(module))

for module in sorted(closure):
    shutil.copy(src / f"{module}.py", dest)
print("  engine modules: " + " ".join(sorted(closure)))
CLOSURE

# pypdf is not optional: books ARE PDFs. workspace.create_book counts a book's
# pages and extract_from_book cuts pages out of one, and both import pypdf.
# Leaving it out shipped an Import Book that failed with ModuleNotFoundError
# inside the engine, into a lastError nothing displayed -- the picker closed,
# the library switched to Books, and nothing was there. Pure Python, no wheels
# to strip. check_books.py now imports a book on the device's OWN sys.path so
# the omission cannot come back.
"$PY" -m pip install --quiet --no-deps --target "$PKGS" \
  music21 chardet joblib jsonpickle more-itertools webcolors \
  requests certifi urllib3 idna charset_normalizer pypdf

# strip what the app never uses. music21/__init__ imports both `corpus` and
# `test`, so keep all .py code and delete only the bundled score data.
find "$PKGS/music21/corpus" -type f ! -name "*.py" -delete
find "$PKGS/music21/corpus" -type d -empty -delete

# Keep each package's licence text before its .dist-info goes. BSD-3, MIT,
# Apache-2.0 and MPL-2.0 all require the notice to travel with a binary, and
# deleting the whole .dist-info (it is mostly RECORD and WHEEL) took the
# LICENSE with it until 0.15.0. Each lands in Licences/python/<distribution>/,
# which the credits screen reads by the same name (Pipeline.Credit.text). A
# package whose metadata carries no licence file stops the vendoring here,
# rather than shipping without one.
rm -rf "$LICENCES" && mkdir -p "$LICENCES"
for info in "$PKGS"/*.dist-info; do
  dist=$(basename "$info"); dist=${dist%%-*}
  mkdir -p "$LICENCES/$dist"
  find "$info" -type f \( -iname 'LICEN[CS]E*' -o -iname 'COPYING*' -o -iname 'NOTICE*' \) \
    -exec cp {} "$LICENCES/$dist/" \;
  if [ -z "$(ls -A "$LICENCES/$dist")" ]; then
    echo "vendor_engine: $dist ships no licence file in its metadata" >&2
    exit 1
  fi
done
echo "  licences: $(ls "$LICENCES" | tr '\n' ' ')"
rm -rf "$PKGS"/*.dist-info "$PKGS/bin"

# drop compiled speedups (mypyc darwin .so in chardet/charset_normalizer wheels)
# — wrong platform for iOS and App Store validation rejects them; the pure
# Python fallbacks remain importable.
find "$PKGS" -name "*.so" -delete
find "$PKGS" -name "*.fwork" -delete

# precompile (write_bytecode=0 at runtime, so ship .pyc)
#
# CHECKED-HASH, not the default timestamp mode. A timestamp .pyc is valid only
# while its source keeps the mtime it was compiled against, and Xcode's copy of
# these folders into the bundle stamps every .py with the BUILD time -- so
# every .pyc the app shipped was stale, and the embedded interpreter compiled
# the engine and music21 from source on every launch (and could not cache the
# result, write_bytecode being off). A checked-hash .pyc records a hash of its
# source instead, which a copy does not change, and an edited source still
# invalidates it. Found by LaunchTiming, 2026-10-21.
"$PY" -m compileall -q --invalidation-mode checked-hash "$APP" "$PKGS"

echo "vendored: $(du -sh $PKGS | cut -f1) packages, $(du -sh $APP | cut -f1) app"
