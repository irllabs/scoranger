#!/usr/bin/env python3
"""Measure numbers, from chat to the page (0.17.0).

Ali, on Molly Ban: "I want measure # control". The chat answered that there
was no setting, which was true: Verovio numbers the first bar of every line
and nothing in the notation could ask for anything else.

What has to hold, counted off the SVG Verovio actually draws:

  1. every=1 numbers every bar; every=3 the bars whose number divides by 3
  2. none numbers nothing -- Verovio has no option for that, so it rides in
     the MEI as mnum.visible="false"
  3. the default numbers the first bar of each line but the first
  4. the setting is in the notation: it survives a write and a read back
  5. one score's numbering is not the next score's on a shared toolkit
     (setOptions merges -- the trap spacing and pagination both met)
  6. the op says exactly one thing, and refuses two at once
  7. the Swift renderer reads the same field the same way

Run: engine/.venv/bin/python engine/scripts/check_measure_numbers.py
"""
import re
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import verovio  # noqa: E402
from music21 import converter, meter, stream  # noqa: E402
from music21 import note as m21note  # noqa: E402

from scoranger_engine import ops, render  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
SCRATCH = Path(tempfile.mkdtemp())
FAILURES: list[str] = []


def check(label, ok, detail=""):
    print(f"    {'ok  ' if ok else 'FAIL'} {label}" + (f": {detail}" if detail and not ok else ""))
    if not ok:
        FAILURES.append(f"{label}{': ' + detail if detail else ''}")


def a_score(bars: int = 16):
    score = stream.Score()
    part = stream.Part()
    for i in range(1, bars + 1):
        m = stream.Measure(number=i)
        if i == 1:
            m.append(meter.TimeSignature("4/4"))
        for pitch in ("G4", "A4", "B4", "C5"):
            m.append(m21note.Note(pitch, quarterLength=1))
        part.append(m)
    score.append(part)
    return score


def drawn(score, tag: str, tk=None) -> tuple[list[str], int]:
    """(the bar numbers drawn, the number of systems), the way render_pdf draws."""
    path = SCRATCH / f"{tag}.musicxml"
    score.write("musicxml", fp=str(path))
    notation = path.read_text(encoding="utf-8")
    numbering = render.measure_numbers_from_musicxml(notation)
    tk = tk or verovio.toolkit()
    tk.setOptions({**render.page_options(), **render.measure_number_options(numbering),
                   "breaks": render.breaks_for(notation)})
    tk.loadFile(str(path))
    if numbering[0] == "none":
        hidden = render.mei_with_measure_numbers_hidden(tk.getMEI())
        if hidden is not None:
            tk.loadData(hidden)
    numbers, systems = [], 0
    for page in range(1, tk.getPageCount() + 1):
        svg = tk.renderToSVG(page)
        systems += len(re.findall(r'class="system"', svg))
        for block in re.findall(r'<g[^>]*class="mNum[^"]*"[^>]*>(.*?)</g>', svg, re.S):
            numbers += re.findall(r">\s*(\d+)\s*<", block)
    return numbers, systems


print("the numbering a reader asks for is the numbering drawn")
s = a_score(16)
ops.measure_numbers(s, every=1)
numbers, _ = drawn(s, "every-1")
check("every bar carries its number", numbers == [str(n) for n in range(1, 17)], str(numbers))

s = a_score(16)
report = ops.measure_numbers(s, every=3)
numbers, _ = drawn(s, "every-3")
check("every third bar: 3, 6, 9, 12, 15", numbers == ["3", "6", "9", "12", "15"], str(numbers))
check("...and the report says so in words", "every 3 bars" in report["measure_numbers"],
      report["measure_numbers"])

s = a_score(16)
ops.measure_numbers(s, none=True)
numbers, _ = drawn(s, "none")
check("none draws no number at all", numbers == [], str(numbers))

s = a_score(16)
ops.paginate(s, measures_per_line=4)
numbers, systems = drawn(s, "default")
check("the default numbers each line's first bar but the first: 5, 9, 13",
      numbers == ["5", "9", "13"] and systems == 4, f"{numbers}, {systems} systems")

print("\nthe setting lives in the notation")
s = a_score(8)
ops.measure_numbers(s, every=2)
path = SCRATCH / "roundtrip.musicxml"
s.write("musicxml", fp=str(path))
back = converter.parse(str(path), forceSource=True)
check("it survives a write and a read back",
      render.measure_numbers_from_musicxml(path.read_text(encoding="utf-8")) == ("every", 2))
again = ops.measure_numbers(back, reset=True)
check("...and reset reports what it was", "every 2 bars" in again["was"], again["was"])
back.write("musicxml", fp=str(path))
check("reset leaves no field at all",
      render.MEASURE_NUMBERS_FIELD not in path.read_text(encoding="utf-8"))

print("\none score's numbering is not the next score's")
shared = verovio.toolkit()
first = a_score(16)
ops.measure_numbers(first, every=1)
drawn(first, "shared-1", shared)
second = a_score(16)
ops.paginate(second, measures_per_line=4)
numbers, _ = drawn(second, "shared-2", shared)
check("a default score drawn after an every-bar one is numbered by default",
      numbers == ["5", "9", "13"], str(numbers))
check("the default interval is named in page_options, so it is set every time",
      render.page_options().get("mnumInterval") == 0)

print("\nthe op says exactly one thing")
for args, what in (({"every": 2, "none": True}, "every and none"),
                   ({}, "nothing"), ({"every": 0}, "every 0"), ({"every": 65}, "every 65")):
    try:
        ops.measure_numbers(a_score(4), **args)
        check(f"{what} is refused", False)
    except ValueError as exc:
        check(f"{what} is refused by name", bool(str(exc)), str(exc))

print("\nthe iPad reads the same field the same way")
swift = (ROOT / "ios/Scoranger/ScoreModel/MeasureNumbers.swift").read_text()
check("MeasureNumbers.swift names the same field",
      f'"{render.MEASURE_NUMBERS_FIELD}"' in swift)
lo, hi = render.MEASURE_NUMBERS_EVERY_RANGE
check(f"...and the same range, {lo}...{hi}", f"{lo}...{hi}" in swift)
check("EngravingOptions names mnumInterval in every option set",
      '"mnumInterval"' in (ROOT / "ios/Scoranger/ScoreModel/EngravingOptions.swift").read_text())

import shutil  # noqa: E402
shutil.rmtree(SCRATCH, ignore_errors=True)
if FAILURES:
    print(f"\nFAIL: {len(FAILURES)} measure-number check(s) failed")
    for line in FAILURES:
        print("   ", line)
    sys.exit(1)
print("\nOK: measure numbers are drawn where the reader asked, on both renderers")
