#!/usr/bin/env python3
"""The first full bar is bar 1, and a chord is a chord symbol (0.17.0).

Ali, on Molly Ban: "when I asked it to add chords in the beginning, somehow it
skipped the first measure ... when I say put chord measures, it should start
at the first bar." The tune came from thesession.org, and music21's ABC reader
numbers a tune with no pickup from 0 -- so the page's first bar was "bar 0" to
every op, and the chat's "bar 1" was the page's second.

And: "when I asked it to add the E minor in the second half of bar eight, that
chord annotation is both lower than the rest and it's in italics" -- the chat
wrote the chord name as a TEXT mark, because the chord tool offered it no way
to put a chord mid-bar.

What has to hold:

  1. an ABC tune with no pickup imports with its first bar numbered 1
  2. a tune WITH a pickup keeps it as 0 -- "the pickup" -- and bar 1 after it
  3. a chart written "from the first bar" lands on the first bar
  4. an arrangement already in a library numbered from 0 gets ONE new version
     numbered from 1 at launch, and the pass does nothing the second time
  5. a forced line break moves with its bar
  6. a chord name as a text mark is refused, pointing at set-chords and the
     offset; words still go in as text
  7. set-chords puts a chord in the second half of a bar, beside the one on
     the downbeat

Run: engine/.venv/bin/python engine/scripts/check_bar_numbers.py
"""
import json
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

FAILURES: list[str] = []


def check(label, ok, detail=""):
    print(f"    {'ok  ' if ok else 'FAIL'} {label}" + (f": {detail}" if detail and not ok else ""))
    if not ok:
        FAILURES.append(f"{label}{': ' + detail if detail else ''}")


ROOT = Path(tempfile.mkdtemp())
os.environ["SCORANGER_WORKSPACE"] = str(ROOT / "workspace")

from music21 import converter, harmony, stream  # noqa: E402

from scoranger_engine import ops, workspace  # noqa: E402

workspace.WORKSPACE = ROOT / "workspace"
workspace._reset_repo_for_testing()

NO_PICKUP = """X:1
T:Molly Ban
M:4/4
L:1/8
K:Edor
|:EBBA B2 AG|FDAD BDAD|EBBA B2 Bd|edBA GE E2:|
"""
WITH_PICKUP = """X:1
T:Pickup Tune
M:6/8
L:1/8
K:G
D|GAB dBG|GAB d2e|GAB dBG|AGF G2:|
"""


def abc(name: str, text: str) -> Path:
    path = ROOT / f"{name}.abc"
    path.write_text(text)
    return path


def bars(slug: str) -> list[int]:
    score = converter.parse(str(workspace.resolve_notation_path(slug)), forceSource=True)
    return [m.number for m in score.parts[0].getElementsByClass(stream.Measure)]


def import_one(path: Path, name: str) -> str:
    scores = workspace.read_notation(path)
    slug, _ = workspace.create_score(name, scores[0])
    return slug


print("the first full bar is bar 1")
molly = import_one(abc("molly", NO_PICKUP), "Molly Ban")
check("an ABC tune with no pickup imports from bar 1", bars(molly)[:3] == [1, 2, 3],
      str(bars(molly)))
pickup = import_one(abc("pickup", WITH_PICKUP), "Pickup Tune")
check("a pickup stays bar 0, with bar 1 after it", bars(pickup)[:3] == [0, 1, 2],
      str(bars(pickup)))

print("\na chart from the beginning starts at the first bar")
score = converter.parse(str(workspace.resolve_notation_path(molly)), forceSource=True)
ops.set_chord_symbols(score, "#0", [{"measure": 1, "symbol": "Em"},
                                    {"measure": 2, "symbol": "D"}])
first = score.parts[0].getElementsByClass(stream.Measure)[0]
symbols = [c.figure for c in first.getElementsByClass(harmony.ChordSymbol)]
check("measure 1 is the first bar on the page, and it carries the first chord",
      first.number == 1 and symbols == ["Em"], f"bar {first.number}: {symbols}")

print("\nset-chords puts a chord in the second half of a bar")
ops.set_chord_symbols(score, "#0", [{"measure": 4, "symbol": "D"},
                                    {"measure": 4, "symbol": "Em", "offset": 2}])
fourth = score.parts[0].getElementsByClass(stream.Measure)[3]
placed = sorted((float(c.offset), c.figure) for c in fourth.getElementsByClass(harmony.ChordSymbol))
check("bar 4 holds D on the downbeat and Em on beat 3", placed == [(0.0, "D"), (2.0, "Em")],
      str(placed))
ops.set_chord_symbols(score, "#0", [{"measure": 4, "symbol": "Bm", "offset": 2}])
placed = sorted((float(c.offset), c.figure) for c in fourth.getElementsByClass(harmony.ChordSymbol))
check("...and a second chart entry there replaces only that chord", placed == [(0.0, "D"), (2.0, "Bm")],
      str(placed))

print("\na chord name is not a text mark")
try:
    ops.add_element(score, "#0", "text", 8, value="Em", offset=2)
    check("'Em' as a text mark is refused", False)
except ValueError as exc:
    message = str(exc)
    check("'Em' as a text mark is refused, pointing at set-chords and the offset",
          "set-chords" in message and '"offset": 2.0' in message, message)
for words in ("dolce", "D.C. al Fine", "rit."):
    try:
        ops.add_element(score, "#0", "text", 3, value=words, offset=0)
        check(f"'{words}' is still a text mark", True)
    except ValueError as exc:
        check(f"'{words}' is still a text mark", False, str(exc))

print("\nan arrangement already numbered from 0 is renumbered once, as a new version")
legacy = converter.parse(str(abc("legacy", NO_PICKUP)))
before = [m.number for m in legacy.parts[0].getElementsByClass(stream.Measure)]
check("music21 numbers the raw ABC from 0 (what this all exists for)", before[0] == 0, str(before))
# Written as an old build wrote it: straight to a version, never renumbered.
slug, _ = workspace.create_score("Legacy", converter.parse(str(abc("legacy2", NO_PICKUP))))
old = converter.parse(str(abc("legacy3", NO_PICKUP)))
ops.paginate(old, measures_per_line=2, break_at=[2])
workspace.add_version(slug, old, "import", {})
check("the library holds an arrangement numbered from 0", bars(slug)[0] == 0, str(bars(slug)[:3]))
versions_before = len(workspace._repo().list_versions(slug))
report = workspace.number_bars_from_one_everywhere()
check("the launch pass renumbers it", slug in report["renumbered"], str(report))
check("...as ONE new version", len(workspace._repo().list_versions(slug)) == versions_before + 1)
check("...whose first bar is 1", bars(slug)[:3] == [1, 2, 3], str(bars(slug)[:3]))
renumbered = converter.parse(str(workspace.resolve_notation_path(slug)), forceSource=True)
check("...and a forced line break moved with its bar (2 -> 3)",
      3 in ops._read_forced(renumbered)[1], str(ops._read_forced(renumbered)))
again = workspace.number_bars_from_one_everywhere()
check("a second pass renumbers nothing", again["renumbered"] == [], str(again))
check("...and the pickup tune was left alone", pickup not in report["renumbered"])
checked = json.loads((workspace.WORKSPACE / workspace._BAR_CHECK_FILE).read_text())
check("what was checked is remembered, so a pickup tune is parsed once",
      workspace._repo().get_score(pickup)["latest"] in checked)

import shutil  # noqa: E402
shutil.rmtree(ROOT, ignore_errors=True)
if FAILURES:
    print(f"\nFAIL: {len(FAILURES)} bar-number check(s) failed")
    for line in FAILURES:
        print("   ", line)
    sys.exit(1)
print("\nOK: the first full bar is bar 1, and a chord is always a chord symbol")
