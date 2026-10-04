"""MusicXML -> PDF rendering: Verovio (engraving to SVG) + cairosvg + pypdf.

Pure-Python pipeline, no external apps. Chord-symbol accidentals use glyphs
from Verovio's music-text font, which cairosvg can't resolve — they are
substituted with plain 'b'/'#' before conversion.
"""

import io
from math import ceil
import re
import tempfile
import threading
from pathlib import Path

# Verovio's toolkit only reliably finds its font resources on first
# construction in a process — keep one instance, serialize access.
_tk = None
_tk_lock = threading.Lock()


# A page is a fixed size. US Letter portrait, because that is what the sources
# are: the sample PDFs in this repo measure 8.5x11 and 8.26x11.69, both portrait.
#
# This replaces `adjustPageHeight`, which trimmed each page to its own content.
# That was added in build 119 for a real reason -- without it Verovio pads every
# page to full height and a partly filled last page exports as a tall white
# void. But trimming means a page with less music on it is a SHORTER page, and
# Ali's two-page spread showed exactly that: the left page's bottom edge sitting
# higher than the right's. Paper does not do that. A partial page with white at
# the bottom is correct; pages of different heights never are.
#
# TWO different measurements, and conflating them cost a build.
#
#   - Verovio lays out in TENTHS OF A MILLIMETRE. Its own A4 default, 2100 x
#     2970, is 210mm x 297mm. US Letter is 215.9 x 279.4mm, so 2159 x 2794.
#     This is what decides how much music fits on a page.
#   - The PDF's physical size is set separately, when cairosvg renders the SVG.
#     Verovio emits the page as `units * scale/100` pixels, and cairosvg reads
#     pixels at 96 to the inch, so the two are only related through the scale
#     option -- change the scale and the paper would change size with it.
#
# The first version of this set the page to 816 x 1056, having measured the PDF
# and concluded there were 96 units to the inch. The PDFs came out 8.5x11 and
# the check passed, because that arithmetic is right for the OUTPUT and wrong
# for the LAYOUT: Verovio was being told the paper was 82 x 106mm, a page the
# size of a postcard, and a 90-bar jig came out over thirty pages of enormous
# notes. The check now asserts the pagination as well as the inches.
PAGE_WIDTH_TENTHS_MM = 2159   # 215.9mm
PAGE_HEIGHT_TENTHS_MM = 2794  # 279.4mm

# What the PDF is rendered at: 8.5 x 11 inches, in cairosvg's pixels-at-96-dpi.
PDF_WIDTH_PX = 816
PDF_HEIGHT_PX = 1056


# --- staff spacing, per score -----------------------------------------------
#
# How much room the page gives between staves, between systems, and to a
# whistle's fingering column. Set by `ops.staff_spacing`, stored in the
# notation as <miscellaneous-field name="scoranger-spacing"> so it versions and
# travels like everything else, and read here and in
# ios/Scoranger/ScoreModel/StaffSpacing.swift, which must stay in step.
#
# Why a field rather than MusicXML's own <staff-layout>/<system-layout>:
# music21 writes those correctly and Verovio IGNORES them, at every value --
# measured, not assumed. Spacing is a Verovio OPTION, so it has to be carried
# to the renderer by us.
#
# STAFF and SYSTEM are Verovio's `spacingStaff`/`spacingSystem`, in MEI units,
# and both are MINIMUMS: they open space up, and cannot take back space the
# music itself claims. That is why the whistle band needs its own control.
SPACING_FIELD = "scoranger-spacing"
DEFAULT_SPACING_STAFF = 12        # Verovio's own defaults, named so a score
DEFAULT_SPACING_SYSTEM = 4        # that sets neither is laid out as before
SPACING_RANGE = (0, 48)           # Verovio's accepted range for both

# FINGERING ROWS: how many lyric rows Verovio reserves for a whistle column's
# six holes (the octave "+" gets one more, only on the notes that carry it).
# Verovio reserves one full lyric line per verse, and the column is then drawn
# at 47.5% of that pitch (HOLE_PITCH_RATIO) -- so six rows reserved for a
# column that fills three left the top half of the band empty, and a whistle
# tune fitted a fraction of the lines a plain one does. Ali: "too much space
# above penny whistle tablatures". Six is the old layout exactly.
#
# FOUR is the floor, and it is a measurement, not a taste. Six holes drawn at
# HOLE_PITCH_RATIO span five tight pitches -- 950 units at the default -- above
# the last hole, and a reserved row is a full lyric pitch, 400. Three rows put
# the top hole 150 units above the top reserved row, into Verovio's margin
# toward the system above; check_render.py exists to refuse exactly that
# ("the column ... grew upward toward the system above"), and caught it. Four
# rows holds the whole column inside the band it reserved, and on a whistle
# tune with a guitar tab under it still takes two pages to one.
DEFAULT_FINGERING_ROWS = 4
FINGERING_ROWS_RANGE = (4, 6)
_SPACING_RE = re.compile(
    r'<miscellaneous-field[^>]*name="' + SPACING_FIELD + r'"[^>]*>([^<]*)</miscellaneous-field>')


def spacing_from_musicxml(text: str) -> dict:
    """The score's spacing, or the defaults for anything it does not set.

    Lenient on the way in -- a hand-edited field or one from a later build must
    not stop a page from drawing -- so an unreadable or out-of-range value falls
    back to its default rather than raising. `ops.staff_spacing` is the strict
    side and refuses a bad value by name before it is ever written.
    """
    match = _SPACING_RE.search(text or "")
    return parse_spacing_value(match.group(1) if match else "")


def parse_spacing_value(value: str) -> dict:
    """The field's own text -- "staff=12;system=4;rows=3" -- as a spacing dict.

    Shared by the renderer, which reads it out of a MusicXML file, and by
    `ops.staff_spacing`, which reads it off a parsed score: one parser, so the
    op cannot write something the page reads differently.
    """
    out = {"staff": DEFAULT_SPACING_STAFF, "system": DEFAULT_SPACING_SYSTEM,
           "rows": DEFAULT_FINGERING_ROWS}
    for part in (value or "").split(";"):
        key, _, raw = part.partition("=")
        key = key.strip()
        if key not in out:
            continue
        try:
            number = int(raw.strip())
        except ValueError:
            continue
        lo, hi = FINGERING_ROWS_RANGE if key == "rows" else SPACING_RANGE
        if lo <= number <= hi:
            out[key] = number
    return out


# MEASURE NUMBERS: where the page numbers its bars, written by
# `ops.measure_numbers` as <miscellaneous-field name="scoranger-measure-numbers">
# and read here and in ios/Scoranger/ScoreModel/MeasureNumbers.swift, which
# must stay in step (check_measure_numbers.py holds the two together).
#
#   (no field)   the engraver's default: the first bar of every line but the
#                first. Verovio's `mnumInterval` 0.
#   every=N      every Nth bar -- `mnumInterval` N, which numbers the bars
#                whose number divides by N (every=1 is every bar).
#   none         no numbers at all. Verovio has no OPTION for that: it reads
#                MEI's `mnum.visible="false"` on the score definition, so the
#                renderers write that attribute onto the MEI and reload.
#
# The interval is a Verovio option, so it is named in EVERY option set for the
# reason spacing is: setOptions merges, and one score's numbering would
# otherwise be the next score's.
MEASURE_NUMBERS_FIELD = "scoranger-measure-numbers"
MEASURE_NUMBERS_EVERY_RANGE = (1, 64)          # Verovio's accepted mnumInterval
_MEASURE_NUMBERS_RE = re.compile(
    r'<miscellaneous-field[^>]*name="' + MEASURE_NUMBERS_FIELD
    + r'"[^>]*>([^<]*)</miscellaneous-field>')


def parse_measure_numbers(value: str) -> tuple[str, int]:
    """The field's text as (mode, every): ("system", 0), ("every", N), ("none", 0).

    Lenient, like the spacing parser: anything unreadable is the default rather
    than a page that will not draw. `ops.measure_numbers` is the strict side.
    """
    text = (value or "").strip()
    if text == "none":
        return ("none", 0)
    key, _, raw = text.partition("=")
    if key.strip() == "every":
        try:
            n = int(raw.strip())
        except ValueError:
            return ("system", 0)
        lo, hi = MEASURE_NUMBERS_EVERY_RANGE
        if lo <= n <= hi:
            return ("every", n)
    return ("system", 0)


def measure_numbers_from_musicxml(text: str) -> tuple[str, int]:
    match = _MEASURE_NUMBERS_RE.search(text or "")
    return parse_measure_numbers(match.group(1) if match else "")


def measure_number_options(numbering: tuple[str, int]) -> dict:
    """Verovio's `mnumInterval` for a numbering. Named every time; see above."""
    mode, every = numbering
    return {"mnumInterval": every if mode == "every" else 0}


def mei_with_measure_numbers_hidden(mei: str) -> str | None:
    """`mnum.visible="false"` on the first score definition, or None if it is
    already there. Verovio draws no bar number at all under it."""
    match = re.search(r"<scoreDef\b[^>]*>", mei)
    if match is None or 'mnum.visible="false"' in match.group(0):
        return None
    tag = match.group(0)
    tag = re.sub(r'\smnum\.visible="[^"]*"', "", tag)
    opened = tag[:-2] + ' mnum.visible="false"/>' if tag.endswith("/>") \
        else tag[:-1] + ' mnum.visible="false">'
    return mei[:match.start()] + opened + mei[match.end():]


#: Mirrors ops.PAGINATION_FIELD -- the mark a reader's own pagination carries.
PAGINATION_FIELD = "scoranger-pagination"
_PAGINATION_RE = re.compile(
    r'<miscellaneous-field[^>]*name="' + PAGINATION_FIELD + r'"[^>]*>\s*reader\s*</miscellaneous-field>')


def breaks_for(text: str) -> str:
    """Verovio's `breaks` for this score: `line` if the READER paginated it.

    `line`, not `encoded` (0.17.0): `encoded` breaks pages ONLY where the
    notation says, and a reader's pagination writes line breaks and no page
    breaks -- so through 0.16.0 every line of a long paginated score was drawn
    on ONE page, running off its foot (the 167-bar quartet: 35 systems on one
    sheet). `line` keeps the encoded LINE breaks and lets Verovio turn the
    pages: the same quartet is 12 pages of the lines the reader asked for.

    Measured: `auto` ignores encoded breaks outright and `encoded` breaks only
    where the notation says. A score's breaks are honoured only when they are
    the reader's -- a file from MuseScore, Finale, Sibelius or Audiveris carries
    its SOURCE EDITION's layout, made for another page, and honouring that took
    the string-quartet fixture from 8 pages to its publisher's 4 at eight and a
    half bars a line. Unmarked, a score lays out as it always has.
    """
    return "line" if _PAGINATION_RE.search(text or "") else "auto"


def spacing_options(spacing: dict) -> dict:
    """The Verovio options a spacing dict turns into. EVERY key, every time.

    `setOptions` merges rather than replaces, and the toolkit is shared: a
    score that asked for wide staves would otherwise leave them wide for the
    next score, which asked for nothing. The same trap took pagination away
    from every paged engrave after one visit to the continuous strip.
    """
    return {"spacingStaff": spacing["staff"], "spacingSystem": spacing["system"]}


def page_options() -> dict:
    """The page geometry both renderers use. Mirrored in EngravingOptions.swift.

    `justifyVertically` spreads the systems down the sheet instead of stacking
    them from the top and leaving the remainder blank. It is here as well as on
    the iPad so an exported PDF is the page the reader was looking at: measured
    on the string quartet, a page carrying two systems went from 38% blank at
    the foot to 18%.
    """
    return {"adjustPageHeight": False,
            "justifyVertically": True,
            # `auto` for every score the reader has NOT paginated -- which is
            # the layout every build has drawn -- and `encoded` only for one
            # they have: `breaks_for` decides it, from the notation, per file.
            # Mirrored in EngravingOptions.breaks(continuous:readerPaginated:);
            # check_pagination.py holds the two together.
            "breaks": "auto",
            # Named here at their defaults so a score that sets no spacing is
            # laid out at the defaults -- not at whatever the last score asked
            # for, which is what a merged option set left unnamed would give.
            **spacing_options({"staff": DEFAULT_SPACING_STAFF,
                               "system": DEFAULT_SPACING_SYSTEM,
                               "rows": DEFAULT_FINGERING_ROWS}),
            # and the default numbering, for the same reason
            **measure_number_options(("system", 0)),
            "pageWidth": PAGE_WIDTH_TENTHS_MM,
            "pageHeight": PAGE_HEIGHT_TENTHS_MM}


def _toolkit():
    global _tk
    if _tk is None:
        import verovio
        _tk = verovio.toolkit()
        # Passed as a dict -- this binding rejects the JSON-string form
        # setOptions also accepts.
        _tk.setOptions(page_options())
    return _tk


# MUSIC GLYPHS AT THE START OF A TEXT, AS OUTLINES. A tempo mark is
# `<text><tspan font-family="Leipzig">\uECA5</tspan> = 80</text>` -- the note is
# a character in Verovio's music font, which cairosvg cannot load, so the PDF
# drew a box where the note goes ("[] = 80", found taking the App Store
# screenshots). Verovio ships every glyph's outline in data/Leipzig/<HEX>.xml
# and its advance in data/Leipzig.xml (1000 units to the em), so the leading
# glyphs are drawn as paths at the text's start and the words after them are
# moved along by the glyphs' width: the spacing Verovio laid out is kept.
# Only LEADING glyphs: one inside a run of words has no position of its own
# to draw at. Chord-symbol accidentals are `_sanitize_svg`'s, which runs after.
_TEXT_BLOCK_RE = re.compile(r'<text([^>]*[^/])>((?:(?!<text[^>]*>).)*?)</text>', re.S)
_LEADING_GLYPHS_RE = re.compile(
    r'^((?:\s|<tspan[^>]*>)*)<tspan font-family="Leipzig" font-size="([\d.]+)px">'
    r'([^<]+)</tspan>')
_glyph_cache: dict = {}


def _leipzig_glyph(ch: str):
    """(path d, advance in font units) for one Leipzig character, or None.
    A space has an advance and no outline: d is "" and nothing is drawn."""
    if ch in _glyph_cache:
        return _glyph_cache[ch]
    import verovio
    data = Path(verovio.__file__).parent / "data"
    code = f"{ord(ch):04X}"
    outline = data / "Leipzig" / f"{code}.xml"
    found = None
    if outline.exists():
        d = re.search(r' d="([^"]+)"', outline.read_text())
        adv = re.search(rf'<g c="{code}"[^>]* h-a-x="([\d.]+)"',
                        (data / "Leipzig.xml").read_text())
        if adv:
            found = (d.group(1) if d else "", float(adv.group(1)))
    _glyph_cache[ch] = found
    return found


def _draw_leading_music_glyphs(svg: str) -> str:
    def block(m):
        attrs, body = m.group(1), m.group(2)
        lead = _LEADING_GLYPHS_RE.match(body)
        x = re.search(r'\bx="([-\d.]+)"', attrs)
        y = re.search(r'\by="([-\d.]+)"', attrs)
        if not (lead and x and y):
            return m.group(0)
        glyphs = [_leipzig_glyph(ch) for ch in lead.group(3)]
        if any(g is None for g in glyphs):
            return m.group(0)
        size = float(lead.group(2))
        scale = size / 1000.0
        x0, y0 = float(x.group(1)), float(y.group(1))
        paths, at = [], 0.0
        for d, advance in glyphs:
            if d:
                paths.append(f'<path transform="translate({_svg_number(at)},0) scale(1,-1)" d="{d}"/>')
            at += advance
        drawn = (f'<g transform="translate({_svg_number(x0)},{_svg_number(y0)}) '
                 f'scale({scale:g})">' + "".join(paths) + '</g>')
        body = body[:lead.start(3)] + body[lead.end(3):]
        attrs = attrs[:x.start(1)] + _svg_number(x0 + at * scale) + attrs[x.end(1):]
        return f'<text{attrs}>{body}</text>{drawn}'
    return _TEXT_BLOCK_RE.sub(block, svg)


# Verovio text-font glyphs (U+EA6x) and plain unicode accidentals -> ASCII
ACCIDENTAL_TEXT = {
    "": "b", "♭": "b",   # flat
    "": "#", "♯": "#",   # sharp
    "": "", "♮": "",     # natural
    "": "b", "": "#", "": "",  # SMuFL fallbacks
}

_MUSIC_TSPAN = re.compile(
    r'<tspan font-family="(?:Leipzig|VerovioText)"[^>]*?'
    r'font-size="(\d+)(?:\.\d+)?px"[^>]*>(.)</tspan>')


def _sanitize_svg(svg: str) -> str:
    """Replace music-font accidental glyphs in chord-symbol text with b/#.

    The glyph tspans are oversized relative to the surrounding text
    (~16:9), so the substitute letter is scaled back down to match.
    """
    def sub(m):
        rep = ACCIDENTAL_TEXT.get(m.group(2))
        if rep is None:
            return m.group(0)
        size = int(round(int(m.group(1)) * 0.5625))
        return f'<tspan font-size="{size}px">{rep}</tspan>'

    svg = _MUSIC_TSPAN.sub(sub, svg)
    for ch, rep in ACCIDENTAL_TEXT.items():
        svg = svg.replace(ch, rep)
    return svg


def _style_chart_svg(svg: str, harm_staves: set[int], grey: str = "#8f8f8f") -> str:
    """Chart cosmetics Verovio can't express: sans-serif bold chord names and
    grey staff furniture on chord-symbol staves.

    Staff-line paths carry no explicit stroke/fill, so attributes set on the
    n-th `g.staff` group of each measure inherit down; harm text lives in its
    own groups and stays black.
    """
    svg = re.sub(r'(<g\b[^>]*class="harm"[^>]*)>',
                 r'\1 font-family="Helvetica, Arial, sans-serif">', svg)
    if not harm_staves:
        return svg
    out = []
    pos = 0
    staff_idx = 0
    for m in re.finditer(r'<g\b[^>]*class="(measure|staff)"[^>]*>', svg):
        if m.group(1) == "measure":
            staff_idx = 0
            continue
        staff_idx += 1
        if staff_idx in harm_staves:
            out.append(svg[pos:m.start()])
            out.append(m.group(0)[:-1] + f' stroke="{grey}" fill="{grey}" color="{grey}">')
            pos = m.end()
    out.append(svg[pos:])
    return "".join(out)


WHISTLE_TAG = "wf"
# five or six single X/O/ verses on one note is a fingering, tag or no tag
WHISTLE_COLUMN = 5
_VERSE_RE = re.compile(r'<g[^>]*class="verse">.*?</g>\s*</g>', re.S)
_SYMBOL_RE = re.compile(r'>([XO/])</tspan>')
_X_RE = re.compile(r'<text x="([-\d.]+)"')
_Y_RE = re.compile(r'<text[^>]*y="([-\d.]+)"')
_SIZE_RE = re.compile(r'<tspan font-size="([\d.]+)px">')
_TEXT_RE = re.compile(r"<text.*?</text>", re.S)
_LABEL_RE = re.compile(r'<title class="labelAttr">([^<]*)</title>')
_ANY_SYL_RE = re.compile(r'>([^<>]{1,3})</tspan>')


# Fingerings sit above the staff, and small. Verovio ignores MusicXML's
# lyric placement="above", but honours MEI's place attribute on <verse>, so the
# move happens on the MEI round trip.
#
# The SIZE is ours to decide, not Verovio's. `lyricSize` is a single
# document-wide text size and it governs <harm> chord symbols as well as lyric
# verses, so halving it to shrink the diagrams also halved every chord name on
# the page -- unreadable, on exactly the scores a whistle player uses. So the
# option stays at its default and the diagrams are scaled here, in the pass
# that draws them. DIAGRAM_SCALE is the same 2.2-in-4.5 the diagrams shipped
# at, expressed where it belongs.
DEFAULT_LYRIC_SIZE = 4.5          # Verovio's default, in MEI units
DIAGRAM_SCALE = 2.2 / 4.5         # what the diagrams were shrunk to, ~0.49
# The point size a chord symbol engraves at when nobody has adjusted it, so a
# stored absolute size can be expressed as a ratio of the engraved glyph.
DEFAULT_CHORD_POINTS = 12.0

# Circle geometry as proportions of the verse glyph they replace, before the
# diagram scale is applied. Mirrored in ios/Scoranger/FingeringDiagrams.swift.
HOLE_CENTRE_X = 0.36              # half a glyph advance
HOLE_CENTRE_Y = -0.35             # above the text baseline
HOLE_RADIUS = 0.28
HOLE_STROKE = 0.07

# --- how big the diagram is, and how tightly it is stacked -------------------
#
# Circle size and row spacing are set SEPARATELY, because Ali wants the column
# much smaller overall while each circle gets slightly bigger. Both used to come
# from the verse's font size, so one could not move without the other.
#
# Everything is expressed against the row pitch Verovio itself laid out, which
# is the one number on the page that already scales with the staff. Measured on
# a real engraving at the default size: pitch 400 SVG units, notehead 217 wide
# (the stem sits at the notehead's right edge), drawn circle 111 across -- so a
# hole was about half a notehead, in a column 2000 units tall.
NOTEHEAD_PER_ROW_PITCH = 217 / 400        # a notehead, in units of row pitch

# A hole is a little smaller than a notehead: big enough to read at speed,
# still clearly not a note. 0.78 of a notehead is 169 units where the old one
# was 111 -- half as big again.
HOLE_DIAMETER_VS_NOTEHEAD = 0.78

# Rows sit at 47.5% of the pitch Verovio chose, which puts a six-hole column at
# 950 units where it was 2000: 47% of the footprint, inside the 40-50% asked
# for. The gap between circles stays about an eighth of a diameter, so they
# read as a stack of separate holes rather than a bar.
HOLE_PITCH_RATIO = 0.475

# The octave "+" stays text (every font has it, unlike the circle glyphs) but
# belongs to the column, so it is sized from the circle rather than the font.
OCTAVE_MARK_VS_DIAMETER = 0.85

# Centre offsets, now relative to the RADIUS rather than the font size, so they
# hold when the circle changes size. Both keep the ratios the old geometry had
# (0.36/0.28 and 0.35/0.28).
HOLE_CENTRE_X_VS_RADIUS = HOLE_CENTRE_X / HOLE_RADIUS
HOLE_CENTRE_Y_VS_RADIUS = -HOLE_CENTRE_Y / HOLE_RADIUS
HOLE_STROKE_VS_RADIUS = HOLE_STROKE / HOLE_RADIUS


def hole_geometry(row_pitch: float) -> tuple[float, float]:
    """(new row pitch, circle radius) for a column, from Verovio's own pitch.

    Pure, and the only place the two numbers are decided, so the on-device
    renderer can be held to the same answer -- see
    ios/Scoranger/FingeringDiagrams.swift and check_whistle.py.
    """
    notehead = row_pitch * NOTEHEAD_PER_ROW_PITCH
    return row_pitch * HOLE_PITCH_RATIO, notehead * HOLE_DIAMETER_VS_NOTEHEAD / 2


def lyric_size_for(fingerings: bool) -> float:
    """The text size to render at. One answer, whatever the score carries.

    Kept as a function because it used to return something smaller for fingered
    scores, and the whole point of the fix is that it no longer does. A caller
    that asks is told the default; a future caller that wants to shrink text
    has to come through here and read why not.
    """
    return DEFAULT_LYRIC_SIZE

# A chord carries the verses when the fingered note is part of one, so both
# element names have to be scanned — chord first, so its inner notes are not
# matched separately.
_MEI_NOTE_RE = re.compile(r"<(chord|note)\b[^>]*>.*?</\1>", re.S)
_MEI_VERSE_RE = re.compile(r"<verse\b[^>]*>.*?</verse>", re.S)
_MEI_SYL_RE = re.compile(r"<syl\b[^>]*>([^<]*)</syl>")


def _is_fingering_verse_set(verses: list[str]) -> bool:
    """Do these verses of one note form a fingering column?

    Same rule as the SVG pass: five or six single holes, with the octave "+"
    allowed alongside. Applied here so fingerings written before the `wf` tag
    existed move above the staff too.
    """
    holes = 0
    for verse in verses:
        syl = _MEI_SYL_RE.search(verse)
        text = (syl.group(1) if syl else "").strip()
        if text in ("X", "O", "/"):
            holes += 1
        elif text != "+":
            return False
    return holes >= WHISTLE_COLUMN


#: The label a PACKED column carries on its first verse: the tag, a bar, and
#: every row of the column in order ("wf|XXOOOO+"). Its other verses carry the
#: tag and the bar alone. `_unpack_fingering_columns` reads it back.
PACKED_PREFIX = WHISTLE_TAG + "|"
_MEI_N_RE = re.compile(r'\bn="\d+"')
_MEI_LABEL_RE = re.compile(r'\blabel="[^"]*"')
_MEI_SYL_TEXT_RE = re.compile(r"(<syl\b[^>]*>)([^<]*)(</syl>)")


def _pack_column(verses: list[str], rows: int) -> list[str] | None:
    """The same column, reserving `rows` lyric lines for its holes.

    Verovio gives every verse a full lyric line, and that is the space a
    whistle tune loses: six lines reserved for holes the draw pass then packs
    into half the height. Keeping only `rows` verses shrinks what Verovio
    reserves; the full pattern rides in the first verse's label so nothing is
    lost, and the SVG pass puts the rows back before the circles are drawn.

    The octave "+" keeps a line of its own below the holes, on the notes that
    have one -- exactly as today's six-or-seven works, which is what keeps
    every column's LAST HOLE on the same baseline across a system (the
    Morrison's Jig alignment fix).

    None when there is nothing to save: a column already this short, or one
    whose rows are not holes and an octave mark.
    """
    texts = []
    for verse in verses:
        syl = _MEI_SYL_RE.search(verse)
        texts.append((syl.group(1) if syl else "").strip())
    holes = [t for t in texts if t in ("X", "O", "/")]
    octave = texts[-1] == "+" if texts else False
    if len(holes) != len(texts) - (1 if octave else 0):
        return None
    if len(holes) <= rows:
        return None
    keep = rows + (1 if octave else 0)
    pattern = "".join(texts)
    packed = []
    for index, verse in enumerate(verses[:keep]):
        v = _MEI_N_RE.sub(f'n="{index + 1}"', verse, count=1)
        label = f'label="{PACKED_PREFIX}{pattern if index == 0 else ""}"'
        v = (_MEI_LABEL_RE.sub(label, v, count=1) if _MEI_LABEL_RE.search(v)
             else v.replace("<verse", f"<verse {label}", 1))
        # the last kept line is the octave's when there is one; its text only
        # has to reserve the line, since every row is redrawn
        text = "+" if (octave and index == keep - 1) else holes[index]
        v = _MEI_SYL_TEXT_RE.sub(lambda m, t=text: m.group(1) + t + m.group(3), v, count=1)
        packed.append(v)
    return packed


def mei_with_fingerings_above(mei: str, rows: int = DEFAULT_FINGERING_ROWS) -> str | None:
    """Mark fingering verses `place="above"`, and pack each column to `rows`
    lines. None when there are none.

    `rows` is the score's own setting, read by `spacing_from_musicxml`. Six is
    the layout every build before 0.13.0 drew.
    """
    if "<verse" not in mei:
        return None
    changed = False

    def one_note(match: "re.Match[str]") -> str:
        nonlocal changed
        block = match.group(0)
        verses = _MEI_VERSE_RE.findall(block)
        if len(verses) < WHISTLE_COLUMN:
            return block
        tagged = all('label="wf"' in v for v in verses)
        if not (tagged or _is_fingering_verse_set(verses)):
            return block
        changed = True
        above = [v if 'place=' in v.split(">")[0]
                 else v.replace("<verse", '<verse place="above"', 1)
                 for v in verses]
        packed = _pack_column(above, rows)
        if packed is None:
            packed = above
        # every verse of the note out, the column back in where the first was
        first = block.find(verses[0])
        stripped = block
        for v in verses:
            stripped = stripped.replace(v, "", 1)
        return stripped[:first] + "".join(packed) + stripped[first:]

    out = _MEI_NOTE_RE.sub(one_note, mei)
    return out if changed else None


# ADDED-ELEMENT ADJUSTMENTS. Verovio's MusicXML importer drops `font-size`,
# `relative-x` and `relative-y` from EVERY element that carries them -- a
# <harmony>, a <dynamics>, a <words>, a <fermata>, an articulation -- so the
# values a user set have to be carried across by hand: position into MEI
# @ho/@vo, which Verovio honours per element, and size into the SVG afterwards,
# because Verovio has no per-element text size at all (@fontsize is ignored as
# a percentage and as a keyword).
#
# This used to carry chord symbols alone, which is what `adjust-element` used
# to reach. It reaches five kinds now and so does this.
#
# WHICH WAY IS UP. MusicXML's relative-y measures UP and so does MEI's @vo, on
# every one of these elements -- measured, element by element, by engraving the
# same bar with and without an offset and reading the rendered y back
# (check_adjust.py does it as an assertion, not as a comment). The <harm> pass
# used to negate its own, on the belief that harm was the exception; it is not,
# and the consequence was that the app's "up" arrow moved a chord symbol DOWN.
#
# Mirrored in ios/Scoranger/ChordAdjustments.swift; keep the two in step.
_HARMONY_TAG_RE = re.compile(r"<harmony\b[^>]*>")
_HARM_MEI_RE = re.compile(r"<harm\b")
_DYNAMICS_TAG_RE = re.compile(r"<dynamics\b[^>]*>")
_FERMATA_TAG_RE = re.compile(r"<fermata\b[^>]*>")
_ARTICULATIONS_RE = re.compile(r"<articulations\b[^>]*>(.*?)</articulations>", re.S)
_ORNAMENTS_RE = re.compile(r"<ornaments\b[^>]*>(.*?)</ornaments>", re.S)
_ARTIC_CHILD_RE = re.compile(r"<([a-z-]+)\b([^>]*)/?>")
# A chord symbol's glyph carries x and y after its size, so the fingering-era
# pattern (which expects the tag to close right after font-size) never matches
# it. Same trap, different tag.
_CHORD_SIZE_RE = re.compile(r'(<tspan[^>]*font-size=")([\d.]+)(px")')
# MEI units are half-spaces; MusicXML tenths are tenths of a staff space.
_TENTHS_TO_HALF_SPACES = 0.2


def _three_numbers(tag: str) -> dict:
    """The size and the two offsets off one MusicXML open tag."""
    def number(attr):
        found = re.search(rf'{attr}="([-\d.]+)"', tag)
        return float(found.group(1)) if found else None
    return {"size": number("font-size"),
            "dx": number("relative-x"), "dy": number("relative-y")}


def _adjustment_tags(text: str, kind: str) -> list[str]:
    """The open tags of one kind of adjustable element, in document order.

    The order is the whole join: Verovio keeps its elements in the order it
    read them, so the nth <dynamics> in the file is the nth <dynam> in the MEI.
    """
    if kind == "harm":
        return _HARMONY_TAG_RE.findall(text)
    if kind == "dynamic":
        return _DYNAMICS_TAG_RE.findall(text)
    if kind == "text":
        # a chord DIAGRAM rides in a <words> too, and it is `diagram_adjustments`
        # that carries its three numbers -- a diagram is drawn by us, not by
        # Verovio, so it is adjusted in a different place entirely
        return [f"<words{attrs}>" for attrs, body in _WORDS_RE.findall(text)
                if CHORD_DIAGRAM_RE.search(body) is None]
    if kind == "fermata":
        return _FERMATA_TAG_RE.findall(text)
    if kind == "articulation":
        return [f"<{name}{attrs}>"
                for block in _ARTICULATIONS_RE.findall(text)
                for name, attrs in _ARTIC_CHILD_RE.findall(block)]
    if kind == "ornament":
        # An <ornaments> block holds <trill-mark>, <turn>, <mordent> and the
        # rest as children, exactly as <articulations> does -- and Verovio
        # emits one element per child in the same order, which is the join
        # the two functions below rely on.
        return [f"<{name}{attrs}>"
                for block in _ORNAMENTS_RE.findall(text)
                for name, attrs in _ARTIC_CHILD_RE.findall(block)]
    raise ValueError(f"no adjustment finder for element kind {kind!r}")


# kind -> the MEI element Verovio writes it as. `diagram` is absent on purpose:
# we draw those ourselves and `mei_with_chord_diagrams` places them.
# `ornament` is an ALTERNATION rather than one name: MusicXML's six ornament
# children become three different MEI elements (a schleifer arrives as a
# <mordent> carrying a glyph override), and there is no one tag that covers
# them. Both users below interpolate this into a regex, so a group is exactly
# as good as a literal.
ELEMENT_MEI_TAGS = {"harm": "harm", "dynamic": "dynam", "text": "dir",
                    "fermata": "fermata", "articulation": "artic",
                    "ornament": "(?:trill|turn|mordent)"}


def element_adjustments(musicxml_path, kind: str = "harm") -> list[dict]:
    """Each element of one kind, with its size and offset, in document order.

    Read straight from the file rather than from a parsed score: the renderer
    only needs three numbers per element, and the MEI it is matching against is
    in the same order.
    """
    try:
        text = Path(musicxml_path).read_text(encoding="utf-8")
    except OSError:
        return []
    return [_three_numbers(tag) for tag in _adjustment_tags(text, kind)]


def chord_adjustments(musicxml_path) -> list[dict]:
    """Each chord symbol's size and offset -- `element_adjustments`' first
    caller, kept under its own name because the app's side is spelled the
    same."""
    return element_adjustments(musicxml_path, "harm")


def chart_placements(musicxml_path) -> list[bool]:
    """Whether each chord symbol asks to sit ON the staff, in document order.

    `chart_style` records the Real Book intent in the notation --
    `placement="below"` and a `default-y` in tenths -- and this reads it back.
    Before this existed the renderer stamped the treatment onto EVERY score
    with a chord symbol, so a plain lead sheet came out of the PDF looking like
    a chart and out of the app looking like itself. Both renderers draw what
    the notation says now; neither decides.
    """
    try:
        text = Path(musicxml_path).read_text(encoding="utf-8")
    except OSError:
        return []
    return [bool(re.search(r'placement="below"', tag) and re.search(r'default-y=', tag))
            for tag in _HARMONY_TAG_RE.findall(text)]


def mei_with_chart_styling(mei: str, musicxml_path) -> str | None:
    """Put the Real Book treatment on the symbols that asked for it.

    Names on the staff, centred in the bar, bold -- but only where the notation
    carries the intent. Returns None when no symbol asks, so the caller can skip
    a Verovio reload.

    Mirrored in ios/Scoranger/ChordPlacement.swift; keep the two in step.
    """
    wants = chart_placements(musicxml_path)
    if not any(wants):
        return None

    meter = re.search(r'<meterSig[^>]*\bcount="(\d+)"', mei) or re.search(
        r'meter\.count="(\d+)"', mei)
    mid = ((int(meter.group(1)) + 1) / 2) if meter else None

    index = 0

    def style(match):
        nonlocal index
        tag = match.group(0)
        on_staff = wants[index] if index < len(wants) else False
        index += 1
        if not on_staff:
            return tag
        tag = re.sub(r'\s+place="[^"]*"', "", tag)
        tag = tag.replace("<harm", '<harm place="within"', 1)
        if mid is not None:
            tag = re.sub(r'tstamp="[^"]*"', f'tstamp="{mid:g}"', tag)
        return tag

    out = re.sub(r"<harm\b[^>]*>", style, mei)

    # bold only the ones that asked, so an unstyled neighbour keeps its weight
    index = 0

    def embolden(match):
        nonlocal index
        on_staff = wants[index] if index < len(wants) else False
        index += 1
        if not on_staff:
            return match.group(0)
        return (match.group(1)
                + f'<rend fontweight="bold" fontsize="150%">{match.group(2)}</rend>'
                + match.group(3))

    return re.sub(r"(<harm\b[^>]*>)([^<]+)(</harm>)", embolden, out)


def mei_with_deduped_rehearsals(mei: str) -> str:
    """Keep one rehearsal mark per bar in a COMBINED score.

    A rehearsal mark is written to every part, so an extracted part carries its
    own (see `ops.set_rehearsal`). Verovio renders the direction from each part
    and anchors them all to the same staff of a combined score, which draws the
    same letter over itself once per part. This keeps the first `<reh>` of each
    (measure, letter) and drops the rest.

    A single part has one of each already, so this is a no-op there -- which is
    the property that lets the same render path serve both.
    """
    kept: set[tuple[str, str]] = set()
    out: list[str] = []
    position = 0
    # <reh> carries its label in a child <rend>, so the whole element is taken
    for match in re.finditer(r"<reh\b[^>]*(?:/>|>.*?</reh>)", mei, re.S):
        element = match.group(0)
        measure = mei.rfind("<measure", 0, match.start())
        bar = re.search(r'\bn="([^"]*)"', mei[measure:measure + 200])
        label = re.sub(r"<[^>]+>", "", element).strip()
        key = (bar.group(1) if bar else str(measure), label)
        if key in kept:
            out.append(mei[position:match.start()])
            position = match.end()
            continue
        kept.add(key)
    out.append(mei[position:])
    return "".join(out)


def mei_with_element_adjustments(mei: str, musicxml_path) -> str | None:
    """Carry every added element's offset into the MEI, or None if none has one.

    Verovio honours @ho/@vo per element and drops MusicXML's relative-x/y, so
    this is the only route an adjustment has to the page. Both measure the same
    way round -- positive is right and UP -- on all five kinds; see the note
    above _HARMONY_TAG_RE for how that was established and what believing
    otherwise cost.
    """
    touched = False
    out = mei
    for kind, tag in ELEMENT_MEI_TAGS.items():
        adjustments = element_adjustments(musicxml_path, kind)
        if not any(a["dx"] is not None or a["dy"] is not None
                   for a in adjustments):
            continue
        index = 0

        def place(match, adjustments=adjustments):
            nonlocal index
            whole = match.group(0)
            if tag == "dir" and CHORD_DIAGRAM_RE.search(match.group(1) or ""):
                return whole          # a diagram marker: not ours to move
            adjustment = adjustments[index] if index < len(adjustments) else {}
            index += 1
            attrs = ""
            if adjustment.get("dx") is not None:
                attrs += f' ho="{adjustment["dx"] * _TENTHS_TO_HALF_SPACES:g}"'
            if adjustment.get("dy") is not None:
                attrs += f' vo="{adjustment["dy"] * _TENTHS_TO_HALF_SPACES:g}"'
            if not attrs:
                return whole
            if tag == "dir":
                head, rest = whole.split(">", 1)
                return f"{head}{attrs}>{rest}"
            return whole + attrs

        pattern = (re.compile(r"<dir\b[^>]*>([^<]*)") if tag == "dir"
                   else re.compile(rf"<{tag}\b"))
        out = pattern.sub(place, out)
        touched = True
    return out if touched else None


def mei_with_chord_adjustments(mei: str, musicxml_path) -> str | None:
    """The chord-symbol half of `mei_with_element_adjustments`, under the name
    the checks and the app's side have always used."""
    return mei_with_element_adjustments(mei, musicxml_path)


# How Verovio draws each kind, which decides how a size is applied to it.
# TEXT is a <tspan font-size>; a GLYPH is a <use> with a scale in its
# transform, and there is no other handle on its size at all.
ELEMENT_SVG_CLASSES = {"harm": ("harm", "text"), "text": ("dir", "text"),
                       "dynamic": ("dynam", "glyph"),
                       "fermata": ("fermata", "glyph"),
                       "articulation": ("artic", "glyph"),
                       # one <g> holding one <use> of the ornament glyph --
                       # a LEAF, like a fermata, and sized the same way
                       "ornament": ("(?:trill|turn|mordent)", "glyph")}

_USE_SCALE_RE = re.compile(r'(transform="translate\([^)]*\)\s*scale\()'
                           r'([\d.]+),\s*([\d.]+)(\))')


def _resize_text(block: str, ratio: float) -> str:
    """Grow or shrink the first sized tspan of a text block."""
    base = _CHORD_SIZE_RE.search(block)
    if not base or float(base.group(2)) <= 0:
        return block
    return _CHORD_SIZE_RE.sub(
        lambda m: f"{m.group(1)}{float(m.group(2)) * ratio:g}{m.group(3)}",
        block, count=1)


def _resize_glyph(block: str, ratio: float) -> str:
    """Grow or shrink a drawn glyph, about its own origin.

    A <use> carries `translate(x, y) scale(k, k)`, and the translate is the
    glyph's ANCHOR -- the note it hangs off, the baseline it sits on. Scaling
    the k's and leaving the translate alone therefore grows the mark without
    moving the point it is attached to, which is the only behaviour that keeps
    a resized fermata over its note.
    """
    return _USE_SCALE_RE.sub(
        lambda m: (f"{m.group(1)}{float(m.group(2)) * ratio:g}, "
                   f"{float(m.group(3)) * ratio:g}{m.group(4)}"),
        block)


def apply_element_sizes(svg: str, musicxml_path) -> str:
    """Rescale every adjusted element in the rendered SVG.

    Verovio has no per-element text size and no per-element glyph size, so
    this is the last place a size can be applied -- after the page is drawn.
    The stored value is a point size; what is applied is its RATIO to the
    engraved default, so the mark keeps its proportion at any page scale.

    A chord symbol's size lives on the INNER tspan; the enclosing <text> is
    font-size="0px", and reading that is what once gave every fingering circle
    a radius of zero.
    """
    out = svg
    for kind, (css, how) in ELEMENT_SVG_CLASSES.items():
        adjustments = element_adjustments(musicxml_path, kind)
        if not any(a["size"] is not None for a in adjustments):
            continue
        # A TEXT block is two groups deep (<g class><text><tspan>); a GLYPH
        # block is a LEAF -- one <g> holding one <use>. Reading a leaf with
        # the text pattern runs past its own </g> and into the next element's
        # drawing, which is how a resized dynamic would have scaled the
        # notehead beside it.
        pattern = (rf'<g[^>]*class="{css}".*?</g>\s*</g>' if how == "text"
                   else rf'<g[^>]*class="{css}"[^>]*>(?:(?!<g\b).)*?</g>')
        blocks = [b for b in re.finditer(pattern, out, re.S)
                  # a chord DIAGRAM is a <dir> too, and it is sized by the
                  # label `mei_with_chord_diagrams` writes, not here
                  if not (css == "dir" and CHORD_DIAGRAM_RE.search(b.group(0)))]
        if not blocks:
            continue
        pieces, cursor = [], 0
        for index, block in enumerate(blocks):
            pieces.append(out[cursor:block.start()])
            body = block.group(0)
            wanted = adjustments[index]["size"] if index < len(adjustments) else None
            if wanted is not None:
                ratio = float(wanted) / DEFAULT_CHORD_POINTS
                body = (_resize_text(body, ratio) if how == "text"
                        else _resize_glyph(body, ratio))
            pieces.append(body)
            cursor = block.end()
        pieces.append(out[cursor:])
        out = "".join(pieces)
    return out


def apply_chord_sizes(svg: str, musicxml_path) -> str:
    """The chord-symbol half of `apply_element_sizes`, under the name the
    checks and the app's side have always used."""
    return apply_element_sizes(svg, musicxml_path)


def apply_lyric_sizes(svg: str) -> str:
    """Resize each word whose verse name asks for it.

    Read off the PAGE rather than out of the file, unlike the five kinds
    above. Verovio carries a verse's name into the SVG as its labelAttr title,
    so a syllable arrives here holding its own size and nothing has to be
    counted: `ly@1.5` on this verse resizes this word. The kinds that go
    through `apply_element_sizes` match the nth block on the page to the nth
    element in the file, which is an alignment a page break can break, and
    lyrics are the one kind that runs to hundreds per score.

    A tab column's `gt@...` is left alone -- `_tab_staff` redraws those
    entirely -- and so is a verse with a plain name, which is every word
    nobody has resized.
    """
    from . import ops

    if 'class="verse"' not in svg:
        return svg
    pieces, cursor = [], 0
    for match in _VERSE_RE.finditer(svg):
        block = match.group(0)
        label = _LABEL_RE.search(block)
        ratio = ops.parse_lyric_label(label.group(1)) if label else None
        if ratio is None or ratio <= 0:
            continue
        pieces.append(svg[cursor:match.start()])
        pieces.append(_resize_text(block, ratio))
        cursor = match.end()
    if not pieces:
        return svg
    pieces.append(svg[cursor:])
    return "".join(pieces)


_PACKED_TITLE_RE = re.compile(
    r'<title class="labelAttr">' + re.escape(PACKED_PREFIX) + r'([^<]*)</title>')
_GLYPH_TEXT_RE = re.compile(r'(<tspan font-size="[\d.]+px">)([^<]*)(</tspan>)')
_TEXT_Y_RE = re.compile(r'(<text\b[^>]*\by=")(-?[\d.]+)(")')
_ID_RE = re.compile(r'\bid="([^"]+)"')


def _svg_number(value: float) -> str:
    """A coordinate as SVG text, losslessly: whole numbers bare, the rest to
    four places. Mirrored as FingeringDiagrams.svgNumber."""
    if value == int(value):
        return str(int(value))
    return f"{value:.4f}".rstrip("0").rstrip(".")


def _unpack_fingering_columns(svg: str) -> str:
    """Put a packed column's rows back, so the draw pass sees today's column.

    `_pack_column` handed Verovio fewer verses so it would reserve less room;
    the pattern rode in the first verse's label. Here each packed column
    becomes one verse block per row again -- the hole letter, the tag, and the
    y a row would have had at Verovio's own pitch, counted up from the LAST
    HOLE, which is the line the draw pass anchors on. `_fingering_diagrams`
    then runs exactly as it always has: everything it was tuned against in
    Ali's photographs -- the bottom anchor, the median pitch, one axis per
    column, the octave mark's line -- is untouched.

    A row above the last hole is placed where it WOULD have been; the draw pass
    only reads those positions for their spacing, and re-places every row from
    the anchor at its own tighter pitch, which is how the column fits the
    smaller band.
    """
    if PACKED_PREFIX not in svg:
        return svg
    blocks = list(_VERSE_RE.finditer(svg))
    edits: list[tuple[int, int, str]] = []
    i = 0
    while i < len(blocks):
        head = _PACKED_TITLE_RE.search(blocks[i].group(0))
        if not head or not head.group(1):
            i += 1
            continue
        pattern = head.group(1)
        column = [blocks[i]]
        j = i + 1
        while j < len(blocks):
            pad = _PACKED_TITLE_RE.search(blocks[j].group(0))
            if pad is None or pad.group(1):
                break
            column.append(blocks[j])
            j += 1
        i = j
        ys = []
        for block in column:
            found = _TEXT_Y_RE.search(block.group(0))
            ys.append(float(found.group(2)) if found else None)
        if None in ys or len(ys) < 2:
            continue
        gaps = sorted(b - a for a, b in zip(ys, ys[1:]) if b > a)
        if not gaps:
            continue
        pitch = gaps[len(gaps) // 2]
        octave = pattern.endswith("+")
        holes = len(pattern) - (1 if octave else 0)
        anchor = ys[len(column) - (2 if octave else 1)]
        template = column[0].group(0)
        rows = []
        for index, glyph in enumerate(pattern):
            y = (anchor + pitch if glyph == "+"
                 else anchor - (holes - 1 - index) * pitch)
            row = template.replace(head.group(0),
                                   f'<title class="labelAttr">{WHISTLE_TAG}</title>', 1)
            row = _GLYPH_TEXT_RE.sub(lambda m, g=glyph: m.group(1) + g + m.group(3),
                                     row, count=1)
            row = _TEXT_Y_RE.sub(lambda m, v=y: f"{m.group(1)}{_svg_number(v)}{m.group(3)}",
                                 row, count=1)
            # ids stay unique: the rows are copies of one block
            row = _ID_RE.sub(lambda m, n=index: f'id="{m.group(1)}-r{n}"', row)
            rows.append(row)
        edits.append((column[0].start(), column[0].end(), "".join(rows)))
        for block in column[1:]:
            edits.append((block.start(), block.end(), ""))
    for start, end, text in sorted(edits, reverse=True):
        svg = svg[:start] + text + svg[end:]
    return svg


def _fingering_diagrams(svg: str) -> str:
    """Replace whistle-fingering glyphs with drawn circles.

    Verovio lays the fingerings out as lyric verses, which is what centres them
    under each notehead; it cannot draw a filled circle, and the circle glyphs
    are missing from the font the rasterizer falls back to. So the letters are
    the notation and the circles are the drawing.

    Two kinds of verse qualify: ones the engine tagged (<lyric name="wf">), and
    untagged columns of five or six single X/O/ verses on one note — fingerings
    written before the tag existed, which are already sitting in scores.
    Mirrors ios/Scoranger/FingeringDiagrams.swift; keep the two in step.
    """
    # a packed column (see _pack_column) back into one block per row FIRST, so
    # everything below sees the column it was written for
    svg = _unpack_fingering_columns(svg)
    if 'class="verse"' not in svg:
        return svg

    verses = list(_VERSE_RE.finditer(svg))
    if not verses:
        return svg

    parsed = []
    for match in verses:
        block = match.group(0)
        symbol = _SYMBOL_RE.search(block)
        label = _LABEL_RE.search(block)
        text = label.group(1) if label else ""
        parsed.append({
            "match": match,
            "block": block,
            "tagged": text == WHISTLE_TAG,
            "symbol": symbol.group(1) if symbol else None,
            # the verse number, which restarts at 1 on each note. Grouping on
            # this rather than on x: Verovio centres each syllable on its own
            # width, so "X" and "O" verses of the SAME note sit at different x
            # and a column of mixed holes never grouped.
            "number": int(text) if text.isdigit() else None,
            "text": (_ANY_SYL_RE.search(block).group(1)
                     if _ANY_SYL_RE.search(block) else None),
            "y": (float(_Y_RE.search(block).group(1))
                  if _Y_RE.search(block) else None),
            "x": (float(_X_RE.search(block).group(1))
                  if _X_RE.search(block) else None),
        })

    convert = [bool(v["tagged"] and v["symbol"]) for v in parsed]
    start = 0
    while start < len(parsed):
        end = start
        while (end + 1 < len(parsed)
               and parsed[end]["number"] is not None
               and parsed[end + 1]["number"] is not None
               and parsed[end + 1]["number"] > parsed[end]["number"]):
            end += 1
        run = parsed[start:end + 1]
        holes = sum(1 for v in run if v["symbol"])
        # the "+" octave mark belongs to the column but is not a hole; it stays
        # text. Requiring every verse to be a hole rejected the second octave.
        only_holes_and_octave = all(v["symbol"] or v["text"] == "+" for v in run)
        if holes >= WHISTLE_COLUMN and only_holes_and_octave:
            for i in range(start, end + 1):
                if parsed[i]["symbol"]:
                    convert[i] = True
        start = end + 1

    if not any(convert):
        return svg

    # A column's octave "+" stays text -- every font has it, unlike the circle
    # glyphs -- but it belongs to the diagram, so it is scaled with the holes
    # rather than left at the engraving's full text size. The engine tags every
    # whistle verse including the "+", so the tag identifies it directly; the
    # verse-number grouping above cannot, because a tagged verse carries the tag
    # in the label where a number would otherwise be.
    # Where each row is REDRAWN.
    #
    # Verovio lays the verses out as lines of lyric text, so their spacing is
    # the lyric line height -- and that same option sizes chord symbols, which
    # is how halving it once shrank every chord name on the page. So the
    # spacing is not asked of Verovio at all: the rows are simply re-placed
    # here, at a pitch of our own, and lyricSize is left alone.
    #
    # A column is a run of consecutive verses whose y increases; the next note's
    # column starts when y drops back to the top again. That works for tagged
    # and untagged columns alike, unlike the verse-number grouping above, which
    # cannot see tagged verses because the tag sits where the number would be.
    placement: dict[int, float] = {}
    column: list[int] = []

    def row_pitch(ys: list[float]) -> float:
        """The spacing between holes, as the MEDIAN gap.

        Not the average over the column: the octave "+" hangs further below
        than the holes are apart, so averaging across the whole span stretched
        the pitch -- and with it the circles, which came out half again too big
        on any column carrying one.
        """
        gaps = sorted(b - a for a, b in zip(ys, ys[1:]) if b > a)
        if not gaps:
            return 0.0
        middle = len(gaps) // 2
        return (gaps[middle] if len(gaps) % 2
                else (gaps[middle - 1] + gaps[middle]) / 2)

    def place(indices: list[int]) -> None:
        ys = [parsed[i]["y"] for i in indices]
        if len(indices) < 2 or any(y is None for y in ys):
            return
        pitch = row_pitch(ys)
        if pitch <= 0:
            return
        new_pitch, _radius = hole_geometry(pitch)
        # Anchored at the BOTTOM row -- the one nearest the staff.
        #
        # It used to anchor at the top, and that is what put the big gap in
        # Ali's screenshot: our pitch is about half the lyric pitch Verovio
        # laid out, so holding the TOP fixed pulled every row below it upward
        # and the lowest hole ended up half a column's height above where the
        # staff expected it. Holding the BOTTOM fixed instead keeps the
        # diagrams against their staff and takes the reclaimed space off the
        # top, which is the safe direction: the system above is further away
        # than the staff below, and the column only ever gets shorter.
        # ...and specifically at the last HOLE, not the last row.
        #
        # A column's last row is the octave "+" when it has one, and anchoring
        # there hung every fingered-octave note a whole lyric pitch lower than
        # its neighbours: within one row above the staff some diagrams sat
        # high and some low, which is what Ali circled through Morrison's Jig.
        # Verovio lays every verse of a system out on the same baseline, so
        # anchoring all columns on the same ROW of the column -- their last
        # hole -- puts every circle stack in a system on one line, whatever
        # each one carries underneath.
        holes = [row for row, i in enumerate(indices) if convert[i]]
        anchor = holes[-1] if holes else len(indices) - 1
        bottom = ys[anchor]
        for row, i in enumerate(indices):
            placement[i] = bottom - (anchor - row) * new_pitch

    # How far apart two rows of ONE column may sit horizontally.
    #
    # Not zero: Verovio centres each syllable on its own width, so an "X" row
    # and an "O" row of the same note can be ten units apart. Not generous
    # either: consecutive notes are a whole note-spacing apart. A quarter of
    # the row pitch sits comfortably between the two and scales with the staff,
    # which a fixed number would not.
    all_gaps = sorted(b["y"] - a["y"]
                      for a, b in zip(parsed, parsed[1:])
                      if a["y"] is not None and b["y"] is not None and b["y"] > a["y"])
    typical_pitch = all_gaps[len(all_gaps) // 2] if all_gaps else 0.0
    x_tolerance = max(typical_pitch * 0.25, 2.0)

    def same_column(a: int, b: int) -> bool:
        """Two consecutive verses in one column.

        Both tests are needed. y must increase, because the rows of a column
        run down the page -- but that ALONE merged the last column of one
        system with the first of the next, whose y is larger still simply
        because it is further down the page: the second system's first column
        was then re-placed from the first system's anchor and left a stack of
        circles floating in the gap between the two, under no note at all.
        x pins a column to one note.
        """
        pa, pb = parsed[a], parsed[b]
        if pa["x"] is None or pb["x"] is None:
            return False
        return pb["y"] > pa["y"] and abs(pb["x"] - pa["x"]) <= x_tolerance

    for i, v in enumerate(parsed):
        if v["y"] is None or not (convert[i] or (v["tagged"] and v["text"] == "+")):
            place(column)
            column = []
            continue
        if column and not same_column(column[-1], i):
            place(column)
            column = []
        column.append(i)
    place(column)

    # the radius belongs to the column too, from the same original pitch --
    # and so does the horizontal AXIS.
    #
    # Verovio centres each verse on its own glyph width, so the rows of one
    # note do not all start at the same x: an "X" row and an "O" row can be ten
    # units apart, and the octave "+" -- a different glyph again -- came out
    # thirty-seven units off on two notes of the fixture. Drawn from its own x,
    # each row lands on a slightly different axis and the "+" hangs beside the
    # circles instead of under them, which is what Ali photographed. A column
    # is one column: it gets ONE x, taken from its holes (the "+" is the odd
    # glyph, so it does not get a vote), and every row is drawn on it.
    radii: dict[int, float] = {}
    anchors: dict[int, float] = {}
    column = []
    for i, v in enumerate(parsed):
        if v["y"] is None or not (convert[i] or (v["tagged"] and v["text"] == "+")):
            column = []
            continue
        if column and not same_column(column[-1], i):
            column = []
        column.append(i)
        if len(column) >= 2:
            pitch = row_pitch([parsed[j]["y"] for j in column])
            if pitch > 0:
                _p, r = hole_geometry(pitch)
                for j in column:
                    radii[j] = r
            holes = sorted(parsed[j]["x"] for j in column
                           if convert[j] and parsed[j]["x"] is not None)
            if holes:
                axis = holes[len(holes) // 2]
                for j in column:
                    anchors[j] = axis

    out, cursor = [], 0
    for index, (wanted, v) in enumerate(zip(convert, parsed)):
        match = v["match"]
        out.append(svg[cursor:match.start()])
        if wanted:
            out.append(_draw_hole(v["block"], y=placement.get(index),
                                  radius=radii.get(index),
                                  anchor_x=anchors.get(index)))
        elif v["tagged"] and v["text"] == "+":
            out.append(_scale_text(v["block"], y=placement.get(index),
                                   radius=radii.get(index),
                                   anchor_x=anchors.get(index)))
        else:
            out.append(v["block"])
        cursor = match.end()
    out.append(svg[cursor:])
    return "".join(out)


def _scale_text(block: str, y: float | None = None,
                radius: float | None = None,
                anchor_x: float | None = None) -> str:
    """Shrink a verse's glyph to the diagram scale, leaving it as text.

    The octave "+" is not a hole, but it belongs to the column and has to move
    and shrink with it, or it floats where the old spacing put it.

    It also has to sit UNDER the column rather than beside it. A hole is drawn
    as a circle whose centre is offset from the verse's text anchor
    (`HOLE_CENTRE_X_VS_RADIUS * r`); the "+" stayed at the raw anchor, so it
    hung to one side of the circles it belongs to. It is centred on the same
    axis as the circles here -- the COLUMN's `anchor_x`, not its own, because
    Verovio placed this glyph by its own width -- with `text-anchor="middle"`
    so the glyph's width stops mattering from here on.
    """
    if radius is not None:
        size = radius * 2 * OCTAVE_MARK_VS_DIAMETER
        block = _SIZE_RE.sub(f'<tspan font-size="{size:g}px">', block, count=1)
    else:
        def shrink(m):
            return f'<tspan font-size="{float(m.group(1)) * DIAGRAM_SCALE:g}px">'
        block = _SIZE_RE.sub(shrink, block, count=1)
    if y is not None:
        # only the NUMBER: _Y_RE matches from "<text" onwards, so replacing the
        # whole match deletes the opening tag and the SVG stops parsing
        block = _Y_RE.sub(lambda m: m.group(0).replace(f'y="{m.group(1)}"',
                                                       f'y="{y:g}"'),
                          block, count=1)
    if radius is not None:
        # onto the circles' own axis, and anchored at its middle so the glyph
        # width does not push it off again
        found = _X_RE.search(block)
        if found:
            base = anchor_x if anchor_x is not None else float(found.group(1))
            centre = base + HOLE_CENTRE_X_VS_RADIUS * radius
            block = _X_RE.sub(f'<text x="{centre:g}"', block, count=1)
            if "text-anchor" not in block.split(">", 1)[0]:
                block = block.replace("<text ", '<text text-anchor="middle" ', 1)
    return block


def _draw_hole(block: str, y: float | None = None,
               radius: float | None = None,
               anchor_x: float | None = None) -> str:
    """One verse, already judged to be a hole.

    `y`, `radius` and `anchor_x` come from the column: the row is re-placed at
    our own pitch, drawn at our own size, and set on the column's one vertical
    axis -- none of which is the font's any more.
    Without them (a lone verse with no column to measure) it falls back to the
    old font-derived geometry.
    """
    symbol = _SYMBOL_RE.search(block)
    x, ymatch = _X_RE.search(block), _Y_RE.search(block)
    size = _SIZE_RE.search(block)
    if not (symbol and x and ymatch and size):
        return block
    font = float(size.group(1))
    if font <= 0 and radius is None:
        return block
    if radius is not None:
        r = radius
        base_y = y if y is not None else float(ymatch.group(1))
        base_x = anchor_x if anchor_x is not None else float(x.group(1))
        cx = base_x + HOLE_CENTRE_X_VS_RADIUS * r
        cy = base_y - HOLE_CENTRE_Y_VS_RADIUS * r
        stroke = HOLE_STROKE_VS_RADIUS * r
    else:
        drawn = font * DIAGRAM_SCALE
        cx = float(x.group(1)) + HOLE_CENTRE_X * drawn
        cy = float(ymatch.group(1)) + HOLE_CENTRE_Y * drawn
        r = HOLE_RADIUS * drawn
        stroke = HOLE_STROKE * drawn
    # paths rather than <circle>: the on-device renderer draws only the
    # subset Verovio emits, and a <circle> vanished there
    ring = (f'M {cx - r} {cy} A {r} {r} 0 1 0 {cx + r} {cy} '
            f'A {r} {r} 0 1 0 {cx - r} {cy} Z')
    if symbol.group(1) == "X":
        shape = f'<path d="{ring}" fill="currentColor" stroke="none" />'
    elif symbol.group(1) == "O":
        shape = (f'<path d="{ring}" fill="none" stroke="currentColor" '
                 f'stroke-width="{stroke}" />')
    else:
        shape = (f'<path d="{ring}" fill="none" stroke="currentColor" '
                 f'stroke-width="{stroke}" />'
                 f'<path d="M {cx - r} {cy} A {r} {r} 0 0 0 {cx + r} {cy} Z" '
                 f'fill="currentColor" stroke="none" />')
    return _TEXT_RE.sub(shape, block, count=1)


# ------------------------------------------------------- guitar tablature
#
# The notation carries six verses per note: a fret number on the string that
# is played, a dash on the ones that are not (ops.guitar_tab). What is drawn
# is a tab staff -- six lines running through the dashes, with the numbers
# standing in gaps in the lines.
#
# The DASH is the meaning and the LINE is the drawing, the same arrangement
# the whistle's letters and circles have. Left as text a column of dashes is
# six loose hyphens per note; drawn as segments that reach half way to the
# neighbouring column they join into the six continuous lines a player reads.
#
# The rows are re-placed here rather than asked of Verovio, for the reason the
# whistle's are: `lyricSize` is one document-wide text size that also governs
# chord symbols, so shrinking the tab to fit would shrink every chord name on
# the page with it.
#
# Mirrored in ios/Scoranger/ScoreModel/TabStaff.swift; engine/scripts/
# check_guitar_tab.py holds the two to one golden fragment.

TAB_TAG = "gt"
TAB_ROWS = 6
# Rows sit closer than Verovio's lyric pitch: a tab staff is tighter than six
# lines of words, and the column only ever gets shorter, which is the safe
# direction when it hangs below the staff.
TAB_PITCH_RATIO = 0.62
TAB_DIGIT_VS_PITCH = 0.9
TAB_LINE_VS_PITCH = 0.055
# Half the gap a one-digit number is given in its line. A two-digit fret needs
# half as much again.
TAB_BREAK_VS_PITCH = 0.42
# How far a column's lines run when there is no neighbour to meet: the start
# and end of a system, in drawn row pitches.
TAB_END_ADVANCE = 1.1
# A number sits ON its line, so its baseline is below it.
TAB_BASELINE_VS_PITCH = 0.32
# MusicXML measures a nudge in TENTHS of a staff space, and this pass places
# the rows itself, so it needs the two in the same units. Measured off a real
# engraving: a staff space is 180 SVG units where the lyric row pitch is 390,
# so ten tenths are 0.4615 of a row pitch.
TAB_TENTH_VS_ROW_PITCH = 0.04615


def tab_column_svg(texts: list, x: float, top_y: float, row_pitch: float,
                   left: float, right: float, scale: float = 1.0) -> str:
    """One column of tab: six line segments, and the frets standing in them.

    Pure, and the only place the numbers are decided, so the on-device
    renderer can be held to the same answer -- see
    ios/Scoranger/ScoreModel/TabStaff.swift and check_guitar_tab.py.
    """
    pitch = row_pitch * TAB_PITCH_RATIO * scale
    stroke = pitch * TAB_LINE_VS_PITCH
    parts = []
    for row, text in enumerate(texts):
        y = top_y + row * pitch
        fret = text.strip() if text else ""
        if fret and fret != "-":
            gap = pitch * TAB_BREAK_VS_PITCH * (1.0 if len(fret) < 2 else 1.5)
            for x1, x2 in ((left, x - gap), (x + gap, right)):
                if x2 > x1:
                    parts.append(
                        f'<path d="M {x1:g} {y:g} L {x2:g} {y:g}" '
                        f'stroke="currentColor" stroke-width="{stroke:g}" fill="none"/>')
            parts.append(
                f'<text text-anchor="middle" font-style="normal" x="{x:g}" '
                f'y="{y + pitch * TAB_BASELINE_VS_PITCH:g}">'
                f'<tspan font-size="{pitch * TAB_DIGIT_VS_PITCH:g}px">{fret}</tspan></text>')
        else:
            parts.append(
                f'<path d="M {left:g} {y:g} L {right:g} {y:g}" '
                f'stroke="currentColor" stroke-width="{stroke:g}" fill="none"/>')
    return "".join(parts)


def tab_columns(svg: str) -> list[dict]:
    """Every tab column in a page, with the rows Verovio laid out for it.

    A column is a run of consecutive tagged verses whose y increases and whose
    x stays put. Both tests are needed: y alone merges the last column of one
    system with the first of the next, which is further down the page only
    because it is further down the page.
    """
    from . import ops

    verses = []
    for match in _VERSE_RE.finditer(svg):
        block = match.group(0)
        label = _LABEL_RE.search(block)
        # the label is the tag AND whatever `adjust-element --kind tab` wrote
        # onto it: Verovio carries a lyric's name to the page and drops its
        # size and its offsets, so the name is what reaches here
        adjustment = ops.parse_tab_label(label.group(1)) if label else None
        if adjustment is None:
            continue
        text = _ANY_SYL_RE.search(block)
        x = _X_RE.search(block)
        y = _Y_RE.search(block)
        if x is None or y is None:
            continue
        verses.append({"match": match, "text": text.group(1) if text else "",
                       "x": float(x.group(1)), "y": float(y.group(1)),
                       "scale": adjustment[0] or 1.0,
                       "dx": adjustment[1] or 0.0, "dy": adjustment[2] or 0.0})
    columns: list[dict] = []
    run: list[dict] = []

    def settle():
        if len(run) < 2:
            run.clear()
            return
        ys = [v["y"] for v in run]
        gaps = sorted(b - a for a, b in zip(ys, ys[1:]) if b > a)
        if gaps:
            pitch = (gaps[len(gaps) // 2] if len(gaps) % 2
                     else (gaps[len(gaps) // 2 - 1] + gaps[len(gaps) // 2]) / 2)
            xs = sorted(v["x"] for v in run)
            # the whole column moves and resizes together, so its first verse
            # speaks for it
            columns.append({"rows": list(run), "pitch": pitch, "top": ys[0],
                            "x": xs[len(xs) // 2], "scale": run[0]["scale"],
                            "dx": run[0]["dx"], "dy": run[0]["dy"]})
        run.clear()

    for verse in verses:
        if run:
            last = run[-1]
            tolerance = max(abs(verse["y"] - last["y"]) * 0.5, 2.0)
            if not (verse["y"] > last["y"] and abs(verse["x"] - last["x"]) <= tolerance):
                settle()
        run.append(verse)
    settle()
    return columns


def _tab_staff(svg: str) -> str:
    """Draw the tab staff through every tab column in a page."""
    if 'class="verse"' not in svg:
        return svg
    columns = tab_columns(svg)
    if not columns:
        return svg

    # Columns of one SYSTEM share their top row, because Verovio lays every
    # verse of a system on the same baseline. That is what lets each column's
    # lines reach half way to its neighbour and meet them: the six lines are
    # drawn a column at a time and still come out continuous.
    systems: dict[int, list[dict]] = {}
    for column in columns:
        systems.setdefault(round(column["top"]), []).append(column)
    drawn: dict[int, str] = {}
    blanked: set[int] = set()
    for row_columns in systems.values():
        row_columns.sort(key=lambda c: c["x"])
        for index, column in enumerate(row_columns):
            pitch = column["pitch"] * TAB_PITCH_RATIO * column["scale"]
            before = row_columns[index - 1]["x"] if index else None
            after = row_columns[index + 1]["x"] if index + 1 < len(row_columns) else None
            left = (column["x"] + before) / 2 if before is not None \
                else column["x"] - pitch * TAB_END_ADVANCE
            right = (column["x"] + after) / 2 if after is not None \
                else column["x"] + pitch * TAB_END_ADVANCE
            # MusicXML measures up; the page measures down
            unit = column["pitch"] * TAB_TENTH_VS_ROW_PITCH
            dx, dy = column["dx"] * unit, -column["dy"] * unit
            texts = [row["text"] for row in column["rows"]]
            drawn[column["rows"][0]["match"].start()] = tab_column_svg(
                texts, column["x"] + dx, column["top"] + dy, column["pitch"],
                left + dx, right + dx, column["scale"])
            for row in column["rows"][1:]:
                blanked.add(row["match"].start())

    out, cursor = [], 0
    for column in columns:
        for row in column["rows"]:
            match = row["match"]
            out.append(svg[cursor:match.start()])
            if match.start() in drawn:
                out.append(f'<g class="verse tab">{drawn[match.start()]}</g>')
            cursor = match.end()
    out.append(svg[cursor:])
    return "".join(out)


# ------------------------------------------------- guitar chord diagrams
#
# The notation carries the shape and nothing else (ops.chord_diagrams): six
# frets, `x` for a string that is not sounded. Everything drawn here follows
# from those six numbers, so the page cannot say something the notation does
# not.
#
# GLYPHS ARE NOT AN OPTION for the grid, the dots or the barre -- the same
# lesson the whistle's circles taught: the font the PDF rasterizer falls back
# to has no filled circle and engraves an empty box. Lines, filled discs and a
# filled bar are drawn as paths. Only the fret numbers and the "5 fr." label
# are text, because they are digits, which every font has.
#
# Verovio reserves the space, we do the drawing. A one-line <dir> reserves one
# line of text above the staff, so the MEI pass below turns each marker into a
# block of blank lines -- seven of them, a marks row and the six lines that
# bound five frets -- and Verovio lays the system out around a block that size.
# The same pass pins every marker to one vertical level with @vgrp: without it
# Verovio gives each direction a level of its own and the diagrams climb the
# page in steps, one per chord.
#
# Mirrored in ios/Scoranger/ScoreModel/ChordDiagrams.swift, which must draw the
# same picture; engine/scripts/check_chord_diagrams.py holds the two to one
# golden fragment.

CHORD_DIAGRAM_RE = re.compile(
    r"\[(?:[x\d]{1,2},){5}[x\d]{1,2}\](?:\((?:[x\d],){5}[x\d]\))?")
# rows of the reserved block: one for the marks, six for the lines of five frets
DIAGRAM_ROWS = 7
DIAGRAM_STRINGS = 6
DIAGRAM_FRETS = 5
# All of it is proportional to the string gap, and the string gap is the block's
# own row pitch, so a diagram scales with the engraving exactly as the whistle's
# holes do.
DIAGRAM_GAP_VS_ROW = 1.0
DIAGRAM_DOT_VS_GAP = 0.3
# the bar is a shade slimmer than a dot is wide, so it does not touch the fret
# lines above and below it
DIAGRAM_BARRE_VS_GAP = 0.22
DIAGRAM_LINE_VS_GAP = 0.05
DIAGRAM_NUT_VS_GAP = 0.16
DIAGRAM_MARK_TEXT_VS_GAP = 0.7
DIAGRAM_POSITION_TEXT_VS_GAP = 0.6
# The point size a diagram is drawn at when nobody has adjusted it, so an
# absolute size from `adjust-element` reads as a ratio of the drawn one -- the
# same arrangement chord symbols use (DEFAULT_CHORD_POINTS).
DEFAULT_DIAGRAM_POINTS = 12.0
# What the MEI pass writes so the SVG pass can find its own work again, and
# the level every diagram is pinned to.
DIAGRAM_VGRP = "1"
_DIR_MARKER_RE = re.compile(
    r'<dir\b([^>]*)>\s*(\[[x\d,]+\](?:\([x\d,]+\))?)\s*</dir>')
_WORDS_RE = re.compile(r"<words\b([^>]*)>([^<]*)</words>")


def diagram_adjustments(musicxml_path) -> list[dict]:
    """Each diagram's size and offset, in document order.

    Read from the file, like `chord_adjustments`: MusicXML puts them on the
    <words> the shape rides in, Verovio drops all three on the way to MEI, and
    document order is the join. `adjust-element --kind diagram` writes them.
    """
    try:
        text = Path(musicxml_path).read_text(encoding="utf-8")
    except OSError:
        return []
    out = []
    for attrs, body in _WORDS_RE.findall(text):
        if CHORD_DIAGRAM_RE.search(body) is None:
            continue

        def number(attr, tag=attrs):
            found = re.search(rf'{attr}="([-\d.]+)"', tag)
            return float(found.group(1)) if found else None
        out.append({"size": number("font-size"),
                    "dx": number("relative-x"), "dy": number("relative-y")})
    return out


def mei_with_chord_diagrams(mei: str, musicxml_path=None) -> str | None:
    """Reserve a block for every diagram, and pin them all to one level.

    Returns None when the score carries no diagram, so the caller can skip a
    Verovio reload. The shape moves into @label -- which Verovio carries to the
    SVG as a <title> -- and the body becomes blank rows, because the marker's
    own text is not what anyone should read on the page.
    """
    adjustments = (diagram_adjustments(musicxml_path)
                   if musicxml_path is not None else [])
    index = 0

    def block(match):
        nonlocal index
        attrs, shape = match.group(1), match.group(2)
        adjustment = adjustments[index] if index < len(adjustments) else {}
        index += 1
        size = adjustment.get("size")
        scale = 1.0 if size is None else size / DEFAULT_DIAGRAM_POINTS
        label = shape if size is None else f"{shape}@{scale:g}"
        attrs = re.sub(r'\s+vgrp="[^"]*"', "", attrs)
        if adjustment.get("dx") is not None:
            attrs += f' ho="{adjustment["dx"] * _TENTHS_TO_HALF_SPACES:g}"'
        if adjustment.get("dy") is not None:
            # Both measure UP here: MusicXML's relative-y does, and so does
            # @vo on a direction placed ABOVE a staff -- a negative one pushed
            # the block 540 units DOWN onto the staff when it was measured.
            # (The <harm> pass above negates its own; harm and dir are not
            # the same element, and this one is what the ruler says.)
            attrs += f' vo="{adjustment["dy"] * _TENTHS_TO_HALF_SPACES:g}"'
        # The reserved block grows with the diagram. Without this an
        # enlarged one drew straight down through the staff underneath it:
        # the rows are what Verovio spaces the system by, and seven of them
        # are seven whatever size the drawing is.
        rows = "<lb/>".join([" "] * ceil(DIAGRAM_ROWS * scale))
        return f'<dir{attrs} vgrp="{DIAGRAM_VGRP}" label="{label}">{rows}</dir>'

    out = _DIR_MARKER_RE.sub(block, mei)
    return out if index else None


def diagram_geometry(x: float, top_y: float, row_pitch: float,
                     scale: float = 1.0) -> dict:
    """Where a diagram's parts go, from the block Verovio laid out.

    Pure, and the only place the numbers are decided, so the on-device renderer
    can be held to the same answer -- see
    ios/Scoranger/ScoreModel/ChordDiagrams.swift and check_chord_diagrams.py.
    """
    gap = row_pitch * DIAGRAM_GAP_VS_ROW * scale
    return {
        "gap": gap,
        "left": x,
        "width": gap * (DIAGRAM_STRINGS - 1),
        # the marks sit on the block's first row; the grid starts on the next
        "marks_y": top_y,
        "top": top_y + row_pitch * 0.5 + gap * 0.25,
        "height": gap * DIAGRAM_FRETS,
        "dot": gap * DIAGRAM_DOT_VS_GAP,
        "barre": gap * DIAGRAM_BARRE_VS_GAP,
        "line": gap * DIAGRAM_LINE_VS_GAP,
        "nut": gap * DIAGRAM_NUT_VS_GAP,
        "mark_text": gap * DIAGRAM_MARK_TEXT_VS_GAP,
        "position_text": gap * DIAGRAM_POSITION_TEXT_VS_GAP,
    }


def _disc(cx: float, cy: float, r: float) -> str:
    """A filled circle as two arcs: SwiftDraw draws the subset Verovio emits,
    and <circle> came out of the on-device renderer as nothing at all."""
    return (f'<path d="M {cx - r:g} {cy:g} A {r:g} {r:g} 0 1 0 {cx + r:g} {cy:g} '
            f'A {r:g} {r:g} 0 1 0 {cx - r:g} {cy:g} Z" '
            f'fill="currentColor" stroke="none"/>')


def chord_diagram_svg(shape: list, x: float, top_y: float, row_pitch: float,
                      scale: float = 1.0, fingers: list | None = None) -> str:
    """One diagram, drawn. `shape` is six frets, None for a silent string.

    `fingers` is which finger goes on each of them, and it is what the marks
    row shows when the notation carries one -- a guitarist reads the row above
    a grid as a hand, not as a repeat of the dots. None falls back to the
    frets, which is what a shape nobody has curated a hand for gets.

    Mirrored exactly in ChordDiagrams.swift: check_chord_diagrams.py compares
    both against one golden fragment, so a change here that is not made there
    fails the checks rather than the eye.
    """
    from . import ops

    g = diagram_geometry(x, top_y, row_pitch, scale)
    base, nut = ops.diagram_window(shape)
    barre = ops.diagram_barre(shape)
    parts = []

    def line(x1, y1, x2, y2, width):
        parts.append(f'<path d="M {x1:g} {y1:g} L {x2:g} {y2:g}" '
                     f'stroke="currentColor" stroke-width="{width:g}" fill="none"/>')

    for s in range(DIAGRAM_STRINGS):
        sx = g["left"] + s * g["gap"]
        line(sx, g["top"], sx, g["top"] + g["height"], g["line"])
    for f in range(DIAGRAM_FRETS + 1):
        fy = g["top"] + f * g["gap"]
        thick = g["nut"] if (f == 0 and nut) else g["line"]
        line(g["left"], fy, g["left"] + g["width"], fy, thick)

    # the marks row: what each HAND does, low to high -- x for a string that is
    # not sounded, 0 for one left open, and otherwise the finger that stops it,
    # falling back to the fret when the notation names no fingering
    marks = fingers if fingers is not None else shape
    for s, fret in enumerate(marks):
        mark = "x" if fret is None else str(fret)
        parts.append(
            f'<text text-anchor="middle" font-style="normal" '
            f'x="{g["left"] + s * g["gap"]:g}" y="{g["marks_y"]:g}">'
            f'<tspan font-size="{g["mark_text"]:g}px">{mark}</tspan></text>')

    def cell_centre(fret):
        return g["top"] + (fret - base + 0.5) * g["gap"]

    barred = set()
    if barre is not None:
        fret, first, last = barre
        barred = {i for i in range(first, last + 1) if shape[i] == fret}
        y = cell_centre(fret)
        half = g["barre"]
        parts.append(
            f'<path d="M {g["left"] + first * g["gap"]:g} {y - half:g} '
            f'H {g["left"] + last * g["gap"]:g} V {y + half:g} '
            f'H {g["left"] + first * g["gap"]:g} Z" '
            f'fill="currentColor" stroke="none"/>')

    for s, fret in enumerate(shape):
        if not fret or s in barred:
            continue
        parts.append(_disc(g["left"] + s * g["gap"], cell_centre(fret), g["dot"]))

    if not nut:
        parts.append(
            f'<text font-style="normal" '
            f'x="{g["left"] + g["width"] + g["gap"] * 0.4:g}" '
            f'y="{g["top"] + g["gap"] * 0.7:g}">'
            f'<tspan font-size="{g["position_text"]:g}px">{base} fr.</tspan></text>')
    return "".join(parts)


# A <dir> group holds a title and a text and nothing nested, so one closing
# tag ends it -- unlike a verse, whose group closes twice.
_DIAGRAM_GROUP_RE = re.compile(r'<g[^>]*class="dir">.*?</g>', re.S)
_DIAGRAM_LABEL_RE = re.compile(
    r'<title class="labelAttr">(\[[x\d,]+\](?:\([x\d,]+\))?)(?:@([\d.]+))?</title>')
_ROW_XY_RE = re.compile(r'<t(?:ext|span)[^>]*\bx="([-\d.]+)"[^>]*\by="([-\d.]+)"')


def chord_diagram_blocks(svg: str) -> list[dict]:
    """Every diagram marker in a page, with the block Verovio gave it.

    The rows are the blank lines the MEI pass put there; their y positions are
    the pitch the drawing is built from, exactly as the whistle's columns take
    their pitch from the verses Verovio laid out.
    """
    blocks = []
    for match in _DIAGRAM_GROUP_RE.finditer(svg):
        label = _DIAGRAM_LABEL_RE.search(match.group(0))
        if label is None:
            continue
        rows = _ROW_XY_RE.findall(match.group(0))
        if len(rows) < 2:
            continue
        ys = [float(y) for _, y in rows]
        pitch = min(b - a for a, b in zip(ys, ys[1:]) if b > a)
        blocks.append({"match": match, "shape": label.group(1),
                       "scale": float(label.group(2)) if label.group(2) else 1.0,
                       "x": float(rows[0][0]), "top": ys[0], "pitch": pitch})
    return blocks


# DIAGRAMS THAT WOULD MEET ARE DRAWN SMALLER. Verovio reserves a diagram's
# HEIGHT (the blank rows) but no width, and every diagram is pinned to one
# level (@vgrp) so they do not climb the page -- so two chords a bar or less
# apart drew one grid over the other (Amazing Grace, bars 3-4, found taking the
# App Store screenshots). Each diagram on a line, left to right, is shrunk to
# the room before the next one, a string gap of clearance included, and never
# below DIAGRAM_MIN_FIT: smaller than half its size a grid cannot be read, and
# chords that close together overlap at the floor rather than vanish.
# Mirrored as ChordDiagrams.fit; check_chord_diagrams.py holds both.
DIAGRAM_CLEARANCE_GAPS = 1.0
DIAGRAM_MIN_FIT = 0.5


def diagram_fit(blocks: list[dict]) -> list[float]:
    """The factor each block is drawn at so it does not reach the next one.

    `blocks` carry x, top, pitch and scale, in page order. Two blocks are on
    one line when their tops are within a row pitch of each other.
    """
    fits = [1.0] * len(blocks)
    for i, block in enumerate(blocks):
        right = [b["x"] for j, b in enumerate(blocks)
                 if j != i and b["x"] > block["x"]
                 and abs(b["top"] - block["top"]) < min(b["pitch"], block["pitch"])]
        if not right:
            continue
        room = min(right) - block["x"]
        wants = (block["pitch"] * DIAGRAM_GAP_VS_ROW * block["scale"]
                 * (DIAGRAM_STRINGS - 1 + DIAGRAM_CLEARANCE_GAPS))
        if wants > room:
            fits[i] = max(DIAGRAM_MIN_FIT, room / wants)
    return fits


def _chord_diagrams(svg: str) -> str:
    """Replace every reserved diagram block with the drawn diagram."""
    from . import ops

    blocks = chord_diagram_blocks(svg)
    if not blocks:
        return svg
    fits = diagram_fit(blocks)
    out, cursor = [], 0
    for block, fit in zip(blocks, fits):
        match = block["match"]
        out.append(svg[cursor:match.start()])
        shape = ops.parse_shape(block["shape"])
        drawn = chord_diagram_svg(shape, block["x"], block["top"],
                                  block["pitch"], block["scale"] * fit,
                                  ops.parse_fingering(block["shape"])) if shape else ""
        out.append(f'<g class="dir chord-diagram">{drawn}</g>')
        cursor = match.end()
    out.append(svg[cursor:])
    return "".join(out)


def render_pdf(musicxml_path, out_path, parts: list[str] | None = None,
               title: str | None = None) -> dict:
    import cairosvg
    from pypdf import PdfReader, PdfWriter

    src = str(musicxml_path)
    kept = None
    if parts or title:
        from music21 import converter, metadata as m21metadata

        from . import ops
        s = converter.parse(src, forceSource=True)
        if parts:
            ops.keep_parts(s, parts)
            kept = ops.list_part_labels(s)
        if title:
            if s.metadata is None:
                s.metadata = m21metadata.Metadata()
            s.metadata.title = title
            s.metadata.movementName = title
        with tempfile.NamedTemporaryFile(suffix=".musicxml", delete=False) as tmp:
            src = tmp.name
        s.write("musicxml", fp=src)

    writer = PdfWriter()
    # The score's own spacing, read before anything is laid out: Verovio lays
    # the document out as it LOADS it, so options set after the load do not
    # take until something reloads -- and on a score with no fingerings and no
    # adjustments nothing does.
    with open(src, encoding="utf-8") as fh:
        notation = fh.read()
    spacing = spacing_from_musicxml(notation)
    numbering = measure_numbers_from_musicxml(notation)
    with _tk_lock:
        tk = _toolkit()
        # The page geometry rides along with every setOptions call: a partial
        # one risks the rest reverting to Verovio's defaults, which would
        # quietly bring back the trimmed, uneven pages -- and the spacing is
        # named in full so one score's wide staves are not the next score's.
        tk.setOptions({**page_options(), **spacing_options(spacing),
                       **measure_number_options(numbering),
                       "breaks": breaks_for(notation),
                       "lyricSize": lyric_size_for(fingerings=False)})
        if not tk.loadFile(src):
            raise RuntimeError(f"Verovio could not load {src}")
        mei = tk.getMEI()
        # Fingerings go above their staff and render small. Verovio ignores
        # MusicXML's lyric placement, so the move is made on the MEI and the
        # document reloaded — the same round trip the chart styling below uses.
        above = mei_with_fingerings_above(mei, rows=spacing["rows"])
        if above is not None:
            mei = above
            if not tk.loadData(mei):
                raise RuntimeError("Verovio could not reload MEI with fingerings above")
        # Real Book chord-lane styling, applied ONLY to the symbols whose
        # notation asks for it. This used to stamp every score that had a chord
        # symbol, which is why a plain lead sheet came out of the PDF on the
        # staff and out of the app above it -- the same file, two placements,
        # and no way for "move it up half a space" to mean one thing.
        styled = mei_with_chart_styling(mei, src)
        if styled is not None:
            mei = styled
            harm_staves = {int(n) for n in
                           re.findall(r'<harm\b[^>]*\bplace="within"[^>]*\bstaff="(\d+)"', mei)}
            harm_staves |= {int(n) for n in
                            re.findall(r'<harm\b[^>]*\bstaff="(\d+)"[^>]*\bplace="within"', mei)}
            if not tk.loadData(mei):
                raise RuntimeError("Verovio could not reload MEI with chart styling")
        else:
            harm_staves = set()

        # The reader's own nudges. These functions existed and were checked in
        # isolation, but nothing in the PDF path ever called them -- so an
        # adjustment showed on screen and vanished from the export.
        adjusted = mei_with_element_adjustments(mei, src)
        if adjusted is not None:
            mei = adjusted
            if not tk.loadData(mei):
                raise RuntimeError("Verovio could not reload MEI with chord offsets")

        # Chord diagrams: the marker each one rides in reserves one line of
        # text, and a diagram is seven lines tall, so the block is opened up
        # here and the document reloaded around it.
        diagrams = mei_with_chord_diagrams(mei, src)
        if diagrams is not None:
            mei = diagrams
            if not tk.loadData(mei):
                raise RuntimeError("Verovio could not reload MEI with chord diagrams")

        # A rehearsal mark is written to every part so extracted parts keep it;
        # in a COMBINED score Verovio anchors them all to one staff and draws
        # the letter over itself once per part.
        deduped = mei_with_deduped_rehearsals(mei)
        if deduped != mei:
            mei = deduped
            if not tk.loadData(mei):
                raise RuntimeError("Verovio could not reload MEI with deduped rehearsals")
        if numbering[0] == "none":
            hidden = mei_with_measure_numbers_hidden(mei)
            if hidden is not None:
                mei = hidden
                if not tk.loadData(mei):
                    raise RuntimeError("Verovio could not reload MEI with measure numbers hidden")
        n_pages = tk.getPageCount()
        svgs = [_tab_staff(_chord_diagrams(_fingering_diagrams(
                    apply_lyric_sizes(apply_element_sizes(
                        _style_chart_svg(_sanitize_svg(_draw_leading_music_glyphs(
                            tk.renderToSVG(p))), harm_staves),
                        src)))))
                for p in range(1, n_pages + 1)]
    for svg in svgs:
        # the page's PHYSICAL size, which is not the size Verovio drew it at
        pdf_page = cairosvg.svg2pdf(bytestring=svg.encode(),
                                    output_width=PDF_WIDTH_PX,
                                    output_height=PDF_HEIGHT_PX)
        writer.append(PdfReader(io.BytesIO(pdf_page)))
    out = Path(out_path)
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "wb") as f:
        writer.write(f)
    return {"pages": n_pages, "out": str(out), "parts": kept or "all"}
