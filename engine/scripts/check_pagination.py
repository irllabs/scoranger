"""Regression check for where the LINES break, and for the Verovio option
that decides whether any of it is drawn at all.

`ops.paginate` writes MusicXML `<print new-system="yes"/>`. Whether a reader
ever sees one is a RENDERER setting, and the three modes do genuinely
different things -- measured here rather than believed:

    breaks=auto      lays the music out itself and IGNORES encoded breaks
    breaks=encoded   breaks ONLY where the notation says, and nowhere else
    breaks=smart     honours some and re-flows the rest

So a READER'S pagination needs `encoded` -- and only a reader's. The first
version asked for it unconditionally, and the 0.13.0 release gate caught what
that did: every imported file was laid out by its SOURCE edition's breaks, the
string-quartet fixture going from 8 pages to its publisher's 4. So the op marks
the score, both renderers ask for `encoded` on a marked score and `auto` on
every other, and that is asserted first -- on BOTH renderers, because render.py
and EngravingOptions.swift each carry their own copy of the answer -- and then
on the real quartet fixture.

The second is the trap in `encoded`: because it breaks only where told, ONE
break on a long piece means one short line and then everything else crushed
onto a single system. So the op always writes a COMPLETE pagination, and that
is asserted against the drawn page, not against the op's own report.

Run: engine/.venv/bin/python engine/scripts/check_pagination.py
"""

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import verovio  # noqa: E402
from music21 import layout, meter, note as m21note, stream  # noqa: E402

from scoranger_engine import ops, render  # noqa: E402

FAILURES: list[str] = []
SCRATCH = Path(__file__).resolve().parents[2] / "workspace" / ".pagination-check"


def check(label, ok, detail=""):
    print(f"    {'ok  ' if ok else 'FAIL'} {label}" + (f": {detail}" if detail and not ok else ""))
    if not ok:
        FAILURES.append(f"{label}{': ' + detail if detail else ''}")


def a_score(bars: int = 16, parts: int = 1):
    score = stream.Score()
    for _ in range(parts):
        part = stream.Part()
        for i in range(1, bars + 1):
            m = stream.Measure(number=i)
            if i == 1:
                m.append(meter.TimeSignature("4/4"))
            m.append(m21note.Note("G4", quarterLength=4))
            part.append(m)
        score.append(part)
    return score


def drawn_systems(score, tag: str, breaks: str | None = None) -> list[int]:
    """Measures per system, off the page Verovio actually draws.

    With no `breaks`, the renderer's own decision is used -- `breaks_for`, read
    off the written notation -- which is the path the export and the iPad take.
    """
    SCRATCH.mkdir(parents=True, exist_ok=True)
    path = SCRATCH / f"{tag}.musicxml"
    score.write("musicxml", fp=str(path))
    tk = verovio.toolkit()                 # fresh: Verovio's options are sticky
    options = dict(render.page_options())
    options["breaks"] = breaks or render.breaks_for(path.read_text(encoding="utf-8"))
    tk.setOptions(options)
    tk.loadFile(str(path))
    out = []
    for page in range(1, tk.getPageCount() + 1):
        svg = tk.renderToSVG(page)
        blocks = re.split(r'(?=<g[^>]*class="system")', svg)[1:]
        out += [b.count('class="measure"') for b in blocks]
    return out


# --- the renderers honour a READER'S breaks, and only a reader's -------------
print("both renderers honour the reader's breaks, and only the reader's")

MARK = '<miscellaneous-field name="scoranger-pagination">reader</miscellaneous-field>'
check("render.py lays an unmarked score out itself",
      render.page_options().get("breaks") == "auto" and render.breaks_for("") == "auto",
      str(render.page_options().get("breaks")))
check("...and a score the reader paginated where its notation says",
      render.breaks_for(MARK) == "line")
check("a source edition's breaks alone do not switch it",
      render.breaks_for('<print new-system="yes"/><print new-page="yes"/>') == "auto")

swift = (Path(__file__).resolve().parents[2]
         / "ios/Scoranger/ScoreModel/EngravingOptions.swift").read_text()
match = re.search(r'static func breaks\(continuous: Bool, readerPaginated: Bool = false\) -> String \{([^}]*)\}',
                  swift)
body = match.group(1) if match else ""
check("EngravingOptions.swift makes the same three-way choice",
      '"none"' in body and '"line"' in body and '"auto"' in body and "readerPaginated" in body,
      body.strip() or "breaks(continuous:readerPaginated:) not found")
check("...keyed on the same field name",
      f'static let paginationField = "{render.PAGINATION_FIELD}"' in swift
      and render.PAGINATION_FIELD == ops.PAGINATION_FIELD)

# --- a score's SOURCE layout is not the reader's -----------------------------
# The release gate for 0.13.0 caught the first version of this, which asked for
# `encoded` unconditionally: the string-quartet fixture carries its publisher's
# 48 system breaks and 12 page breaks, and went from Verovio's 8 pages to the
# edition's 4, at eight and a half bars a line.
print("\na score's own source layout is left alone until the reader paginates")

import zipfile  # noqa: E402

QUARTET = Path(__file__).resolve().parents[2] / "testdata" / "app-samples" / "sous-le-ciel-quartet.mxl"
with zipfile.ZipFile(QUARTET) as z:
    member = next(n for n in z.namelist()
                  if n.endswith((".xml", ".musicxml")) and not n.startswith("META"))
    quartet_xml = z.read(member).decode("utf-8")
check("the fixture really does carry a source layout",
      quartet_xml.count('new-system="yes"') > 0 and quartet_xml.count('new-page="yes"') > 0)


def pages(xml: str, breaks: str) -> int:
    tk = verovio.toolkit()
    tk.setOptions({**render.page_options(), "breaks": breaks})
    tk.loadData(xml)
    return tk.getPageCount()


as_before, as_published = pages(quartet_xml, "auto"), pages(quartet_xml, "encoded")
check(f"unmarked, it lays out as every build has: {pages(quartet_xml, render.breaks_for(quartet_xml))} pages "
      f"(auto {as_before}, the publisher's {as_published})",
      render.breaks_for(quartet_xml) == "auto" and as_before != as_published)

sourced = a_score(16)
from music21 import layout as m21layout  # noqa: E402
for part in sourced.parts:
    for m in part.getElementsByClass(stream.Measure):
        if m.number in (3, 11):
            m.insert(0.0, m21layout.SystemLayout(isNew=True))
        if m.number == 9:
            m.insert(0.0, m21layout.PageLayout(isNew=True))
check("a score with only source breaks draws exactly like one with none",
      drawn_systems(sourced, "sourced") == drawn_systems(a_score(16), "bare"),
      f"{drawn_systems(sourced, 'sourced')} vs {drawn_systems(a_score(16), 'bare')}")
# A source edition's line length (eight bars, 3 to 11) is not the reader's.
# Until 0.17.0 the op REFUSED here; it now chooses a length from how busy the
# bars are and says so, and the source's breaks at 3 and 11 do not survive.
import copy  # noqa: E402
chosen_from = copy.deepcopy(sourced)
chosen = ops.paginate(chosen_from, break_at=[7])
check("a source layout's line length is not taken as the reader's",
      chosen["measures_per_line_chosen"]
      and chosen["measures_per_line"] == ops.natural_measures_per_line(chosen_from)
      and 3 not in chosen["line_starts"] and 11 not in chosen["line_starts"]
      and 7 in chosen["line_starts"], str(chosen))
report = ops.paginate(sourced, measures_per_line=4)
check("paginating marks the score as the reader's", ops.reader_paginated(sourced))
page_breaks = sum(1 for p in sourced.parts for m in p.getElementsByClass(stream.Measure)
                  for pl in m.getElementsByClass(m21layout.PageLayout) if pl.isNew)
check("...replaces the source's page breaks as well as its lines", page_breaks == 0,
      f"{page_breaks} page breaks left")
check("...and the page follows the reader's lines",
      drawn_systems(sourced, "resourced") == [4, 4, 4, 4],
      str(drawn_systems(sourced, "resourced")))

# --- and the three modes are not interchangeable ---------------------------
print("\nthe modes do different things, which is why a reader's needs line")

paged = a_score(16)
ops.paginate(paged, measures_per_line=4)
check("line draws the four-bar lines the notation asks for",
      drawn_systems(paged, "line", "line") == [4, 4, 4, 4],
      str(drawn_systems(paged, "line", "line")))

# Through 0.16.0 a reader's pagination was drawn `encoded`, which breaks PAGES
# only where the notation says -- and paginating writes none. A score longer
# than a page was ONE page with every line on it, running off its foot: the
# 167-bar quartet, 35 systems on one sheet. Short tunes never showed it.
long_score = a_score(120, parts=4)
ops.paginate(long_score, measures_per_line=4)
LONG = SCRATCH / "long.musicxml"
SCRATCH.mkdir(parents=True, exist_ok=True)
long_score.write("musicxml", fp=str(LONG))


def page_count(breaks: str) -> int:
    tk = verovio.toolkit()
    tk.setOptions({**render.page_options(), "breaks": breaks})
    tk.loadFile(str(LONG))
    return tk.getPageCount()


check("a paginated score longer than a page turns its pages",
      page_count(render.breaks_for(LONG.read_text(encoding="utf-8"))) > 1,
      f"{page_count(render.breaks_for(LONG.read_text(encoding='utf-8')))} page(s)")
check("...which encoded does not: every line on one page, the 0.13-0.16 bug",
      page_count("encoded") == 1, f"encoded gave {page_count('encoded')}")
check("...and every line is still the reader's four bars",
      set(drawn_systems(long_score, "long")) == {4}, str(set(drawn_systems(long_score, "long"))))
auto = drawn_systems(paged, "auto", "auto")
check("auto ignores them outright -- the bug this would have shipped",
      auto != [4, 4, 4, 4], f"auto gave {auto}")

# --- a complete layout, never a lone break ---------------------------------
print("\nevery pagination is complete, because a lone break crushes the rest")

one = a_score(16)
ops.paginate(one, measures_per_line=4)
report = ops.paginate(one, break_at=[7])
check("a forced break keeps its bar at the head of a line",
      7 in report["line_starts"], str(report["line_starts"]))
check("...and no line is longer than the score's own length",
      max(report["bars_per_line"]) <= report["measures_per_line"],
      str(report["bars_per_line"]))
check("...which is what the page actually shows",
      drawn_systems(one, "forced") == report["bars_per_line"],
      f"drawn {drawn_systems(one, 'forced')} vs reported {report['bars_per_line']}")

# --- the round trip, which is where chord diagrams died --------------------
print("\nbreaks survive being written and read back, every version is")

from music21 import converter  # noqa: E402

SCRATCH.mkdir(parents=True, exist_ok=True)
trip = SCRATCH / "roundtrip.musicxml"
rt = a_score(16)
ops.paginate(rt, measures_per_line=4)
rt.write("musicxml", fp=str(trip))
back = converter.parse(str(trip), forceSource=True)
check("a break read back is still a break",
      ops.system_break_bars(back) == [5, 9, 13],
      str(ops.system_break_bars(back)))
again = SCRATCH / "roundtrip2.musicxml"
back.write("musicxml", fp=str(again))
check("and survives a second write, which every op performs",
      again.read_text().count('new-system="yes"') == 3,
      str(again.read_text().count('new-system="yes"')))
check("the reader's mark survives it too, or the next op would unpaginate",
      render.breaks_for(again.read_text()) == "line")

# --- clearing hands it back ------------------------------------------------
print("\nclearing gives the layout back to the engraver")

cleared = a_score(16)
ops.paginate(cleared, measures_per_line=4)
gone = ops.paginate(cleared, clear=True)
check("every break is removed and counted",
      gone["breaks_removed"] == 3, str(gone))
check("...and the reader's mark with them", not ops.reader_paginated(cleared))
check("and a score with none falls back to the engraver's own layout",
      drawn_systems(cleared, "cleared") == drawn_systems(a_score(16), "plain", "auto"),
      f"{drawn_systems(cleared, 'cleared')} vs auto {drawn_systems(a_score(16), 'plain', 'auto')}")

# --- a break is a property of the SYSTEM, so every staff carries one -------
print("\na break goes on every staff, as a volta has to")

grand = a_score(8, parts=3)
ops.paginate(grand, measures_per_line=4)
per_part = [[m.number for m in p.getElementsByClass(stream.Measure)
             if any(sl.isNew for sl in m.getElementsByClass(layout.SystemLayout))]
            for p in grand.parts]
check("all three staves break at the same bar",
      per_part == [[5], [5], [5]], str(per_part))

# --- refusals --------------------------------------------------------------
print("\nwith no length written or given, it chooses one and says so (0.17.0)")

bare = a_score(16)
report = ops.paginate(bare, break_at=[9])
check("a bare break on a score nobody paginated is not refused",
      report["measures_per_line_chosen"] is True, str(report))
check("...the length is the one natural_measures_per_line chooses",
      report["measures_per_line"] == ops.natural_measures_per_line(a_score(16)),
      str(report["measures_per_line"]))
check("...and the report says it was chosen, and how to ask for another",
      "chosen" in report["note"] and "measures_per_line" in report["note"], report["note"])
check("...and bar 9 starts a line on the page", 9 in report["line_starts"],
      str(report["line_starts"]))

try:
    ops.paginate(a_score(8), break_at=[99])
    check("a bar that does not exist must be refused", False)
except ValueError as exc:
    check("a bar outside the score is refused with the range",
          "99" in str(exc) and "1-8" in str(exc), str(exc))
try:
    ops.paginate(a_score(8), end_at=[99])
    check("a line cannot end at a bar that does not exist", False)
except ValueError as exc:
    check("...and so is a line ending at one", "99" in str(exc), str(exc))

print("\na line ends where the reader says, and the rest is laid out sensibly")

s = a_score(16)
ops.paginate(s, measures_per_line=4)
r = ops.paginate(s, end_at=[10])
check("ending a line at bar 10 makes bar 11 start the next", 11 in r["line_starts"],
      str(r["line_starts"]))
check("...the lines before it are evened out, not 4, 4 and a stranded 2",
      r["bars_per_line"][:3] == [4, 3, 3], str(r["bars_per_line"]))
check("...the old breaks after it are derived again, not kept around it",
      r["bars_per_line"] == [4, 3, 3, 4, 2], str(r["bars_per_line"]))
check("...and the PAGE draws those lines",
      drawn_systems(s, "end-at-10") == r["bars_per_line"],
      f"{drawn_systems(s, 'end-at-10')} vs {r['bars_per_line']}")
r = ops.paginate(s, end_at=[3])
check("a second line ending is remembered beside the first",
      4 in r["line_starts"] and 11 in r["line_starts"], str(r["line_starts"]))
r = ops.paginate(s, remove_at=[11])
check("removing a forced break forgets it", 11 not in ops._read_forced(s)[1],
      str(ops._read_forced(s)))
check("...and no line is left holding a single bar", 1 not in r["bars_per_line"],
      str(r["bars_per_line"]))
derived = next(b for b in r["line_starts"] if b not in (1, 4))
r = ops.paginate(s, remove_at=[derived])
check(f"removing a break the op filled in (bar {derived}) keeps it off",
      derived not in r["line_starts"], str(r["line_starts"]))
r = ops.paginate(s, measures_per_line=4)
check("a fresh length forgets every forced line", r["bars_per_line"] == [4, 4, 4, 4],
      str(r["bars_per_line"]))

r = ops.paginate(a_score(13), measures_per_line=4)
check("a last line of one bar is evened out instead (13 bars at 4: 4, 3, 3, 3)",
      r["bars_per_line"] == [4, 3, 3, 3], str(r["bars_per_line"]))

pickup = a_score(9)
for index, m in enumerate(pickup.parts[0].getElementsByClass(stream.Measure)):
    m.number = index                      # an upbeat, then bars 1-8
pickup.parts[0].getElementsByClass(stream.Measure)[0].paddingLeft = 3.0
r = ops.paginate(pickup, measures_per_line=4)
check("a pickup rides in front of the first line without counting toward it",
      r["line_starts"] == [0, 5], str(r["line_starts"]))

print("\nthe chosen length prefers phrases and follows how busy the bars are")

import fixtures  # noqa: E402
check("a reel-like line of quavers: 4 bars a line",
      ops.natural_measures_per_line(fixtures.sax_study(bars=8)) == 4)
check("a jig fits more than four but is laid out at four, a phrase",
      ops.natural_measures_per_line(fixtures.jig(bars=16)) == 4)
check("whole notes: eight a line, not thirty", ops.natural_measures_per_line(a_score(16)) == 8)

import shutil  # noqa: E402
shutil.rmtree(SCRATCH, ignore_errors=True)

if FAILURES:
    print(f"\nFAIL: {len(FAILURES)} pagination check(s) failed")
    for line in FAILURES:
        print("   ", line)
    sys.exit(1)
print("\nOK: the lines break where the notation says, and both renderers ask for it")
