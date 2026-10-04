"""Regression check for guitar chord diagrams.

Six things are asserted, and each one is a way the feature has an obvious
wrong-but-plausible form:

  - THE SHAPES. The chart of conventional shapes is published fact, so it is
    checked against the published fact, chord by chord, the way
    check_whistle.py checks the whistle's fingerings. A chord the search has to
    work out is checked for the things that make a voicing real: every chord
    tone sounding, the root in the bass, a hand that can reach it. And the
    chart is not the same rule as "the lowest voicing": A7 and Dm7 can both be
    played open and are both written as fifth-fret barres, which is what the
    chart says and what the op draws.
  - THE HAND. Which finger goes on each dot, which is a second published fact
    and not a restatement of the first. Frets and fingers coincide for a C --
    x32010 both ways -- and part company for a G, 320003 under the fingers and
    320004 in them. Movable shapes are derived from the open shape they are a
    barre of and are asserted from that derivation, not from a table.
  - THE REFERENCE CHART, engraved: C, G, A7 and Dm7 taken the whole way
    through music21, Verovio and both rendering passes, with the four marks
    rows, the two barres, the two fret labels and the two nuts read back off
    the page. Everything else here is arithmetic over lists; this is the
    picture.
  - WHAT A BARRE IS. One finger across the neck is drawn as one bar, not as a
    row of separate dots — and it stops every string it crosses, so a shape
    with an open string inside the span is not a barre and is not playable.
  - THE WINDOW. The thick top line is the nut, and it is drawn only when the
    shape sits at the nut; a shape higher up the neck is a window, and it is
    the window that carries the "5 fr." label. One rule decides both, so they
    cannot disagree.
  - THE TWO RENDERERS. render.py draws the PDF and ChordDiagrams.swift draws
    the page on the iPad. They are held to ONE golden fragment, kept in
    ios/ScorangerTests/Fixtures/chord-diagrams-golden.txt: this check writes
    what Python draws and compares, ChordDiagramsTests asserts Swift against
    the same file. A change made in one renderer and not the other fails a
    check rather than the eye.

Run: engine/.venv/bin/python engine/scripts/check_chord_diagrams.py
     ... --write   to re-cut the golden fragment after a deliberate change
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "engine"))

from scoranger_engine import ops, render  # noqa: E402

GOLDEN = ROOT / "ios" / "ScorangerTests" / "Fixtures" / "chord-diagrams-golden.txt"
SWIFT = ROOT / "ios" / "Scoranger" / "ScoreModel" / "ChordDiagrams.swift"

FAILURES: list[str] = []


def check(label: str, ok: bool, detail: str = "") -> None:
    if not ok:
        FAILURES.append(f"{label}{': ' + detail if detail else ''}")


def drawn_for(symbol: str, tuning: str = "EADGBE",
              shapes: list[str] | None = None) -> dict | None:
    """What the op would engrave for one chord symbol."""
    from music21 import harmony, meter, note, stream

    score = stream.Score()
    part = stream.Part()
    measure = stream.Measure(number=1)
    measure.append(meter.TimeSignature("4/4"))
    measure.insert(0.0, harmony.ChordSymbol(symbol))
    measure.append(note.Note("C4", quarterLength=4))
    part.append(measure)
    score.append(part)
    report = ops.chord_diagrams(score, part, tuning,
                                shapes=ops.parse_shape_overrides(shapes))
    if report["unplayable_count"]:
        return None
    return report["shapes"][0]


def shape_of(symbol: str, tuning: str = "EADGBE") -> str | None:
    """The shape the op would engrave for one chord symbol, as its shorthand."""
    drawn = drawn_for(symbol, tuning)
    return drawn["shape"] if drawn else None


# --- the published chart ----------------------------------------------------
#
# The shapes a player already has in their hands. Written the way a chord book
# writes them, low string to high — and beside each one the HAND that plays it,
# which is a second published fact and not a restatement of the first. C is
# x32010 both ways; G is 320003 under the fingers and 320004 in them, ring and
# middle low and the PINKY on the top E, and no arithmetic over six fret
# numbers produces that.
for symbol, frets, fingers in [
    ("C", "x32010", "x32010"), ("G", "320003", "320004"),
    ("D", "xx0232", "xx0132"), ("A", "x02220", "x01230"),
    ("E", "022100", "023100"), ("Am", "x02210", "x02310"),
    ("Em", "022000", "023000"), ("Dm", "xx0231", "xx0231"),
    ("D7", "xx0212", "xx0213"), ("E7", "020100", "020100"),
    ("G7", "320001", "320001"), ("Am7", "x02010", "x02010"),
    ("Cmaj7", "x32000", "x32000"),
    # movable shapes: nothing below is in the fingering table. Each one is
    # derived by the rule a method book teaches — the index bars the fret the
    # nut used to be, every other finger steps up one — so F is the E shape
    # with 2,3,1 become 3,4,2, and Bm is the Am shape the same way.
    ("F", "133211", "134211"), ("Fm", "133111", "134111"),
    ("Bm", "x24432", "x13421"),
]:
    got = drawn_for(symbol)
    want = ops.shape_text(ops._shape_from_text(frets))
    check(f"{symbol} is {frets}", got and got["shape"] == want, str(got))
    want_fingers = ",".join("x" if f is None else str(f)
                            for f in ops._shape_from_text(fingers))
    check(f"{symbol} is played {fingers}", got and got["fingering"] == want_fingers,
          str(got))

# --- the conventional shape, not the lowest one -----------------------------
#
# The search would find both of these open, because open is lowest and lowest
# is what the search is for. The chart is consulted first for exactly this
# reason: an A7 in a turnaround is a fifth-fret barre, and so is the Dm7 it
# resolves to. The open shapes are still there, one --shape away.
for symbol, frets, fingers in [("A7", "575655", "131211"),
                               ("Dm7", "x57565", "x13121")]:
    got = drawn_for(symbol)
    check(f"{symbol} is the fifth-fret barre {frets}",
          got and got["shape"] == ops.shape_text(ops._shape_from_text(frets)),
          str(got))
    check(f"{symbol} is fingered {fingers}",
          got and got["fingering"] == ",".join(
              "x" if f is None else str(f) for f in ops._shape_from_text(fingers)),
          str(got))
    check(f"{symbol} says it is a barre at the fifth fret",
          got and got["barre"] and got["first_fret"] == 5 and not got["nut"],
          str(got))

for symbol, open_shape in [("A7", "x02020"), ("Dm7", "xx0211")]:
    pinned = drawn_for(symbol, shapes=[f"{symbol}={open_shape}"])
    check(f"--shape reaches the open {symbol}",
          pinned and pinned["shape"] == ops.shape_text(
              ops._shape_from_text(open_shape)) and pinned["pinned"],
          str(pinned))
for bad in ["A7", "A7=x0202", "=x02020"]:
    try:
        ops.parse_shape_overrides([bad])
        check(f"--shape {bad!r} is refused", False)
    except ValueError:
        check(f"--shape {bad!r} is refused", True)

# --- a fingering nobody curated is not invented ------------------------------
#
# The marks row falls back to the frets, which is honest: a fret number is a
# fact about the shape. A made-up hand would not be.
check("an uncurated, underivable shape has no fingering",
      ops.chord_fingering(ops.parse_shape("[x,x,0,7,9,8]")) is None)
check("...and its marker carries none",
      ops.shape_text(ops.parse_shape("[x,x,0,7,9,8]"), None) == "[x,x,0,7,9,8]")
check("a fingering that repeats the frets is not written either",
      ops.shape_text(ops.parse_shape("[x,3,2,0,1,0]"),
                     ops.chord_fingering(ops.parse_shape("[x,3,2,0,1,0]")))
      == "[x,3,2,0,1,0]")
check("one that does not is",
      ops.shape_text(ops.parse_shape("[3,2,0,0,0,3]"),
                     ops.chord_fingering(ops.parse_shape("[3,2,0,0,0,3]")))
      == "[3,2,0,0,0,3](3,2,0,0,0,4)")
check("and it reads back", ops.parse_fingering("[3,2,0,0,0,3](3,2,0,0,0,4)")
      == [3, 2, 0, 0, 0, 4]
      and ops.parse_shape("[3,2,0,0,0,3](3,2,0,0,0,4)") == [3, 2, 0, 0, 0, 3])
check("a marker with no fingering reads back as none",
      ops.parse_fingering("[x,3,2,0,1,0]") is None)

# --- shapes the search has to work out --------------------------------------
#
# Nothing in the chart covers these, so the arithmetic is on its own. What is
# asserted is what makes a voicing real rather than what a particular table
# says, since there is more than one right answer.
for symbol in ["G#m7", "B-7", "F#7", "E-", "C#m", "A-maj7"]:
    text = shape_of(symbol)
    if text is None:
        check(f"{symbol} has a shape", False, "reported unplayable")
        continue
    shape = ops.parse_shape(text)
    opens = [__import__("music21").pitch.Pitch(p).midi
             for p in ops.GUITAR_TUNINGS["EADGBE"]]
    sounded = [i for i, f in enumerate(shape) if f is not None]
    pcs = {(opens[i] + shape[i]) % 12 for i in sounded}
    from music21 import harmony as _h
    wanted = {p.pitchClass for p in _h.ChordSymbol(symbol).pitches}
    root = _h.ChordSymbol(symbol).root().pitchClass
    stopped = [f for f in shape if f]
    check(f"{symbol} {text} sounds the chord", pcs == wanted, f"{pcs} vs {wanted}")
    check(f"{symbol} {text} has the root in the bass",
          (opens[sounded[0]] + shape[sounded[0]]) % 12 == root)
    check(f"{symbol} {text} is contiguous",
          sounded == list(range(sounded[0], sounded[-1] + 1)))
    check(f"{symbol} {text} is within a hand",
          not stopped or max(stopped) - min(stopped) <= ops.GUITAR_FRET_SPAN,
          f"span {max(stopped) - min(stopped) if stopped else 0}")
    check(f"{symbol} {text} needs no fifth finger",
          ops._fingers_needed(shape) <= ops.GUITAR_MAX_FINGERS)

# --- the tuning is real, not decorative -------------------------------------
#
# DADGAD is not standard tuning with different letters: the same chord is a
# different shape, and the chart does not apply to it.
standard_d = shape_of("D")
dadgad_d = shape_of("D", "DADGAD")
check("DADGAD gives its own D", dadgad_d not in (None, standard_d),
      f"standard {standard_d}, DADGAD {dadgad_d}")
check("drop D gives a D of its own", shape_of("D", "DADGBE") is not None)
try:
    ops.guitar_tuning("EADGBF")
    check("an unknown tuning is refused", False)
except ValueError:
    check("an unknown tuning is refused", True)

# --- what cannot be played is reported, not faked ---------------------------
#
# The op reports; it never quietly writes a shape that is not the chord.
from music21 import harmony as m21harmony  # noqa: E402
from music21 import meter as m21meter  # noqa: E402
from music21 import note as m21note  # noqa: E402
from music21 import stream as m21stream  # noqa: E402

score = m21stream.Score()
part = m21stream.Part()
measure = m21stream.Measure(number=1)
measure.append(m21meter.TimeSignature("4/4"))
# seven notes on six strings: a thirteenth names more pitches than a guitar
# has strings, so no voicing sounds the whole chord
measure.insert(0.0, m21harmony.ChordSymbol("C13"))
measure.append(m21note.Note("C4", quarterLength=4))
part.append(measure)
score.append(part)
report = ops.chord_diagrams(score, part, "EADGBE")
check("an unplayable chord is reported",
      report["unplayable_count"] == 1 and report["diagrams"] == 0,
      f"{report['diagrams']} drawn, {report['unplayable_count']} reported")
check("the report says which bar and which chord",
      bool(report["unplayable"]) and report["unplayable"][0]["measure"] == 1
      and report["unplayable"][0]["symbol"] == "C13",
      str(report["unplayable"]))
from music21 import expressions as m21expressions  # noqa: E402
check("nothing is written for it",
      not list(part.recurse().getElementsByClass(m21expressions.TextExpression)))

# --- a transposed score does not keep the old shapes ------------------------
#
# Six frets are one chord. Transpose the music and every diagram on it is
# describing the chord that used to be there, so they go, and the report says
# how many.
score = m21stream.Score()
part = m21stream.Part()
part.partName = "Guitar"
measure = m21stream.Measure(number=1)
measure.append(m21meter.TimeSignature("4/4"))
measure.insert(0.0, m21harmony.ChordSymbol("C"))
measure.append(m21note.Note("C4", quarterLength=4))
part.append(measure)
score.append(part)
ops.chord_diagrams(score, part, "EADGBE")
moved = ops.transpose(score, "M2")
check("transposing clears the diagrams it would have made wrong",
      moved.get("chord_diagrams_cleared") == 1, str(moved))
check("...and leaves none behind",
      not [e for e in part.recurse().getElementsByClass(m21expressions.TextExpression)
           if ops.parse_shape(e.content) is not None])

# --- a barre is a barre -----------------------------------------------------
F = ops.parse_shape("[1,3,3,2,1,1]")
check("F barres the first fret", ops.diagram_barre(F) == (1, 0, 5),
      str(ops.diagram_barre(F)))
check("C does not barre", ops.diagram_barre(ops.parse_shape("[x,3,2,0,1,0]")) is None)
# two fingers that happen to share a fret are not a barre: nothing higher lies
# between them
check("a shared fret with nothing above it is not a barre",
      ops.diagram_barre(ops.parse_shape("[x,x,0,2,1,1]")) is None)
# a finger across the neck stops every string it crosses
check("a barre cannot cross an open string",
      ops.diagram_barre(ops.parse_shape("[4,6,4,4,0,4]")) is None)
check("...and the search will not offer one",
      ops._fingers_needed(ops.parse_shape("[4,6,4,4,0,4]")) > ops.GUITAR_MAX_FINGERS)

barre_svg = render.chord_diagram_svg(F, 0, 0, 100)
check("a barre is drawn as one bar, not as dots",
      barre_svg.count('<path d="M 0 103 H 500 V 147 H 0 Z"') == 1
      # three stopped strings are inside the bar, so three dots are left: the
      # two at the third fret and the one at the second
      and barre_svg.count("A 30 30 0 1 0") == 6,
      barre_svg)

# --- the nut, and the label that replaces it --------------------------------
check("a shape at the nut is drawn against the nut",
      ops.diagram_window(ops.parse_shape("[x,3,2,0,1,0]")) == (1, True))
check("...and so is one that reaches the fifth fret",
      ops.diagram_window(ops.parse_shape("[x,x,0,5,5,5]")) == (1, True))
check("a shape above it is a window on the neck",
      ops.diagram_window(ops.parse_shape("[4,6,4,4,4,4]")) == (4, False))

nut_svg = render.chord_diagram_svg(ops.parse_shape("[x,3,2,0,1,0]"), 0, 0, 100)
high_svg = render.chord_diagram_svg(ops.parse_shape("[4,6,4,4,4,4]"), 0, 0, 100)
check("the nut is thicker than a fret line",
      'stroke-width="16"' in nut_svg and 'stroke-width="5"' in nut_svg)
check("a windowed shape has no nut", 'stroke-width="16"' not in high_svg)
check("...and carries its fret number", "4 fr." in high_svg)
check("a shape at the nut carries no fret number", "fr." not in nut_svg)

# --- the reader's nudge reaches the page ------------------------------------
#
# `adjust-element --kind diagram` writes three numbers onto the marker, and
# Verovio drops all three, so the MEI pass has to carry them. Both of these
# were wrong once and both were visible only on an engraving.
import tempfile as _tempfile  # noqa: E402

score = m21stream.Score()
part = m21stream.Part()
part.partName = "Guitar"
for index, symbol in enumerate(["C", "G"]):
    measure = m21stream.Measure(number=index + 1)
    if index == 0:
        measure.append(m21meter.TimeSignature("4/4"))
    measure.insert(0.0, m21harmony.ChordSymbol(symbol))
    measure.append(m21note.Note("C4", quarterLength=4))
    part.append(measure)
score.append(part)
ops.chord_diagrams(score, part, "EADGBE")
nudged = ops.adjust_element(score, "Guitar", kind="diagram", measure=2,
                            size=18.0, offset_x=25.0, offset_y=30.0)
check("a diagram is addressable by adjust-element", nudged["adjusted"] == 1, str(nudged))
path = Path(_tempfile.mkdtemp(prefix="scoranger-diagram-")) / "s.musicxml"
score.write("musicxml", fp=str(path))
found = render.diagram_adjustments(path)
check("the nudge is in the notation, not in the renderer",
      found == [{"size": None, "dx": None, "dy": None},
                {"size": 18.0, "dx": 25.0, "dy": 30.0}], str(found))

import verovio as _verovio  # noqa: E402
_tk = _verovio.toolkit()
_tk.loadFile(str(path))
carried = render.mei_with_chord_diagrams(_tk.getMEI(), path)
blocks = carried.split("<dir")[1:]
check("a nudge upwards is carried upwards",
      'vo="6"' in blocks[1] and "vo=" not in blocks[0],
      "MusicXML relative-y and a dir's @vo both measure up")
check("...and sideways", 'ho="5"' in blocks[1])
# an enlarged diagram needs a taller block, or it draws through the staff
check("an enlarged diagram reserves more rows than a plain one",
      blocks[1].count("<lb/>") > blocks[0].count("<lb/>"),
      f'{blocks[1].count("<lb/>")} vs {blocks[0].count("<lb/>")}')
check("...and says how much bigger it is", '@1.5"' in blocks[1])

# --- the reference chart, engraved ------------------------------------------
#
# Four chords, and the page the owner drew them on. Everything above this is
# arithmetic over lists; this is the picture, taken the whole way through
# music21, Verovio, the MEI pass and the SVG pass, and read back off the page.
#
# It is here because each of the four is a different way the feature was wrong:
# C is where the frets and the hand agree and nothing should change; G is where
# they part company and the row must read the hand; A7 and Dm7 are where the
# lowest shape is not the played one, and they carry the barre and the "5 fr."
# the shape implies.
REFERENCE = [
    ("C",   "x,3,2,0,1,0", "x32010", 1, False),
    ("G",   "3,2,0,0,0,4", "320004", 1, False),
    ("A7",  "1,3,1,2,1,1", "131211", 5, True),
    ("Dm7", "x,1,3,1,2,1", "x13121", 5, True),
]

score = m21stream.Score()
part = m21stream.Part()
part.partName = "Guitar"
for index, (symbol, _marks, _flat, _fret, _barre) in enumerate(REFERENCE):
    measure = m21stream.Measure(number=index + 1)
    if index == 0:
        measure.append(m21meter.TimeSignature("4/4"))
    measure.insert(0.0, m21harmony.ChordSymbol(symbol))
    measure.append(m21note.Note("C4", quarterLength=4))
    part.append(measure)
score.append(part)
reference = ops.chord_diagrams(score, part, "EADGBE")
check("the reference chart draws four diagrams", reference["diagrams"] == 4,
      str(reference))

reference_dir = Path(_tempfile.mkdtemp(prefix="scoranger-reference-"))
reference_xml = reference_dir / "reference.musicxml"
score.write("musicxml", fp=str(reference_xml))
_tk = _verovio.toolkit()
_tk.loadFile(str(reference_xml))
_mei = render.mei_with_chord_diagrams(_tk.getMEI(), reference_xml)
check("the reference chart survives the round trip into MEI", _mei is not None)
if _mei is not None and _tk.loadData(_mei):
    page = render._chord_diagrams(render._sanitize_svg(_tk.renderToSVG(1)))
    drawn = re.findall(r'<g class="dir chord-diagram">(.*?)</g>', page, re.S)
    check("four diagrams reach the page", len(drawn) == 4, f"{len(drawn)}")
    for (symbol, marks, _flat, fret, barre), svg in zip(REFERENCE, drawn):
        row = re.findall(r'<tspan font-size="[\d.]+px">([x\d]+)</tspan>', svg)
        # the marks row is the six leading single characters; a "5 fr." label
        # is matched by the same pattern and is not part of the row
        check(f"the row over {symbol} reads {marks}",
              ",".join(row[:6]) == marks, f"read {row[:6]}")
        # a bar is a filled rectangle: 'H ... V ... H ... Z'. A dot is arcs.
        check(f"{symbol} {'is' if barre else 'is not'} drawn with a barre",
              (" V " in svg) == barre)
        check(f"{symbol} {'carries' if fret > 1 else 'carries no'} fret label",
              (f"{fret} fr." in svg) == (fret > 1), svg[-260:])
        # the nut is the one line drawn thicker than the rest, so a diagram
        # that has one is drawn with two stroke widths and one that has not
        # with a single width
        widths = set(re.findall(r'stroke-width="([\d.]+)"', svg))
        check(f"{symbol} {'has no' if fret > 1 else 'has a'} nut",
              (len(widths) == 2) == (fret == 1), str(sorted(widths)))
else:
    check("the reference chart engraves", False, "Verovio would not reload it")

# --- the two renderers draw the same picture --------------------------------
CASES = [
    ("[x,3,2,0,1,0]", 638.0, 1443.0, 390.0, 1.0),      # open, at the nut
    ("[1,3,3,2,1,1](1,3,4,2,1,1)", 2421.0, 1443.0, 390.0, 1.0),   # a barre at the nut
    ("[4,6,4,4,4,4](1,3,1,1,1,1)", 4204.0, 1443.0, 390.0, 1.0),   # a window, labelled
    ("[3,2,0,0,0,3](3,2,0,0,0,4)", 638.0, 990.5, 402.5, 1.5),     # enlarged, and the
                                                       # one shape where the hand and
                                                       # the frets part company
    ("[x,x,0,7,9,8]", 4204.0, 990.5, 402.5, 1.0),      # no fingering: the frets stand
]
lines = []
for shape_text, x, top, pitch, scale in CASES:
    drawn = render.chord_diagram_svg(ops.parse_shape(shape_text), x, top, pitch, scale,
                                     ops.parse_fingering(shape_text))
    lines.append(f"{shape_text}|{x:g}|{top:g}|{pitch:g}|{scale:g}\t{drawn}")
golden = "\n".join(lines) + "\n"

if "--write" in sys.argv:
    GOLDEN.parent.mkdir(parents=True, exist_ok=True)
    GOLDEN.write_text(golden, encoding="utf-8")
    print(f"wrote {GOLDEN.relative_to(ROOT)}")
else:
    have = GOLDEN.read_text(encoding="utf-8") if GOLDEN.exists() else ""
    check("the golden fragment is what render.py draws", have == golden,
          "run check_chord_diagrams.py --write if the change was deliberate")

# The Swift half cannot be run from here, so what is asserted is that it is
# still holding itself to the same numbers: its constants, and the fixture its
# own test reads. ChordDiagramsTests does the drawing comparison.
swift = SWIFT.read_text(encoding="utf-8") if SWIFT.exists() else ""
for name, value in [("dotVsGap", render.DIAGRAM_DOT_VS_GAP),
                    ("barreVsGap", render.DIAGRAM_BARRE_VS_GAP),
                    ("lineVsGap", render.DIAGRAM_LINE_VS_GAP),
                    ("nutVsGap", render.DIAGRAM_NUT_VS_GAP),
                    ("markTextVsGap", render.DIAGRAM_MARK_TEXT_VS_GAP),
                    ("positionTextVsGap", render.DIAGRAM_POSITION_TEXT_VS_GAP),
                    ("gapVsRow", render.DIAGRAM_GAP_VS_ROW),
                    ("defaultPoints", render.DEFAULT_DIAGRAM_POINTS)]:
    check(f"ChordDiagrams.swift keeps {name} = {value:g}",
          f"static let {name} = {value:g}" in swift)
check("ChordDiagrams.swift reserves the same block",
      f"static let rows = {render.DIAGRAM_ROWS}" in swift
      and f"static let frets = {render.DIAGRAM_FRETS}" in swift)

# ---------------------------------------------------------------------------
# 0.18.2: diagrams that would meet are drawn smaller. Verovio reserves a
# diagram's height but no width, and @vgrp pins them all to one level, so two
# chords a bar apart drew one grid over the other (Amazing Grace bars 3-4, in
# the App Store screenshots).
for name, value in [("clearanceGaps", render.DIAGRAM_CLEARANCE_GAPS),
                    ("minFit", render.DIAGRAM_MIN_FIT)]:
    check(f"ChordDiagrams.swift keeps {name} = {value:g}",
          f"static let {name} = {value:g}" in swift)
# The numbers ChordDiagramsTests.testFitMatchesRenderPy asserts on the Swift
# side, so the two rules are held to one answer.
FIT_CASES = [dict(x=0, top=100, pitch=100, scale=1),     # 600 wanted, 300 room
             dict(x=300, top=100, pitch=100, scale=1),   # 600 wanted, 1000 room
             dict(x=1300, top=100, pitch=100, scale=1),  # 600 wanted, 100 room: floor
             dict(x=1400, top=100, pitch=100, scale=1),  # last on its line
             dict(x=10, top=900, pitch=100, scale=1)]    # another line: unaffected
check("render.diagram_fit gives the numbers the Swift test holds",
      render.diagram_fit(FIT_CASES) == [0.5, 1.0, 0.5, 1.0, 1.0],
      str(render.diagram_fit(FIT_CASES)))

crowded = m21stream.Score()
lead = m21stream.Part()
lead.partName = "Guitar"
for number, (first, second) in enumerate([("G", "C"), ("G", "D"), ("Em", "C")], start=1):
    measure = m21stream.Measure(number=number)
    if number == 1:
        measure.append(m21meter.TimeSignature("3/4"))
    measure.insert(0, m21harmony.ChordSymbol(first))
    measure.insert(2, m21harmony.ChordSymbol(second))
    measure.append(m21note.Note("G4", quarterLength=2))
    measure.append(m21note.Note("A4", quarterLength=1))
    lead.append(measure)
crowded.append(lead)
ops.chord_diagrams(crowded, lead, "EADGBE")
crowded_xml = Path(_tempfile.mkdtemp(prefix="scoranger-crowded-")) / "crowded.musicxml"
crowded.write("musicxml", fp=str(crowded_xml))
_tk.loadFile(str(crowded_xml))
_mei = render.mei_with_chord_diagrams(_tk.getMEI(), crowded_xml)
if _mei is not None and _tk.loadData(_mei):
    _svg = render._sanitize_svg(_tk.renderToSVG(1))
    _blocks = render.chord_diagram_blocks(_svg)
    _fits = render.diagram_fit(_blocks)
    # (left, right edge as drawn, line, fit), left to right
    spans = sorted((b["x"], b["x"] + b["pitch"] * b["scale"] * f
                    * (render.DIAGRAM_STRINGS - 1), b["top"], f)
                   for b, f in zip(_blocks, _fits))
    # A grid reaching the next one on its line, unless it is already at the
    # floor -- that much crowding overlaps by design rather than vanishing.
    meets = [(a, b) for a, b in zip(spans, spans[1:])
             if abs(a[2] - b[2]) < 1 and a[1] > b[0] and a[3] > render.DIAGRAM_MIN_FIT]
    check("six chords two beats apart: diagrams are drawn smaller, not over each other",
          len(_blocks) == 6 and any(f < 1 for f in _fits) and not meets,
          f"blocks {len(_blocks)}, fits {_fits}, meeting {meets}")
else:
    check("the crowded chart engraves", False, "Verovio would not reload it")

# ---------------------------------------------------------------------------
# A SEVENTH thing: the op says so when there is nothing to draw on.
#
# Ali, 0.6.10: "the agent reports adding chord-diagram grids but none appear on
# the score." The renderers were the first suspects and both are innocent --
# everything above this line passes, and a part carrying chord symbols engraves
# its diagrams correctly.
#
# What happens is upstream. `chord-diagrams` hangs a diagram over every chord
# symbol the part ALREADY carries, by design: `set-chords` writes the symbols
# and `chart_style` places them, and a second notion of where a chord sits
# would fall out of step with the first. Run against a part with no chord
# symbols it therefore had nothing to do -- and returned {"diagrams": 0} as a
# SUCCESS, with a new version to show for it. The agent relays a successful op,
# the reader is told diagrams were added, and the page is unchanged.
#
# So an op that cannot do the thing says so, which is this repo's own rule:
# correctness belongs in the op. The error names the parts that DO carry chord
# symbols, because "there are none here" and "you asked for the wrong staff"
# are the two ways to arrive and they need different next steps.
score = m21stream.Score()
bare = m21stream.Part()
bare.partName = "Violin I"
for number in (1, 2):
    measure = m21stream.Measure(number=number)
    if number == 1:
        measure.append(m21meter.TimeSignature("4/4"))
    measure.append(m21note.Note("C4", quarterLength=4))
    bare.append(measure)
score.append(bare)

charted = m21stream.Part()
charted.partName = "Guitar"
for number in (1, 2):
    measure = m21stream.Measure(number=number)
    if number == 1:
        measure.append(m21meter.TimeSignature("4/4"))
    measure.insert(0, m21harmony.ChordSymbol("G"))
    measure.append(m21note.Note("G3", quarterLength=4))
    charted.append(measure)
score.append(charted)

try:
    ops.chord_diagrams(score, bare)
except ValueError as exc:
    message = str(exc)
    check("a part with no chord symbols is refused, not silently no-opped", True)
    check("the refusal names the part asked for", "Violin I" in message, message)
    check("the refusal names a part that does carry symbols",
          "Guitar" in message, message)
    check("the refusal says what to do next",
          "set-chords" in message, message)
except Exception as exc:  # noqa: BLE001
    check("a part with no chord symbols is refused, not silently no-opped",
          False, f"raised {type(exc).__name__} rather than ValueError: {exc}")
else:
    check("a part with no chord symbols is refused, not silently no-opped",
          False, "the op returned successfully with nothing drawn -- which is "
                 "what makes the agent say it added diagrams when it did not")

# And the op still WORKS where there is something to draw on: the refusal must
# not be reachable by a part that has symbols.
drew = ops.chord_diagrams(score, charted)
check("a part that does carry chord symbols still gets its diagrams",
      drew.get("diagrams") == 2, str(drew.get("diagrams")))

# --clear is not a draw and must not be refused: clearing a part that has no
# diagrams is how a reader undoes a mistake, and it has to work on any staff.
cleared = ops.chord_diagrams(score, bare, clear=True)
check("clearing a part with no chord symbols is allowed",
      cleared.get("cleared") == 0, str(cleared))

if FAILURES:
    print(f"FAIL: {len(FAILURES)} chord-diagram check(s)")
    for line in FAILURES:
        print("   ", line)
    sys.exit(1)
print("OK: chord diagrams match the chart, the rules and the other renderer")
