"""Regression check for how things are SIZED on the page.

Verovio has exactly one text-size option, `lyricSize`, and it sizes lyric
verses AND `<harm>` chord symbols. Build 128 halved it to shrink the whistle
fingering diagrams, and chord names came along for the ride: they rendered at
less than half their size for anyone whose score had fingerings, which is
exactly the score a whistle player is looking at.

The rule this file enforces:

    How big a chord name is may not depend on anything else the score happens
    to carry. Our own drawn glyphs are scaled in our own pass, never by moving
    a global option that also sizes someone else's text.

Run: engine/.venv/bin/python engine/scripts/check_render.py
"""

import re
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "engine"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import verovio  # noqa: E402

from music21 import duration as m21duration  # noqa: E402
from music21 import expressions, tempo  # noqa: E402
from pypdf import PdfReader  # noqa: E402

import fixtures  # noqa: E402
from scoranger_engine import ops, render  # noqa: E402

FAILURES: list[str] = []

# The app's option set (VerovioRenderer.options), so what is measured here is
# what a user sees.
# page geometry comes from the renderer itself, so this measures the page a
# reader actually gets rather than a copy that drifted from it
APP_OPTIONS = {"scale": 45, "footer": "none",
               "pageMarginTop": 100, "pageMarginBottom": 100,
               "pageMarginLeft": 120, "pageMarginRight": 120,
               **render.page_options()}

CHORDS = [{"measure": 1, "symbol": "Em"}, {"measure": 5, "symbol": "D"},
          {"measure": 9, "symbol": "G"}]


def engrave(with_fingerings: bool, bars: int = 16):
    """Render a jig with chord symbols, optionally fingered, the app's way."""
    score = fixtures.jig(bars=bars)
    ops.set_chord_symbols(score, "#0", CHORDS)
    if with_fingerings:
        ops.whistle_fingerings(score, score.parts[0], "D")
    src = tempfile.mktemp(suffix=".musicxml")
    score.write("musicxml", fp=src)

    toolkit = verovio.toolkit()
    toolkit.setOptions({**APP_OPTIONS, "lyricSize": render.DEFAULT_LYRIC_SIZE})
    toolkit.loadFile(src)
    mei = toolkit.getMEI()
    above = render.mei_with_fingerings_above(mei)
    if above is not None:
        toolkit.setOptions({**APP_OPTIONS,
                            "lyricSize": render.lyric_size_for(fingerings=True)})
        toolkit.loadData(above)
    svg = toolkit.renderToSVG(1)
    return svg, render._fingering_diagrams(svg)


def sizes(svg: str, css_class: str) -> list[float]:
    """Font sizes of the text inside one class of element."""
    return sorted({float(s) for s in re.findall(
        rf'class="{css_class}".{{0,400}}?<tspan font-size="([\d.]+)px"', svg, re.S)})


def radii(svg: str) -> list[float]:
    """Radii of the arcs our pass drew (the 'A r r' of each circle path)."""
    return sorted({round(float(r), 2) for r in re.findall(r'A ([\d.]+) \1 0 1 0', svg)})


plain_svg, _ = engrave(with_fingerings=False)
fing_svg, drawn = engrave(with_fingerings=True)

# -- the regression itself ----------------------------------------------------
plain_chords, fing_chords = sizes(plain_svg, "harm"), sizes(fing_svg, "harm")
if not plain_chords:
    FAILURES.append("no chord symbols found in the fixture -- the check is not measuring anything")
elif plain_chords != fing_chords:
    FAILURES.append(
        f"chord-name size depends on whether the score has fingerings: "
        f"{plain_chords} without, {fing_chords} with")

# -- and chord names are at the engraving's full text size ---------------------
verse_sizes = sizes(fing_svg, "verse")
if not verse_sizes:
    FAILURES.append("no fingering verses found -- the check is not measuring anything")
elif fing_chords and verse_sizes != fing_chords:
    FAILURES.append(f"chord names ({fing_chords}) and verses ({verse_sizes}) should share the "
                    "engraving's one text size; the diagrams are scaled in our own pass")

# -- the diagram is small and tightly stacked, and the circles are not --------
#
# Ali asked for the column to lose about half its footprint while each hole got
# BIGGER -- just under a notehead. Those pull against each other, so both are
# measured here, off the drawn output rather than off the constants.

# how the rows are spaced, measured from the circles actually drawn
centres = [(float(x), float(y)) for x, y in
           re.findall(r'<path d="M ([-\d.]+) ([-\d.]+) A', drawn)]
columns: dict[float, list[float]] = {}
for x, y in centres:
    columns.setdefault(round(x, 1), []).append(y)
pitches = sorted({round(b - a)
                  for ys in columns.values()
                  for a, b in zip(sorted(ys), sorted(ys)[1:]) if b > a})

drawn_radii = radii(drawn)
if not drawn_radii:
    FAILURES.append("our pass drew no circles")
if len(drawn_radii) > 1:
    FAILURES.append(f"the holes are not all one size: {drawn_radii}")

# the pitch Verovio laid the verses out at, before we re-placed them
original = [(float(x), float(y)) for x, y in
            re.findall(r'class="verse".{0,400}?<text[^>]*?x="([-\d.]+)"[^>]*?y="([-\d.]+)"',
                       fing_svg, re.S)]
orig_columns: dict[float, list[float]] = {}
for x, y in original:
    orig_columns.setdefault(round(x, 1), []).append(y)
orig_pitches = sorted({round(b - a)
                       for ys in orig_columns.values()
                       for a, b in zip(sorted(ys), sorted(ys)[1:]) if b > a})

if pitches and orig_pitches:
    shrunk = pitches[0] / orig_pitches[0]
    if not 0.40 <= shrunk <= 0.50:
        FAILURES.append(
            f"the column is {shrunk:.0%} of the spacing Verovio laid out "
            f"({pitches[0]} from {orig_pitches[0]}); it was asked to be 40-50%")

# and the holes themselves are just under a notehead, which is what stops
# "smaller overall" from turning into "too small to read"
if drawn_radii and pitches:
    notehead = orig_pitches[0] * render.NOTEHEAD_PER_ROW_PITCH
    fraction = (drawn_radii[0] * 2) / notehead
    if not 0.65 <= fraction < 1.0:
        FAILURES.append(
            f"a hole is {fraction:.0%} of a notehead ({drawn_radii[0]*2:.0f} of "
            f"{notehead:.0f}); it should be a little under one")
    # ...and bigger than the diagrams shipped at, which is the other half of
    # the request and the easy thing to lose while shrinking the column
    was = render.HOLE_RADIUS * render.DIAGRAM_SCALE * (verse_sizes[0] if verse_sizes else 0)
    if was and drawn_radii[0] <= was:
        FAILURES.append(
            f"the holes got smaller, not bigger: {drawn_radii[0]:.1f} vs {was:.1f}")

# A column belongs to ONE note: six holes, plus the octave "+" at most.
#
# Grouping rows by "y keeps increasing" alone merged the last column of a
# system with the first of the next -- whose y is larger still, simply because
# it is further down the page -- and the merged column was re-placed from the
# first system's anchor, leaving a stack of circles floating in the gap between
# the two systems, under no note at all.
oversized = {round(x, 1): len(ys) for x, ys in columns.items() if len(ys) > 6}
if oversized:
    FAILURES.append(
        f"columns with more than six holes: {oversized} -- rows from different "
        "notes have been grouped together")

# the circles must not touch or overlap once the rows are tightened
if drawn_radii and pitches and pitches[0] <= drawn_radii[0] * 2:
    FAILURES.append(
        f"the holes overlap: pitch {pitches[0]} with diameter {drawn_radii[0]*2:.0f}")

# -- the octave "+" is part of the diagram and moves and scales with it --------
plus = sorted({float(s) for s in re.findall(r'<tspan font-size="([\d.]+)px">\+</tspan>', drawn)})
if not plus:
    FAILURES.append("no octave '+' in a fingered second-octave jig -- nothing to check")
elif drawn_radii:
    want_plus = drawn_radii[0] * 2 * render.OCTAVE_MARK_VS_DIAMETER
    if not any(abs(p - want_plus) < 1.0 for p in plus):
        FAILURES.append(f"the octave '+' renders at {plus}; sized from the circles beside it "
                        f"it should be {want_plus:.1f}")

# -- the column HUGS ITS STAFF, and the "+" sits under it ---------------------
#
# Both of Ali's fingering bugs are about WHERE the redrawn column lands, so
# both are measured in one frame: the circle centres our pass actually drew,
# against the verse positions Verovio laid out, converted into that same frame
# by the offsets `_draw_hole` applies.
#
# Getting the frame right is the whole check. A first draft compared the drawn
# circles' path start -- which is the LEFT EDGE, not the centre -- against the
# raw verse x, and the two never matched: every assertion quietly skipped and
# the file stayed green with both fixes reverted.
R = drawn_radii[0] if drawn_radii else 0.0
if R > 0:
    def frame(x: float, y: float) -> tuple[float, float]:
        """A verse's laid-out position, as the circle centre it becomes."""
        return (x + render.HOLE_CENTRE_X_VS_RADIUS * R,
                y - render.HOLE_CENTRE_Y_VS_RADIUS * R)

    drawn_cols: dict[float, list[float]] = {}
    for x, y in centres:  # a circle path starts at its left edge
        drawn_cols.setdefault(round(x + R, 1), []).append(y)

    # Only the holes: the "+" is a different glyph, and Verovio places each
    # verse on its own width, so its x is not the column's.
    rows = re.findall(
        r'class="verse".{0,600}?<text[^>]*?x="([-\d.]+)"[^>]*?y="([-\d.]+)"'
        r'.{0,400}?>([^<]{1,3})<', fing_svg, re.S)
    orig_cols: dict[float, list[float]] = {}
    for x, y, glyph in rows:
        if glyph not in ("X", "O", "/"):
            continue
        cx, cy = frame(float(x), float(y))
        orig_cols.setdefault(round(cx, 1), []).append(cy)

    if not orig_cols:
        FAILURES.append("no laid-out hole verses to measure the column against")
    paired = 0
    for cx, ys in drawn_cols.items():
        near = [k for k in orig_cols if abs(k - cx) <= R / 2]
        if not near or len(ys) < 2:
            continue
        was = orig_cols[min(near, key=lambda k: abs(k - cx))]
        if len(was) < 2:
            continue
        paired += 1
        # anchored at the BOTTOM: its lowest hole stays where Verovio put the
        # lowest verse. Anchored at the top instead -- which is what put the
        # gap in Ali's screenshot -- the whole column rises by the height it
        # saved, five row pitches' worth.
        if max(ys) < max(was) - R:
            FAILURES.append(
                f"the column at x={cx:.0f} pulled AWAY from its staff: lowest "
                f"hole at {max(ys):.0f} where the verse it replaces sat at "
                f"{max(was):.0f}. Anchor the column at its bottom row.")
        # and it only ever got shorter, so the top moved DOWN, never up toward
        # the system above
        if min(ys) < min(was) - R:
            FAILURES.append(
                f"the column at x={cx:.0f} grew upward toward the system "
                f"above: top {min(ys):.0f} vs {min(was):.0f}")
    if paired < 3:
        FAILURES.append(
            f"only {paired} columns could be paired with their verses -- the "
            "hug check is not measuring anything")

    # -- and the octave "+" is centred on the column's own axis ---------------
    #
    # A hole becomes a circle whose centre is offset from the verse anchor, so
    # a "+" left at its raw anchor hangs a full offset to one side; and because
    # Verovio centres it on ITS glyph width, its raw anchor is not even the
    # holes' anchor -- two notes in this fixture are a further 37 units out.
    plus_marks = re.findall(
        r'<text[^>]*?x="([-\d.]+)"[^>]*>(?:(?!</text>).)*?>\+<', drawn, re.S)
    if not plus_marks:
        FAILURES.append("no octave '+' found to check for centring")
    for raw in plus_marks:
        px = float(raw)
        axis = min(drawn_cols, key=lambda c: abs(c - px))
        # a quarter of a hole: visibly under the column, not merely near it
        if abs(px - axis) > R / 4:
            FAILURES.append(
                f"the octave '+' at x={px:.0f} is not on its column's axis at "
                f"x={axis:.0f} (off by {abs(px - axis):.0f}, tolerance "
                f"{R / 4:.0f})")

# -- every diagram in a row sits on ONE baseline (#43) -------------------------
#
# Ali circled these through Morrison's Jig: within a single row above the
# staff, some diagrams sat higher and some lower than their neighbours. A
# column was anchored on its LAST ROW, and a column's last row is the octave
# "+" when it has one -- so every fingered-octave note hung a whole lyric pitch
# below the notes either side of it.
#
# Verovio lays every verse of a system on one baseline, so the test is simple:
# group the drawn columns into systems by their own vertical position, and
# every column in a system must have its lowest HOLE at the same height.
if drawn_cols:
    by_system: dict[int, list[float]] = {}
    for cx, ys in drawn_cols.items():
        bottom = max(ys)
        # a system is a band: columns of one system differ by rounding, not by
        # a row pitch, and the next system is a page-section away
        key = next((k for k in by_system if abs(k - bottom) < R * 4), None)
        by_system.setdefault(key if key is not None else int(bottom), []).append(bottom)
    for system, bottoms in by_system.items():
        spread = max(bottoms) - min(bottoms)
        if spread > 2.0:
            FAILURES.append(
                f"the diagrams in the system near y={system} do not share a "
                f"baseline: their lowest holes span {spread:.0f} units "
                f"({len(bottoms)} columns, {min(bottoms):.0f}..{max(bottoms):.0f})")
    check_count = sum(len(b) for b in by_system.values())
    if check_count < 4:
        FAILURES.append(
            f"only {check_count} columns to compare -- the baseline check is "
            "not measuring anything")

# -- the marks the APP's path got wrong, pinned on the EXPORT's path ---------
#
# Two faults were found in the iPad's renderer in 0.8.2: a tempo mark's digits
# drawn at the size of the music glyph beside them, and Verovio's own italics
# and bolds ignored outright. Neither was ever wrong here -- cairosvg reads the
# per-tspan sizes and the stylesheet that the app's SwiftDraw path cannot --
# and this is what says so, so that a future rewrite of `_sanitize_svg` cannot
# quietly bring them across.
marks = fixtures.jig(bars=8)
marks_bar = marks.parts[0].measure(1)
marks_bar.insert(0.0, tempo.MetronomeMark(number=138,
                                          referent=m21duration.Duration(1.5)))
marks_bar.insert(1.5, expressions.TextExpression("dolce"))
marks_src = tempfile.mktemp(suffix=".musicxml")
marks.write("musicxml", fp=marks_src)
marks_pdf = tempfile.mktemp(suffix=".pdf")
render.render_pdf(marks_src, marks_pdf)
faces = {str(font.get("/BaseFont")).split("+")[-1]
         for font in (PdfReader(marks_pdf).pages[0]["/Resources"].get("/Font") or {}).values()}
for face in ("Times-Italic", "Times-Bold"):
    if face not in faces:
        FAILURES.append(f"the exported PDF has no {face}: Verovio's stylesheet "
                        f"stopped reaching the page (it has {sorted(faces)})")

marks_toolkit = verovio.toolkit()
marks_toolkit.setOptions({**APP_OPTIONS, "lyricSize": render.DEFAULT_LYRIC_SIZE})
marks_toolkit.loadFile(marks_src)
tempo_block = re.search(r'<g[^>]*class="tempo".*?</g>',
                        render._sanitize_svg(marks_toolkit.renderToSVG(1)), re.S)
if tempo_block is None:
    FAILURES.append("no tempo mark was engraved at all")
else:
    tempo_sizes = {float(v) for v in
                   re.findall(r'font-size="([\d.]+)px"', tempo_block.group(0))
                   if float(v) > 0}
    if len(tempo_sizes) < 2:
        FAILURES.append(
            f"the tempo mark came out at one size ({sorted(tempo_sizes)}): the "
            "glyph and the digits are engraved at different sizes and the "
            "export must keep them apart")

# 0.18.2: the tempo mark's NOTE is a character in Verovio's music font, which
# cairosvg cannot load, so the PDF drew a box -- "[] = 80". The export draws a
# leading music glyph as its outline and moves the words along by its width.
drawn = render._draw_leading_music_glyphs(marks_toolkit.renderToSVG(1))
drawn_tempo = re.search(r'<g[^>]*class="tempo".*?</g>', drawn, re.S)
if drawn_tempo is None:
    FAILURES.append("no tempo mark after drawing its glyphs")
else:
    left = re.findall(r'<tspan font-family="Leipzig"[^>]*>([^<]+)</tspan>', drawn_tempo.group(0))
    if left:
        FAILURES.append(f"the tempo mark still hands cairosvg music-font characters "
                        f"{[hex(ord(c)) for c in ''.join(left)]}: they print as boxes")
    # "138", not "= ": Verovio sets the '=' between NO-BREAK spaces.
    if "<path" not in drawn_tempo.group(0) or "138" not in drawn_tempo.group(0):
        FAILURES.append("the tempo mark lost its note outline or its '= 138'")
    else:
        print("    ok   the tempo note is drawn as an outline, the words moved along")

# -- a resized WORD reaches the exported page -------------------------------
#
# Measured in the PDF, not in the SVG, because the SVG pass and the export
# chain are two different things: `apply_lyric_sizes` was written, checked in
# isolation and not called from `render_pdf` at first, which is the same fault
# `mei_with_element_adjustments` had -- an adjustment that showed on screen
# and vanished from the export.
#
# cairosvg writes a glyph run's size into its text matrix and leaves `Tf` at
# 1, so the first number of the Tm IS the point size of the word that follows.
_PDF_WORD = re.compile(rb"BT\n([\d.-]+) 0 0 [\d.-]+ [\d.-]+ [\d.-]+ Tm\n"
                       rb"/[\w-]+ 1 Tf\n\((.*?)\)Tj", re.S)


def engraved_words(pdf_path):
    """Every text run on page 1 of a PDF, with the size it was drawn at."""
    data = PdfReader(pdf_path).pages[0].get_contents().get_data()
    return {m.group(2).decode("latin-1"): round(float(m.group(1)), 2)
            for m in _PDF_WORD.finditer(data)}


def sung_pdf(scale=None):
    from music21 import harmony

    score = fixtures.jig(bars=4)
    bar = score.parts[0].measure(2)
    note = next(n for n in bar.notes if not isinstance(n, harmony.Harmony))
    note.lyric = "la"
    if scale is not None:
        ops.adjust_element(score, "#0", kind="lyric", measure=2, scale=scale)
    src = tempfile.mktemp(suffix=".musicxml")
    score.write("musicxml", fp=src)
    out = tempfile.mktemp(suffix=".pdf")
    render.render_pdf(src, out)
    return engraved_words(out)


plain_page, big_page = sung_pdf(), sung_pdf(scale=2.0)
if "la" not in plain_page or "la" not in big_page:
    FAILURES.append(f"the word was not engraved in the PDF at all: "
                    f"{sorted(plain_page)} then {sorted(big_page)}")
else:
    grew = big_page["la"] / plain_page["la"]
    if not 1.9 <= grew <= 2.1:
        FAILURES.append(
            f"--scale 2 on a lyric engraved at {big_page['la']}pt against "
            f"{plain_page['la']}pt ({grew:.2f}x): the size is in the notation "
            "but render_pdf is not carrying it to the page")
    if plain_page.get("Pennywhistle") != big_page.get("Pennywhistle"):
        FAILURES.append(
            "resizing one word changed the part name too "
            f"({plain_page.get('Pennywhistle')} -> "
            f"{big_page.get('Pennywhistle')}): the pass is matching more than "
            "the verse it was asked for")

if FAILURES:
    print(f"FAIL: {len(FAILURES)} rendering size check(s) failed")
    for line in FAILURES:
        print("   ", line)
    sys.exit(1)
print(f"OK: chord names are {fing_chords[0]:g}px with or without fingerings; "
      f"the fingering column is stacked at {pitches[0]} where Verovio laid out "
      f"{orig_pitches[0]} ({pitches[0]/orig_pitches[0]:.0%}), and each hole is "
      f"{drawn_radii[0]*2:.0f} across -- "
      f"{(drawn_radii[0]*2)/(orig_pitches[0]*render.NOTEHEAD_PER_ROW_PITCH):.0%} of a notehead")
