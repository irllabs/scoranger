"""The words a PDF prints, put on the notes the scanner read them under.

A stage after OMR, the way `enrich` is a stage after the ABC reader. The
scanner (Audiveris) reads a page as an IMAGE -- the app rasterises a PDF
before sending it -- and reads words by OCR. On a MuseScore lead sheet that
came back with 11 of its 24 chord names, words run together ("bridgetown",
"Andshe"), and the four stanzas printed under the music hung on the last five
bars as verses 3 to 12. But a PDF that was ENGRAVED rather than scanned
carries every word it prints, exactly, with its position: its text layer.

WHAT THIS DOES WITH IT. The scanner's MusicXML says where every note is in its
own units (tenths), and the words it DID read correctly are on the page too.
Those words are the anchors: a straight-line fit from tenths to points, page
by page, from the scanner's syllables to the same syllables on the text
layer. On the Star of County Down 90 anchors fit to 0.1 pt vertically and
2 pt horizontally. Then, with every note's place on the page known:

  - each printed syllable goes on the note it is printed UNDER, verse by
    verse in the order the lines are printed, replacing what the scanner read
    on that staff;
  - each printed chord name goes on the note or rest it is printed OVER,
    replacing the scanner's chord symbols on that page;
  - every line printed below the music is TEXT, not a verse, and is reported.

The scanner's own reading is kept wherever this cannot be proved: a page
whose anchors do not fit, a staff with no printed words under it, a bar whose
notes the MusicXML and music21 count differently. Nothing here guesses a
note; a word that is not close enough to one is counted and left off.

A SCAN HAS NO TEXT LAYER, and the last rule still holds for it from the
scanner's positions alone: a line of words far below the last verse of its
staff is not a verse (`distant_verses`). That is what a stanza block or a
footer becomes otherwise.

What the text layer cannot say: where a hyphen is. Engravers draw it as a
line, not a character, so whether a syllable continues a word is taken from
the scanner where it read one there, and is otherwise "single".
"""

from __future__ import annotations

import math
import re
import statistics
import unicodedata
import zipfile
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path

#: a five-line staff is 40 tenths tall, by MusicXML's definition of a tenth
STAFF_TENTHS = 40.0
#: a black notehead is a little over one staff space wide
HEAD_TENTHS = 11.8
#: the first verse of a staff starts within this many tenths below it, and
#: each further verse within `NEXT_VERSE` of the one above. The Star's
#: verses sit 40 and 65 below the staff; its stanza block starts 210 below.
FIRST_VERSE = 120.0
NEXT_VERSE = 60.0
#: how far (points) a syllable's centre may be from its note's centre, and a
#: chord name's left edge from its note's, and still be that note's
WORD_REACH = 18.0
CHORD_REACH = 14.0
#: a page is lined up when this many anchors agree to within these residuals
MIN_ANCHORS = 4
MAX_RESIDUAL_X = 4.0
MAX_RESIDUAL_Y = 2.0


# -- the text layer -----------------------------------------------------------

@dataclass(frozen=True)
class Span:
    """One run of text the PDF draws: its words, where, how big, in what."""

    text: str
    #: left edge and baseline, in points from the page's top-left corner
    x: float
    y: float
    size: float
    font: str
    #: the order the page draws it in. A chord name's letters are drawn one
    #: after another, and pypdf can report the second one's x a point LEFT of
    #: the first ("m" before "E"), so its letters are joined in this order
    seq: int = 0

    @property
    def width(self) -> float:
        # An estimate. pypdf hands back decoded text, and for the Type0 fonts
        # engravers embed the glyph widths are keyed by glyph id, not by
        # character. Half an em per character is close for serif lowercase,
        # and only the CENTRE of a syllable is ever used.
        return 0.5 * self.size * len(self.text)

    @property
    def centre(self) -> float:
        return self.x + self.width / 2


def _mult(m, n):
    return [m[0] * n[0] + m[1] * n[2], m[0] * n[1] + m[1] * n[3],
            m[2] * n[0] + m[3] * n[2], m[2] * n[1] + m[3] * n[3],
            m[4] * n[0] + m[5] * n[2] + n[4], m[4] * n[1] + m[5] * n[3] + n[5]]


def _normal(text: str) -> str:
    # NFKC: a font draws "fi" as one ligature glyph and the text layer says
    # so ("ﬁxture"); a reader means two letters, and so does every match
    return unicodedata.normalize("NFKC", " ".join(text.split()))


@dataclass(frozen=True)
class Stroke:
    """A short horizontal line the page draws: (x0, x1, y) in points from the
    top-left. A lyric HYPHEN is one of these in every engraving looked at --
    a drawn line, not a character -- and nothing else says where they are."""

    x0: float
    x1: float
    y: float


def _strokes(page, reader) -> list[Stroke]:
    """Every horizontal stroke on a page under 30 pt long, in page coordinates."""
    from pypdf.generic import ContentStream

    box = page.mediabox
    top, left = float(box.top), float(box.left)
    ctm = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0]
    stack: list[list[float]] = []
    start = None
    out: list[Stroke] = []

    def at(x: float, y: float) -> tuple[float, float]:
        return (ctm[0] * x + ctm[2] * y + ctm[4], ctm[1] * x + ctm[3] * y + ctm[5])

    for operands, op in ContentStream(page.get_contents(), reader).operations:
        if op == b"q":
            stack.append(list(ctm))
        elif op == b"Q":
            ctm = stack.pop() if stack else [1.0, 0.0, 0.0, 1.0, 0.0, 0.0]
        elif op == b"cm":
            ctm = _mult([float(v) for v in operands], ctm)
        elif op == b"m":
            start = at(float(operands[0]), float(operands[1]))
        elif op == b"l" and start is not None:
            end = at(float(operands[0]), float(operands[1]))
            if abs(end[1] - start[1]) < 0.2 and 0.5 < abs(end[0] - start[0]) < 30:
                out.append(Stroke(min(start[0], end[0]) - left, max(start[0], end[0]) - left,
                                  top - start[1]))
            start = end
        elif op == b"re":
            x, y, w, h = (float(v) for v in operands)
            a, b = at(x, y), at(x + w, y + h)
            if abs(b[1] - a[1]) < 1.5 and 0.5 < abs(b[0] - a[0]) < 30:
                out.append(Stroke(min(a[0], b[0]) - left, max(a[0], b[0]) - left,
                                  top - (a[1] + b[1]) / 2))
    return out


@dataclass(frozen=True)
class Line:
    """One printed line of running text, as a reader would quote it."""

    text: str
    y: float
    x: float


def page_spans(pdf_path) -> list[tuple[list[Span], list[Line], list[Stroke]]]:
    """Every page's text, as spans and as lines, and its short strokes.

    No text layer: empty lists.

    The two readings differ in how pieces join. A SPAN is one run of text as
    drawn, which is what a syllable or a chord letter is. A LINE joins runs
    the way they read: pypdf starts every run after a position change with a
    space, which is wrong when the run begins exactly where the last one
    ended -- MuseScore draws an underlined syllable as its own run, so
    "onward" arrives as "on" and "ward". pypdf also reports each run's start
    as the start of its line, and reports the true position in the empty
    calls between runs, so that is where the joins are read from.
    """
    import pypdf

    reader = pypdf.PdfReader(str(pdf_path))
    pages: list[tuple[list[Span], list[Line], list[Stroke]]] = []
    for page in reader.pages:
        box = page.mediabox
        top = float(box.top)
        left = float(box.left)
        spans: list[Span] = []
        lines: list[list] = []          # [y, x, [pieces]]
        state = {"cursor": None, "end": None, "await_end": False}

        def visit(text, cm, tm, font_dict, font_size, spans=spans, lines=lines,
                  state=state, top=top, left=left):
            m = _mult(tm, cm)
            x, y = m[4] - left, top - m[5]
            if not text:
                if state["await_end"]:
                    state["end"], state["await_end"] = x, False
                state["cursor"] = x
                return
            if text.strip():
                size = float(font_size or 0) * math.hypot(m[0], m[1])
                font = ""
                if font_dict:
                    font = str(font_dict.get("/BaseFont", "")).lstrip("/")
                    font = font.split("+", 1)[-1]     # a subset prefix: ABCDEF+FreeSerif
                spans.append(Span(_normal(text), x, y, size, font, len(spans)))
            piece = text
            contiguous = (state["end"] is not None and state["cursor"] is not None
                          and abs(state["cursor"] - state["end"]) < 0.5)
            if lines and abs(lines[-1][0] - y) < 2.0 and "\n" not in text:
                if contiguous and piece.startswith(" "):
                    piece = piece[1:]
                lines[-1][2].append(piece)
            elif text.strip():
                lines.append([y, state["cursor"] if state["cursor"] is not None else x, [piece]])
            state["await_end"] = True

        try:
            page.extract_text(visitor_text=visit)
        except Exception:  # noqa: BLE001 -- a page pypdf cannot read is a page with no text
            spans, lines = [], []
        out_lines = [Line(_normal("".join(parts)), y, x) for y, x, parts in lines]
        try:
            strokes = _strokes(page, reader) if spans else []
        except Exception:  # noqa: BLE001 -- no strokes read means no hyphens read; the scanner's stand
            strokes = []
        pages.append((spans, [line for line in out_lines if line.text], strokes))
    return pages


# -- the scanner's layout -----------------------------------------------------

@dataclass
class Element:
    """One `<note>` that is not a chord's second note, and where it is."""

    part: int
    #: index of its measure within the part, and its index among the measure's
    #: notes and rests in document order -- music21's order too (see `_m21_index`)
    measure: int
    index: int
    page: int
    system: int
    #: left edge in tenths from the page's left
    x: float
    kind: str                   # "note", "rest" or "grace"
    step: str | None
    #: (verse, text, syllabic, tenths from the page's top)
    lyrics: list[tuple[int, str, str, float]] = field(default_factory=list)
    #: (chord name, tenths from the page's top)
    harmony: tuple[str, float] | None = None


@dataclass
class Staff:
    """One part's staff (or staves) in one system."""

    page: int
    system: int
    part: int
    top: float                  # tenths from the page's top
    bottom: float


@dataclass
class Layout:
    page_width: float
    page_height: float
    elements: list[Element]
    staves: list[Staff]
    #: measure indices of each (part, system)
    measures: dict[tuple[int, int], list[int]]


def read_xml(path) -> ET.Element:
    """The MusicXML root of a .mxl or .musicxml/.xml file."""
    source = Path(path)
    if source.suffix.lower() == ".mxl":
        with zipfile.ZipFile(source) as archive:
            names = [n for n in archive.namelist()
                     if n.lower().endswith((".xml", ".musicxml")) and not n.startswith("META-INF")]
            container = "META-INF/container.xml"
            if container in archive.namelist():
                rootfile = ET.fromstring(archive.read(container)).find(".//{*}rootfile")
                if rootfile is not None and rootfile.get("full-path"):
                    names = [rootfile.get("full-path")]
            return ET.fromstring(archive.read(names[0]))
    return ET.parse(source).getroot()


def _float(node, path: str, default: float | None = None) -> float | None:
    text = node.findtext(path) if node is not None else None
    try:
        return float(text) if text is not None else default
    except ValueError:
        return default


def _harmony_text(node) -> str | None:
    step = node.findtext("root/root-step")
    if not step:
        return None
    alter = node.findtext("root/root-alter") or ""
    accidental = {"1": "#", "-1": "b"}.get(alter.strip(), "")
    kind = node.find("kind")
    suffix = kind.get("text") if kind is not None and kind.get("text") is not None else ""
    bass = node.findtext("bass/bass-step")
    return f"{step}{accidental}{suffix}" + (f"/{bass}" if bass else "")


def read_layout(root: ET.Element) -> Layout:
    """Where the scanner put every note, system and staff, in tenths."""
    defaults = root.find("defaults")
    layout = defaults.find("page-layout") if defaults is not None else None
    page_width = _float(layout, "page-width", 1190.0)
    page_height = _float(layout, "page-height", 1683.0)
    margins = layout.find("page-margins") if layout is not None else None
    left_margin = _float(margins, "left-margin", 0.0)
    top_margin = _float(margins, "top-margin", 0.0)

    parts = root.findall("part")
    # pass 1: per part, per system -- which page, its print, its measures
    systems: list[list[dict]] = []
    for p, part in enumerate(parts):
        mine: list[dict] = []
        page, staves = 0, 1
        for m_index, measure in enumerate(part.findall("measure")):
            printed = measure.find("print")
            new_page = printed is not None and printed.get("new-page") == "yes"
            new_system = (m_index == 0 or new_page
                          or (printed is not None and printed.get("new-system") == "yes"))
            if new_page:
                page += 1
            for attributes in measure.findall("attributes"):
                staves = int(_float(attributes, "staves", staves) or staves)
            if new_system:
                system_layout = printed.find("system-layout") if printed is not None else None
                distances = {}
                if printed is not None:
                    for staff_layout in printed.findall("staff-layout"):
                        distances[int(staff_layout.get("number", "1"))] = _float(
                            staff_layout, "staff-distance", None)
                mine.append({
                    "page": page, "measures": [],
                    "left": _float(system_layout, "system-margins/left-margin", None),
                    "top_distance": _float(system_layout, "top-system-distance", None),
                    "system_distance": _float(system_layout, "system-distance", None),
                    "staff_distances": distances, "staves": staves,
                    "first_on_page": new_page or m_index == 0,
                })
            mine[-1]["measures"].append((m_index, measure))
        systems.append(mine)

    # pass 2: where each system's staves are, top to bottom
    count = min((len(s) for s in systems), default=0)
    staves_out: list[Staff] = []
    tops: dict[tuple[int, int], float] = {}
    bottom = 0.0
    last_left = 0.0
    lefts: list[float] = []
    for s in range(count):
        first = systems[0][s]
        if first["first_on_page"]:
            top = top_margin + (first["top_distance"] if first["top_distance"] is not None else 0.0)
        else:
            top = bottom + (first["system_distance"] if first["system_distance"] is not None else 80.0)
        last_left = first["left"] if first["left"] is not None else last_left
        lefts.append(last_left)
        for p in range(len(parts)):
            info = systems[p][s]
            if p > 0:
                distance = info["staff_distances"].get(1)
                top = bottom + (distance if distance is not None else 60.0)
            staff_bottom = top + STAFF_TENTHS
            for number in range(2, info["staves"] + 1):
                gap = info["staff_distances"].get(number)
                staff_bottom += (gap if gap is not None else 60.0) + STAFF_TENTHS
            tops[(p, s)] = top
            staves_out.append(Staff(info["page"], s, p, top, staff_bottom))
            bottom = staff_bottom

    # pass 3: every note's place, and the words the scanner hung on it
    elements: list[Element] = []
    measures: dict[tuple[int, int], list[int]] = {}
    for p in range(len(parts)):
        for s in range(count):
            info = systems[p][s]
            top = tops[(p, s)]
            x0 = left_margin + lefts[s]
            measures[(p, s)] = [m for m, _ in info["measures"]]
            for m_index, measure in info["measures"]:
                index = 0
                pending: tuple[str, float] | None = None
                for node in measure:
                    if node.tag == "harmony":
                        name = _harmony_text(node)
                        if name:
                            pending = (name, top - float(node.get("default-y") or 0.0))
                        continue
                    if node.tag != "note" or node.find("chord") is not None:
                        continue
                    kind = ("grace" if node.find("grace") is not None
                            else "rest" if node.find("rest") is not None else "note")
                    element = Element(p, m_index, index, info["page"], s,
                                      x0 + float(node.get("default-x") or 0.0), kind,
                                      node.findtext("pitch/step"))
                    for lyric in node.findall("lyric"):
                        text = _normal("".join(t.text or "" for t in lyric.findall("text")))
                        if text:
                            element.lyrics.append((
                                int(lyric.get("number") or 1), text,
                                lyric.findtext("syllabic") or "single",
                                top - float(lyric.get("default-y") or 0.0)))
                    if pending and kind != "grace":
                        element.harmony, pending = pending, None
                    elements.append(element)
                    index += 1
                x0 += float(measure.get("width") or 0.0)
    return Layout(page_width, page_height, elements, staves_out, measures)


def distant_verses(layout: Layout) -> dict[tuple[int, int], set[int]]:
    """Per (part, system), the verse numbers printed too far below to be verses.

    The scanner numbers every line of words under a staff as a verse, and a
    stanza block, a translation or a footer under the last system is a line
    of words under a staff. A verse sits directly below its staff or below
    the verse above it; a line that is neither is text.
    """
    by_staff: dict[tuple[int, int], dict[int, list[float]]] = {}
    for e in layout.elements:
        for verse, _, _, y in e.lyrics:
            by_staff.setdefault((e.part, e.system), {}).setdefault(verse, []).append(y)
    bottoms = {(st.part, st.system): st.bottom for st in layout.staves}
    out: dict[tuple[int, int], set[int]] = {}
    for key, verses in by_staff.items():
        line = bottoms.get(key)
        if line is None:
            continue
        reach = FIRST_VERSE
        far: set[int] = set()
        for verse, ys in sorted(verses.items(), key=lambda kv: statistics.median(kv[1])):
            y = statistics.median(ys)
            if far or y - line > reach:
                far.add(verse)
                continue
            line, reach = y, NEXT_VERSE
        if far:
            out[key] = far
    return out


# -- lining the page up -------------------------------------------------------

@dataclass(frozen=True)
class Fit:
    """points = a * tenths + b, on each axis, for one page."""

    ax: float
    bx: float
    ay: float
    by: float
    anchors: int
    residual_x: float
    residual_y: float

    def x(self, tenths: float) -> float:
        return self.ax * tenths + self.bx

    def y(self, tenths: float) -> float:
        return self.ay * tenths + self.by


def _line(pairs: list[tuple[float, float]]) -> tuple[float, float]:
    n = len(pairs)
    mx = sum(a for a, _ in pairs) / n
    my = sum(b for _, b in pairs) / n
    var = sum((a - mx) ** 2 for a, _ in pairs)
    if var <= 1e-9:
        return 0.0, my
    slope = sum((a - mx) * (b - my) for a, b in pairs) / var
    return slope, my - slope * mx


def fit_page(words: list[tuple[str, float, float, str]], spans: list[Span]) -> Fit | None:
    """Line the scanner's words up with the printed ones. None when they do not.

    `words` are the scanner's (text, x, baseline y, align) in tenths: a
    syllable by its CENTRE, because engravers centre one under its note, and
    a chord name by its LEFT edge, because they start one at its note -- so a
    lead sheet with chords and no words lines up too. The first fit uses only
    texts that occur ONCE on the page in both readings, which pair up without
    knowing anything about position; every later pass pairs each with the
    same text nearest where the fit puts it, and keeps only pairs that agree.
    """
    if not words or not spans:
        return None
    printed: dict[str, list[Span]] = {}
    for span in spans:
        printed.setdefault(span.text, []).append(span)
    # a chord name drawn a letter at a time ("E", "m") is matched whole
    for look in {(s.font, round(s.size)) for s in spans}:
        for row in _rows([s for s in spans if (s.font, round(s.size)) == look], 0.6):
            for token in _merge_glyphs(row):
                if token.text not in {s.text for s in row}:
                    printed.setdefault(token.text, []).append(token)

    def at(span: Span, align: str) -> float:
        return span.x if align == "left" else span.centre

    read: dict[str, int] = {}
    for text, *_ in words:
        read[text] = read.get(text, 0) + 1
    pairs = [(x, y, at(printed[t][0], a), printed[t][0].y) for t, x, y, a in words
             if read[t] == 1 and len(printed.get(t, [])) == 1]
    if len(pairs) < 3:
        pairs = _consensus(words, printed, at)
    if len(pairs) < 3:
        return None

    fit = None
    for tolerance in (None, 24.0, 10.0, 6.0):
        if tolerance is not None:
            pairs = []
            for t, x, y, a in words:
                px, py = fit.x(x), fit.y(y)
                near = [s for s in printed.get(t, [])
                        if abs(at(s, a) - px) < tolerance and abs(s.y - py) < tolerance]
                if near:
                    best = min(near, key=lambda s: math.hypot(at(s, a) - px, s.y - py))
                    pairs.append((x, y, at(best, a), best.y))
        if len(pairs) < 3:
            return None
        ax, bx = _line([(p[0], p[2]) for p in pairs])
        if max(p[1] for p in pairs) - min(p[1] for p in pairs) > 40:
            ay, by = _line([(p[1], p[3]) for p in pairs])
        else:
            # every anchor on one system says nothing about the vertical
            # scale; a page is scaled the same way up as across, so that is
            # taken from the horizontal and only the offset is fitted
            ay = ax
            by = statistics.median(p[3] - ax * p[1] for p in pairs)
        if ax <= 0 or ay <= 0:
            return None
        rx = statistics.median(abs(p[2] - (ax * p[0] + bx)) for p in pairs)
        ry = statistics.median(abs(p[3] - (ay * p[1] + by)) for p in pairs)
        fit = Fit(ax, bx, ay, by, len(pairs), rx, ry)
    if fit.anchors < MIN_ANCHORS or fit.residual_x > MAX_RESIDUAL_X or fit.residual_y > MAX_RESIDUAL_Y:
        return None
    return fit


def _consensus(words, printed: dict[str, list[Span]], at) -> list[tuple]:
    """Pairs for a first fit when few texts are unique, by agreement.

    A lead sheet's chord names repeat -- G, D, Em, G -- so the unique-text
    start finds too little to begin from. Every two readings of different
    texts, against every printed copy of each, propose a line; the one the
    most other readings land on (within 8 pt) wins and its agreeing pairs are
    returned. A wrong answer here is not applied: the fit it seeds has to
    pass the same residual test as any other.
    """
    best: list[tuple] = []
    for i, (t1, x1, y1, a1) in enumerate(words):
        for t2, x2, y2, a2 in words[i + 1:]:
            if t1 == t2 or abs(x2 - x1) < 40:
                continue
            for s1 in printed.get(t1, [])[:6]:
                for s2 in printed.get(t2, [])[:6]:
                    ax = (at(s2, a2) - at(s1, a1)) / (x2 - x1)
                    if ax <= 0:
                        continue
                    # one system tells nothing about the vertical scale; a
                    # page is printed the same way up and across
                    ay = (s2.y - s1.y) / (y2 - y1) if abs(y2 - y1) > 40 else ax
                    if ay <= 0 or not 0.7 < ay / ax < 1.4:
                        continue
                    bx, by = at(s1, a1) - ax * x1, s1.y - ay * y1
                    agree = []
                    for t, x, y, a in words:
                        px, py = ax * x + bx, ay * y + by
                        near = [s for s in printed.get(t, [])
                                if abs(at(s, a) - px) < 8 and abs(s.y - py) < 8]
                        if near:
                            hit = min(near, key=lambda s: abs(at(s, a) - px) + abs(s.y - py))
                            agree.append((x, y, at(hit, a), hit.y))
                    if len(agree) > len(best):
                        best = agree
    return best


# -- chord names --------------------------------------------------------------

#: A chord NAME, as engravers print one: a root, an optional accidental, and
#: then only the letters, digits and signs chord qualities are made of, with
#: an optional slash bass. Lexical only -- `chord_symbol` decides whether
#: music21 can hold it. "A" and "B" boxed as rehearsal marks pass this too,
#: which is why the chord FONT is decided by the page, not by the word.
_CHORD_NAME = re.compile(
    r"^[A-G](#|b|♯|♭)?(maj|min|m|M|dim|aug|sus|add|alt|o|ø|\+|-|[0-9]|#|b|♯|♭|\(|\)|,)*"
    r"(/[A-G](#|b|♯|♭)?)?$")


def is_chord_name(text: str) -> bool:
    return bool(_CHORD_NAME.match(text.replace(" ", "")))


def chord_symbol(text: str):
    """A music21 ChordSymbol for a printed chord name, or None."""
    from music21 import harmony

    from . import ops

    name = text.replace("♯", "#").replace("♭", "b").replace(" ", "")
    made = ops.chord_symbol_from_text(name)
    if made is not None:
        return made
    figure = re.sub(r"^([A-G])b", r"\1-", name)
    figure = re.sub(r"/([A-G])b", r"/\1-", figure)
    try:
        symbol = harmony.ChordSymbol(figure)
    except Exception:  # noqa: BLE001 -- music21 raises several kinds for a name it cannot read
        return None
    return symbol if symbol.pitches else None


def _rows(spans: list[Span], spread: float) -> list[list[Span]]:
    """Spans gathered into printed rows, each left to right."""
    rows: list[list[Span]] = []
    for span in sorted(spans, key=lambda s: s.y):
        if rows and abs(span.y - rows[-1][0].y) <= spread * max(span.size, rows[-1][0].size):
            rows[-1].append(span)
        else:
            rows.append([span])
    return [sorted(row, key=lambda s: s.x) for row in rows]


def _merge_glyphs(row: list[Span]) -> list[Span]:
    """A chord name drawn a letter at a time ("E", "m") made one span again.

    Joined in the order the page DRAWS them (`Span.seq`), which is the order
    of the letters, and only while each starts within the width of what came
    before it -- never across the gap to the next chord.
    """
    out: list[Span] = []
    for span in sorted(row, key=lambda s: s.seq):
        if out:
            last = out[-1]
            gap = span.x - last.x
            if -2.0 < gap < 0.8 * last.size * len(last.text) + 0.5:
                out[-1] = Span(last.text + span.text, min(last.x, span.x),
                               min(last.y, span.y), last.size, last.font, last.seq)
                continue
        out.append(span)
    return sorted(out, key=lambda s: s.x)


# -- the plan for one page ----------------------------------------------------

@dataclass
class PagePlan:
    #: (part, measure, index) -> [(verse, text, syllabic)] -- the WHOLE set of
    #: words those notes carry, on every staff in `word_staves`
    words: dict[tuple[int, int, int], list[tuple[int, str, str]]] = field(default_factory=dict)
    word_staves: set[tuple[int, int]] = field(default_factory=set)
    #: (part, measure, index) -> chord name, replacing every chord symbol on
    #: the parts in `chord_parts`
    chords: dict[tuple[int, int, int], str] = field(default_factory=dict)
    chord_staves: set[tuple[int, int]] = field(default_factory=set)
    below: list[str] = field(default_factory=list)
    fit: Fit | None = None
    unplaced_words: int = 0
    unplaced_chords: list[str] = field(default_factory=list)


#: Why a page kept the scanner's reading (`plan_page`). Only the first is
#: something the reader is told about (`pages_misaligned`).
MISALIGNED = "its printed words could not be lined up with the scanner's"
PRINTS_NONE = "it prints none of the words or chord names the scanner read"


def plan_page(layout: Layout, page: int, spans: list[Span], lines: list[Line],
              strokes: list[Stroke] = ()) -> tuple[PagePlan | None, str | None]:
    """What the text layer says this page's words and chords are. Writes nothing."""
    elements = [e for e in layout.elements if e.page == page]
    staves = sorted((st for st in layout.staves if st.page == page), key=lambda st: st.top)
    if not elements or not staves:
        return None, "the scanner found no music on this page"
    far = distant_verses(layout)
    anchors = [(text, e.x + HEAD_TENTHS / 2, y, "centre") for e in elements
               for verse, text, _, y in e.lyrics
               if verse not in far.get((e.part, e.system), set())]
    chord_anchors = [(e.harmony[0], e.x, e.harmony[1], "left") for e in elements if e.harmony]
    fit = fit_page(anchors + chord_anchors, spans)
    if fit is None:
        # Two different pages. One prints the words the scanner read and they
        # would not line up, which the reader is told. The other prints none
        # of them as text -- a tunebook whose only text is its header, its
        # music drawn as paths -- and has nothing to line up; telling that
        # reader their PDF's "printed words did not line up" describes words
        # that are not there (Ali, The Cat's Meow, 0.23.2).
        read = {text for text, *_ in anchors + chord_anchors}
        if read & {s.text for s in spans}:
            return None, MISALIGNED
        return None, PRINTS_NONE

    plan = PagePlan(fit=fit)
    # which font the words are printed in: the one the anchors are printed in
    matched_fonts: dict[str, int] = {}
    sizes: list[float] = []
    for text, x, y, _ in anchors:
        px, py = fit.x(x), fit.y(y)
        near = [s for s in spans if s.text == text and abs(s.centre - px) < 6 and abs(s.y - py) < 3]
        for s in near[:1]:
            matched_fonts[s.font] = matched_fonts.get(s.font, 0) + 1
            sizes.append(s.size)
    # A page lined up by its chord names alone has no word font: it has no
    # words, or none the scanner read, and its words are left as they are.
    word_font = max(matched_fonts, key=matched_fonts.get) if matched_fonts else None
    word_size = statistics.median(sizes) if sizes else 0.0

    staff_pt = [(st, fit.y(st.top), fit.y(st.bottom)) for st in staves]
    last_bottom = max(b for _, _, b in staff_pt)
    staff_height_pt = STAFF_TENTHS * fit.ay

    def staff_above(y: float):
        above = [(st, t, b) for st, t, b in staff_pt if t < y]
        return max(above, key=lambda item: item[1]) if above else None

    def staff_below(y: float):
        below = [(st, t, b) for st, t, b in staff_pt if t > y]
        return min(below, key=lambda item: item[1]) if below else None

    # -- the words --------------------------------------------------------
    word_rows = _rows([s for s in spans if word_font is not None and s.font == word_font
                       and abs(s.size - word_size) <= 0.2 * word_size], 0.3)
    rows_by_staff: dict[tuple[int, int], list[list[Span]]] = {}
    for row in word_rows:
        y = statistics.median(s.y for s in row)
        owner = staff_above(y)
        # BELOW the staff: an instrument's name is printed beside the first
        # system in the same font, and is not its first verse
        if owner is None or y <= owner[2]:
            continue
        st, _, bottom = owner
        rows_by_staff.setdefault((st.part, st.system), []).append(row)
    claimed: set[int] = set()
    open_words: dict[tuple[int, int], bool] = {}

    def hyphens(row: list[Span]) -> list[float]:
        """Where this row's hyphens are: drawn strokes at mid-letter height,
        and any hyphen printed as a character."""
        y = statistics.median(s.y for s in row)
        size = statistics.median(s.size for s in row)
        out = [(k.x0 + k.x1) / 2 for k in strokes
               if y - 0.6 * size < k.y < y - 0.1 * size and k.x1 - k.x0 < 1.5 * size]
        out += [s.centre for s in row if set(s.text) <= {"-", "–"}]
        return sorted(out)

    page_has_hyphens = any(hyphens(row) for row in word_rows)
    for st, _, bottom in staff_pt:
        key = (st.part, st.system)
        rows = sorted(rows_by_staff.get(key, []), key=lambda r: r[0].y)
        line, reach, verse = bottom, FIRST_VERSE * fit.ay, 0
        sung = sorted((e for e in elements if (e.part, e.system) == key and e.kind == "note"),
                      key=lambda e: e.x)
        if not rows or not sung:
            continue
        centres = [fit.x(e.x + HEAD_TENTHS / 2) for e in sung]
        for row in rows:
            y = statistics.median(s.y for s in row)
            if y - line > reach:
                break
            line, reach, verse = y, NEXT_VERSE * fit.ay, verse + 1
            claimed.add(id(row))
            plan.word_staves.add(key)
            placed: dict[int, list[str]] = {}
            drawn = hyphens(row)
            for span in row:
                if set(span.text) <= {"_", "-", "–", "—"}:
                    continue
                nearest = min(range(len(sung)), key=lambda i: abs(centres[i] - span.centre))
                if abs(centres[nearest] - span.centre) > WORD_REACH:
                    plan.unplaced_words += 1
                    continue
                placed.setdefault(nearest, []).append(span.text)
            order = sorted(placed)
            for n_placed, i in enumerate(order):
                e = sung[i]
                text = " ".join(placed[i])
                if page_has_hyphens:
                    # the page draws its hyphens: one between this syllable
                    # and the next is the word going on; past the last
                    # syllable of the line, it goes on into the next system
                    after = centres[order[n_placed + 1]] if n_placed + 1 < len(order) else math.inf
                    hyphen_after = any(centres[i] < h < after for h in drawn)
                    hyphen_before = open_words.get((e.part, verse), False)
                    syllabic = ({(False, False): "single", (False, True): "begin",
                                 (True, True): "middle", (True, False): "end"}
                                [(hyphen_before, hyphen_after)])
                    open_words[(e.part, verse)] = hyphen_after
                    plan.words.setdefault((e.part, e.measure, e.index), []).append(
                        (verse, text, syllabic))
                    continue
                # The scanner reads a hyphen from the page, so its syllabic
                # says whether one follows. Its own reading of THIS syllable
                # is the best witness, even when it hung it a note away;
                # failing that, whatever it read under this note.
                same = [(abs(j - i), s) for j, o in enumerate(sung) if abs(j - i) <= 2
                        for v, t, s, _ in o.lyrics if v == verse and t == text]
                scanner = (min(same)[1] if same else
                           next((s for v, _, s, _ in e.lyrics if v == verse), None))
                hyphen_after = scanner in ("begin", "middle")
                hyphen_before = open_words.get((e.part, verse), False)
                syllabic = ({(False, False): "single", (False, True): "begin",
                             (True, True): "middle", (True, False): "end"}
                            [(hyphen_before, hyphen_after)])
                open_words[(e.part, verse)] = hyphen_after
                plan.words.setdefault((e.part, e.measure, e.index), []).append(
                    (verse, text, syllabic))

    # -- the chord names --------------------------------------------------
    # Chord names are told from everything else printed above a staff by
    # their LOOK: one font at one size, nearly all of it chord names. Not by
    # font alone -- MuseScore 4 prints lyrics and chord names both in Edwin --
    # so the rows already read as verses are taken out first. A music font's
    # glyphs (noteheads, clefs) are text to a PDF too, in the Private Use Area
    # SMuFL puts them in, and are never a chord name.
    verse_spans = {id(s) for row in word_rows if id(row) in claimed for s in row}
    candidates = [s for s in spans if id(s) not in verse_spans
                  and not any(0xE000 <= ord(c) <= 0xF8FF for c in s.text)]
    by_font: dict[tuple[str, int], list[Span]] = {}
    for look in {(s.font, round(s.size)) for s in candidates}:
        for row in _rows([s for s in candidates if (s.font, round(s.size)) == look], 0.6):
            for token in _merge_glyphs(row):
                owner = staff_below(token.y)
                if owner is not None and owner[1] - token.y <= 4 * staff_height_pt:
                    by_font.setdefault(look, []).append(token)
    scanner_chords = {(e.harmony[0]) for e in elements if e.harmony}
    best_font, best_score = None, (0, 0)
    for font, tokens in by_font.items():
        names = [t for t in tokens if is_chord_name(t.text)]
        if len(tokens) < 3 or len(names) < 0.9 * len(tokens):
            continue
        agree = sum(1 for t in names if t.text in scanner_chords)
        score = (agree, len(names))
        if score > best_score:
            best_font, best_score = font, score
    if best_font is not None:
        for token in by_font[best_font]:
            if not is_chord_name(token.text):
                continue            # a credit or a title set in the same look
            owner = staff_below(token.y)
            if owner is None:
                continue
            st = owner[0]
            here = [e for e in elements if (e.part, e.system) == (st.part, st.system)
                    and e.kind in ("note", "rest")]
            if not here:
                plan.unplaced_chords.append(token.text)
                continue
            nearest = min(here, key=lambda e: abs(fit.x(e.x) - token.x))
            if abs(fit.x(nearest.x) - token.x) > CHORD_REACH:
                plan.unplaced_chords.append(token.text)
                continue
            key = (nearest.part, nearest.measure, nearest.index)
            plan.chords[key] = token.text
            plan.chord_staves.add((st.part, st.system))
        # every staff on the page that the chord font is printed over is
        # the text layer's; a staff it is printed over nowhere keeps nothing
        # the scanner invented only if the scanner put chords there
        for st in staves:
            if any(e.harmony for e in elements if (e.part, e.system) == (st.part, st.system)):
                plan.chord_staves.add((st.part, st.system))

    # -- what is printed below the music ----------------------------------
    verse_ys = [statistics.median(s.y for s in row) for row in word_rows if id(row) in claimed]
    for line in sorted(lines, key=lambda l: (l.x > 0.5 * max(s.x for s in spans), l.y)):
        if line.y > last_bottom + staff_height_pt and not any(abs(line.y - y) < 2 for y in verse_ys):
            plan.below.append(line.text)
    return plan, None


# -- applying it --------------------------------------------------------------

def _m21_index(score) -> dict[tuple[int, int], list]:
    """(part, measure index) -> its notes and rests in document order."""
    from music21 import harmony, stream

    out: dict[tuple[int, int], list] = {}
    for p, part in enumerate(score.parts):
        for m, measure in enumerate(part.getElementsByClass(stream.Measure)):
            out[(p, m)] = [n for n in measure.recurse().notesAndRests
                           if not isinstance(n, harmony.Harmony)]
    return out


def _agrees(raw: list[Element], held: list) -> bool:
    if len(raw) != len(held):
        return False
    for e, n in zip(raw, held):
        if e.kind == "rest" and not n.isRest:
            return False
        if e.kind != "rest" and n.isRest:
            return False
        if e.step and not n.isRest and e.step not in {p.step for p in n.pitches}:
            return False
    return True


def correct(score, notation_path, pdf_path) -> dict:
    """Put the PDF's own words and chord names on a score the scanner read.

    `score` is the music21 score parsed from `notation_path`, which is the
    scanner's MusicXML for `pdf_path`. Edited in place. Returns the report.
    With no PDF (or none with a text layer), only the rules that need the
    scanner's positions alone are applied: lines below a staff's verses are
    not verses, and text below a page's first system is not a credit.
    """
    from music21 import harmony
    from music21 import note as m21note

    from . import ops

    root = read_xml(notation_path)
    layout = read_layout(root)
    unreadable = None
    spans_by_page: list = []
    if pdf_path is not None:
        try:
            spans_by_page = page_spans(pdf_path)
        except Exception as exc:  # noqa: BLE001 -- an unreadable PDF has no text layer to use
            unreadable = str(exc)

    held = _m21_index(score)
    raw: dict[tuple[int, int], list[Element]] = {}
    for e in layout.elements:
        raw.setdefault((e.part, e.measure), []).append(e)
    usable = {key for key, elements in raw.items() if _agrees(elements, held.get(key, []))}

    far = distant_verses(layout)
    report: dict = {"text_layer": any(page[0] for page in spans_by_page), "pages_lined_up": 0,
                    "pages_not_lined_up": [], "pages_misaligned": 0, "syllables": 0,
                    "syllables_scanner_read": 0, "syllables_as_scanned": 0,
                    "lines_not_verses": sum(len(v) for v in far.values()),
                    "chords": 0, "chords_scanner_read": 0,
                    "chords_unplaced": [], "text_below_music": [],
                    "measures_not_matched": len(raw) - len(usable)}
    if unreadable:
        report["pdf_unreadable"] = unreadable
    report["chords_scanner_read"] = sum(1 for e in layout.elements if e.harmony)

    pages = sorted({e.page for e in layout.elements})
    plans: dict[int, PagePlan] = {}
    for page in pages:
        if page < len(spans_by_page) and spans_by_page[page][0]:
            plan, why = plan_page(layout, page, *spans_by_page[page])
            if plan is not None:
                plans[page] = plan
                report["pages_lined_up"] += 1
                continue
            report["pages_not_lined_up"].append({"page": page + 1, "reason": why})
            report["pages_misaligned"] += why == MISALIGNED

    for (part, system), measure_list in layout.measures.items():
        page = next((e.page for e in layout.elements if (e.part, e.system) == (part, system)), None)
        plan = plans.get(page)
        for m in measure_list:
            if (part, m) not in usable:
                continue
            elements = raw[(part, m)]
            notes = held[(part, m)]
            for e, n in zip(elements, notes):
                key = (part, m, e.index)
                if plan is not None and (part, system) in plan.word_staves:
                    read = {(int(l.number), l.text) for l in ops.word_verses(n)}
                    for lyric in ops.word_verses(n):
                        n.lyrics.remove(lyric)
                    for verse, text, syllabic in plan.words.get(key, []):
                        n.lyrics.append(m21note.Lyric(text=text, number=verse,
                                                      syllabic=syllabic, applyRaw=True))
                        report["syllables"] += 1
                        report["syllables_as_scanned"] += (verse, text) in read
                    report["syllables_scanner_read"] += len(read)
                elif (part, system) in far:
                    for lyric in ops.word_verses(n):
                        if int(lyric.number) in far[(part, system)]:
                            n.lyrics.remove(lyric)
            if plan is not None and (part, system) in plan.chord_staves:
                measure = notes[0].getContextByClass("Measure") if notes else None
                if measure is None:
                    continue
                for old in list(measure.recurse().getElementsByClass(harmony.ChordSymbol)):
                    old.activeSite.remove(old)
                for e, n in zip(elements, notes):
                    name = plan.chords.get((part, m, e.index))
                    if not name:
                        continue
                    symbol = chord_symbol(name)
                    if symbol is None:
                        report["chords_unplaced"].append(name)
                        continue
                    measure.insert(n.getOffsetInHierarchy(measure), symbol)
                    report["chords"] += 1
    for plan in plans.values():
        report["chords_unplaced"].extend(plan.unplaced_chords)
        report["text_below_music"].extend(plan.below)
    if not plans:
        # no page could be read from its text layer; the scanner's positions
        # still say which lines are not verses
        report["text_below_music"] = _far_text(layout, far)
    report["credits_dropped"] = drop_low_credits(score, layout)
    report["credits_corrected"] = correct_credits(
        score, layout, {page: (spans_by_page[page][1], plan.fit)
                        for page, plan in plans.items()})
    return report


def correct_credits(score, layout: Layout, printed: dict) -> list[str]:
    """The title and composer as the page prints them. Returns what changed.

    OCR reads "fixture" as "ﬁxture", with the ligature the font drew. On a
    page whose text lines up, the credit takes the printed line nearest it
    when the two say the same thing once both are folded to plain letters
    (NFKC); on a scan, the fold alone. The score's metadata follows a title
    or composer it was copied from.
    """
    import difflib

    from music21 import text as m21text

    changed: list[str] = []
    md = score.metadata
    for box in score.getElementsByClass(m21text.TextBox):
        old = str(box.content)
        new = unicodedata.normalize("NFKC", old)
        page = int(getattr(box, "page", 1) or 1) - 1
        y = getattr(box.style, "absoluteY", None)
        if page in printed and y is not None:
            lines, fit = printed[page]
            at = fit.y(layout.page_height - float(y))
            near = [l for l in lines if abs(l.y - at) < 12]
            best = max(near, key=lambda l: difflib.SequenceMatcher(None, l.text, new).ratio(),
                       default=None)
            if best is not None and difflib.SequenceMatcher(None, best.text, new).ratio() >= 0.8:
                new = best.text
        if new != old:
            box.content = new
            changed.append(f"{old} -> {new}")
            if md is not None:
                for field_name in ("title", "movementName", "composer"):
                    if getattr(md, field_name, None) == old:
                        setattr(md, field_name, new)
    return changed


def drop_low_credits(score, layout: Layout) -> list[str]:
    """Remove page text the scanner read BELOW a page's first system. Returns it.

    A title, a subtitle, a composer and a lyricist are printed above the
    music. Everything the scanner calls a credit further down the page is
    something else it read as one -- on the Star, a bar number ("5"), two
    lines of a stanza and the footer's web address, which Verovio then
    engraved at the TOP of the page above the title. Positions only, so a
    scan is held to it too. MusicXML measures a credit up from the page's
    foot; the layout measures down from its head.
    """
    from music21 import text as m21text

    firsts: dict[int, float] = {}
    for staff in layout.staves:
        firsts[staff.page] = min(firsts.get(staff.page, staff.top), staff.top)
    dropped: list[str] = []
    for box in list(score.getElementsByClass(m21text.TextBox)):
        page = int(getattr(box, "page", 1) or 1) - 1
        y = getattr(box.style, "absoluteY", None)
        if page not in firsts or y is None:
            continue
        if layout.page_height - float(y) > firsts[page]:
            dropped.append(str(box.content))
            score.remove(box)
    return dropped


def _far_text(layout: Layout, far: dict[tuple[int, int], set[int]]) -> list[str]:
    lines: dict[tuple[int, int, int], list[tuple[float, str]]] = {}
    for e in layout.elements:
        for verse, text, _, _ in e.lyrics:
            if verse in far.get((e.part, e.system), set()):
                lines.setdefault((e.part, e.system, verse), []).append((e.x, text))
    return [" ".join(t for _, t in sorted(words)) for _, words in sorted(lines.items())]
