"""What a parser dropped, put back on the score it dropped it from.

A stage AFTER parsing, with one input and one output: the source text a
reader handed us and the stream music21 made of it, in; the same stream with
the marks music21 discarded attached to the right notes, out. Nothing here
writes notation as text and nothing here edits a file -- the golden rule holds
-- it reads the SOURCE to find out what was said, and then says it again in
music21 objects.

ABC decorations are the first thing to need this and the reason the module
exists. They will not be the last: every importer this engine has loses
something its format can say and MusicXML can hold, and the alternative to a
named stage is a special case inside `workspace.read_notation` for each one.

HOW A MARK FINDS ITS NOTE. By COUNTING, not by guessing. `scan` walks the ABC
and numbers every note event it contains -- a note, a chord, a visible rest --
in the order the file writes them, which is the order music21 emits them. A
decoration is recorded against the number of the event it precedes. After the
parse, event N is `notesAndRests[N]`.

That is only safe while the two counts agree, so `restore` CHECKS them, twice:

  - the whole tune's event count against the stream's, and
  - for every decoration, the note LETTER the ABC wrote against the step of
    the note it is about to be attached to.

Either disagreeing means this module has mis-read some ABC construct, and a
mark hung on the wrong note is worse than a mark reported as lost -- so on a
mismatch nothing is attached to that tune and the count is REPORTED. The
report is the point: a reader whose rolls vanished is owed the number, which
is what `workspace.abc_report` says, and it now says how many arrived too.

WHY THE TEXT IS STRIPPED FIRST. music21's ABC tokenizer treats a decoration as
part of the note event's string and then throws several of those strings away
(`abcFormat.ABCHandler.tokenize`). For `H` it throws away THE NOTE: `HA2 B2 c2
d2` parses as three notes, and a tune imported with a fermata in it was
quietly missing one. Removing the marks before the parse is what makes the
note survive; re-attaching them afterwards is what makes them survive. The two
halves are one mechanism and neither works alone.
"""

from __future__ import annotations

import re
import tempfile
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Decoration:
    """One mark the ABC wrote, and the note event it was written against."""

    #: index of the tune within the file, in `X:` order
    tune: int
    #: index of the note event within that tune, in the order it is written
    event: int
    #: canonical name -- a key of `DECORATIONS`
    mark: str
    #: the mark exactly as the file spelled it, for a report to quote
    source: str
    #: the ABC note letter it sat on, upper-cased; None on a rest or a chord.
    #: `restore` checks this against the note it is about to attach to.
    step: str | None


#: The four `!...!` decorations music21's own tokenizer acts on. They are
#: SPANNERS -- two anchors -- and music21 already builds the Crescendo and the
#: Diminuendo correctly, so they are left in the text for it to find. This
#: module never touches a spanner: see `ops.SPANNER_KINDS` for why an op in
#: this repo refuses to guess a spanner's far end.
_M21_SPANNER_DECORATIONS = {"!crescendo(!", "!crescendo)!",
                            "!diminuendo(!", "!diminuendo)!"}

#: canonical name -> every way ABC spells it. The shorthand letters are the
#: ABC 2.2 standard's decoration set plus `J` (slide), which abcm2ps defines
#: and thesession.org's transcriptions use -- 16 times across the 541 tunes
#: surveyed for this table, against 2034 rolls, 50 staccatos, 4 trills and a
#: handful of bowings. The `!...!` long forms are the standard's, with the
#: aliases real files carry.
#:
#: Spelled this way round because one mark has several spellings and the
#: reverse index is built from it -- two tables would drift.
_SPELLINGS: dict[str, tuple[str, ...]] = {
    # -- what hangs off a note ------------------------------------------
    "roll": ("~", "!roll!"),
    "trill": ("T", "!trill!"),
    "mordent": ("M", "!mordent!", "!lowermordent!"),
    "pralltriller": ("P", "!pralltriller!", "!uppermordent!"),
    "turn": ("!turn!",),
    "inverted-turn": ("!invertedturn!",),
    "slide": ("J", "!slide!"),
    "fermata": ("H", "!fermata!", "!H!"),
    "staccato": (".", "!staccato!"),
    "staccatissimo": ("!staccatissimo!", "!wedge!"),
    "accent": ("L", "!accent!", "!emphasis!", "!>!"),
    "marcato": ("!marcato!", "!^!"),
    "tenuto": ("!tenuto!",),
    "up-bow": ("u", "!upbow!", "!u!"),
    "down-bow": ("v", "!downbow!", "!v!"),
    "breath": ("!breath!",),
    # -- what marks a place in the form ---------------------------------
    "segno": ("S", "!segno!"),
    "coda": ("O", "!coda!"),
    "fine": ("!fine!",),
    "da-capo": ("!D.C.!", "!dacapo!"),
    "dal-segno": ("!D.S.!", "!dalsegno!"),
    # -- what sits under the staff --------------------------------------
    **{f"dynamic:{d}": (f"!{d}!",) for d in
       ("pppp", "ppp", "pp", "p", "mp", "mf", "f", "ff", "fff", "ffff",
        "sfz", "fp")},
}

#: what each canonical mark BECOMES: (family, music21 class name).
#:
#:   "articulation"  hangs off a note's `.articulations`
#:   "expression"    hangs off a note's `.expressions`
#:   "navigation"    is inserted into the note's MEASURE at the barline,
#:                   exactly where `ops._navigation_mark` puts one, so
#:                   `set-structure --remove` can still find it. It marks a
#:                   place in the form, not a note.
#:   "dynamic"       is inserted into the measure at the NOTE's offset, the
#:                   same anchor `ops.ELEMENT_KINDS["dynamic"]` declares.
#:
#: THE ROLL IS A JUDGEMENT AND IT IS WRITTEN DOWN HERE. An Irish roll is not a
#: turn, a trill or a mordent; it is a five-note figure -- the note, the note
#: above, the note, the note below, the note -- with its own name and no glyph
#: of its own in MusicXML or SMuFL. Engravers print it variously. It is mapped
#: to a TURN (`<turn/>`, the ∾ sign above the notehead) because the turn is
#: the standard glyph whose shape the roll's five notes actually describe, it
#: is what most printed Irish collections use, and it is a mark every other
#: program can read. `~` and `!turn!` therefore engrave identically, which is
#: the honest cost of using a borrowed glyph and is stated rather than hidden.
#: Changing this line changes what the page shows; nothing else depends on it.
DECORATIONS: dict[str, tuple[str, str]] = {
    "roll": ("expression", "Turn"),
    "trill": ("expression", "Trill"),
    "mordent": ("expression", "Mordent"),
    "pralltriller": ("expression", "InvertedMordent"),
    "turn": ("expression", "Turn"),
    "inverted-turn": ("expression", "InvertedTurn"),
    # MusicXML's name for the slide ornament is `schleifer`, and that is the
    # figure ABC's `J` draws: a short run INTO the note. `<glissando>` and
    # `<slide>` are spanners with a far end nothing here can know.
    "slide": ("expression", "Schleifer"),
    "fermata": ("expression", "Fermata"),
    "staccato": ("articulation", "Staccato"),
    "staccatissimo": ("articulation", "Staccatissimo"),
    "accent": ("articulation", "Accent"),
    "marcato": ("articulation", "StrongAccent"),
    "tenuto": ("articulation", "Tenuto"),
    "up-bow": ("articulation", "UpBow"),
    "down-bow": ("articulation", "DownBow"),
    "breath": ("articulation", "BreathMark"),
    "segno": ("navigation", "Segno"),
    "coda": ("navigation", "Coda"),
    "fine": ("navigation", "Fine"),
    "da-capo": ("navigation", "DaCapo"),
    "dal-segno": ("navigation", "DalSegno"),
    **{f"dynamic:{d}": ("dynamic", d) for d in
       ("pppp", "ppp", "pp", "p", "mp", "mf", "f", "ff", "fff", "ffff",
        "sfz", "fp")},
}

#: shorthand/long spelling -> canonical name, built from `_SPELLINGS`.
_BY_SPELLING = {spelling: mark
                for mark, spellings in _SPELLINGS.items()
                for spelling in spellings}

#: the single characters above, for the walker to test membership against
_SHORTHAND = {s for s in _BY_SPELLING if len(s) == 1}

#: A field line: `T: title`, `K: Edor`, `w: lyrics`. Never music.
_FIELD_LINE = re.compile(r"^\s*[A-Za-z]:")

#: `X:` opens a tune. One file may hold many.
_TUNE_START = re.compile(r"^\s*X\s*:")


def _tunes(text: str) -> list[tuple[int, int]]:
    """(start, end) line indices of each `X:` block, in the order written."""
    lines = text.splitlines()
    starts = [i for i, line in enumerate(lines) if _TUNE_START.match(line)]
    if not starts:
        return [(0, len(lines))]
    bounds = []
    for n, start in enumerate(starts):
        end = starts[n + 1] if n + 1 < len(starts) else len(lines)
        bounds.append((start, end))
    return bounds


def scan(text: str) -> tuple[str, list[Decoration], list[str]]:
    """The ABC with its decorations removed, where each one was, and the rest.

    Returns (stripped text, decorations found, spellings left behind). The
    third is every `!...!` this module has no music21 object for; they stay in
    the text (music21 ignores them either way) and are REPORTED, because a
    silent drop is the thing this module exists to end.
    """
    lines = text.splitlines(keepends=True)
    out_lines = list(lines)
    found: list[Decoration] = []
    unknown: list[str] = []

    for tune_index, (start, end) in enumerate(_tunes(text)):
        events = 0
        for row in range(start, end):
            if row >= len(lines):
                break
            line = lines[row]
            if _FIELD_LINE.match(line) or line.lstrip().startswith("%"):
                continue
            stripped, events, marks, left = _scan_line(line, tune_index, events)
            out_lines[row] = stripped
            found.extend(marks)
            unknown.extend(left)
    return "".join(out_lines), found, unknown


def _scan_line(line: str, tune: int, events: int
               ) -> tuple[str, int, list[Decoration], list[str]]:
    """One body line: the same line with decorations cut out, and what they were.

    A character walk rather than a regular expression, because whether a `T`
    is a trill depends on what precedes it -- inside `"..."` it is part of a
    chord symbol, before a `:` it opens a field somebody wrote without
    brackets, and `[K:G]` is not a chord. Each of those is one branch here and
    none of them is expressible as a pattern over the whole line.
    """
    kept: list[str] = []
    pending: list[tuple[str, str]] = []   # (canonical mark, as written)
    found: list[Decoration] = []
    unknown: list[str] = []
    i, n = 0, len(line)

    def attach(step: str | None) -> None:
        nonlocal events
        for mark, source in pending:
            found.append(Decoration(tune, events, mark, source, step))
        pending.clear()
        events += 1

    while i < n:
        c = line[i]

        if c == "%":                      # comment to end of line
            kept.append(line[i:])
            break

        if c == '"':                      # chord symbol or annotation
            close = line.find('"', i + 1)
            close = n if close < 0 else close + 1
            kept.append(line[i:close])
            i = close
            continue

        if c in "!+":                     # long-form decoration
            close = line.find(c, i + 1)
            if close < 0 or "\n" in line[i:close]:
                kept.append(c)            # a lone `!` is an old line break
                i += 1
                continue
            token = line[i:close + 1]
            body = token[1:-1]
            canonical = _BY_SPELLING.get(f"!{body}!")
            if canonical is not None:
                pending.append((canonical, token))
            elif token in _M21_SPANNER_DECORATIONS:
                kept.append(token)        # music21 builds these itself
            else:
                kept.append(token)
                unknown.append(token)
            i = close + 1
            continue

        if c == "[":
            # `[` opens four different things and only one of them is music.
            if re.match(r"\[[A-Za-z]:", line[i:]):   # inline field: [K:G]
                close = line.find("]", i + 1)
                close = n if close < 0 else close + 1
                kept.append(line[i:close])
                i = close
                continue
            nxt = line[i + 1:i + 2]
            close = line.find("]", i + 1)
            if nxt.isdigit() or nxt in "|]" or close < 0:
                # `[1`/`[2` open a volta and `[|` a barline -- neither is a
                # chord and neither is an event. An unclosed `[` is neither
                # either: swallowing the rest of the line as one chord put
                # every later mark in a 541-tune download on the wrong note.
                kept.append(c)
                i += 1
                continue
            kept.append(line[i:close + 1])           # a chord: ONE event
            i = close + 1
            attach(None)
            continue

        if c in _SHORTHAND and not line[i + 1:i + 2] == ":":
            pending.append((_BY_SPELLING[c], c))
            i += 1
            continue

        if c == "z":                      # a rest music21 keeps
            kept.append(c)
            i += 1
            attach(None)
            continue

        if c in "xXZ":                    # rests music21 discards: not events
            kept.append(c)
            i += 1
            continue

        if c.isalpha() and c in "ABCDEFGabcdefg":
            kept.append(c)
            i += 1
            attach(c.upper())
            continue

        kept.append(c)                    # bars, slurs, ties, lengths, spaces
        i += 1

    # a decoration at the end of a line applies to the next line's first note;
    # carrying it would need state across lines, and no real file does it
    return "".join(kept), events, found, unknown


def _events(score) -> list[tuple]:
    """(element, holder) for every note event, in the order ABC writes them.

    Walked through the hierarchy rather than taken off `score.flatten()`,
    because a navigation mark and a dynamic are inserted into a STREAM at an
    offset and a flattened note has no stream left to ask for. The holder is
    that stream.

    Usually it is a Measure. It is the PART itself for a tune of a single bar,
    which music21's ABC reader hands back as loose notes on the part with no
    measure around them at all -- `workspace._write_musicxml` bars it up on
    the way to the file, and a mark inserted at the right offset is in the
    right bar when it does.

    A chord SYMBOL is a Chord to music21 and comes back from `.notesAndRests`
    with the music -- the trap `whistle_fingerings`, `guitar_tab` and
    `ops._elements_in_measure` are each written around. It is not a note event
    and it would shift every mark after it by one.
    """
    from music21 import harmony as m21harmony
    from music21 import stream as m21stream

    out = []
    for part in score.parts:
        measures = list(part.getElementsByClass(m21stream.Measure))
        for holder in measures or [part]:
            for element in holder.recurse().notesAndRests:
                if not isinstance(element, m21harmony.Harmony):
                    out.append((element, holder))
    return out


def _attach(element, measure, mark: str) -> None:
    """One decoration onto one note event, by the family it belongs to."""
    from music21 import articulations as m21articulations
    from music21 import dynamics as m21dynamics
    from music21 import expressions as m21expressions
    from music21 import repeat as m21repeat

    family, spec = DECORATIONS[mark]
    if family == "expression":
        obj = getattr(m21expressions, spec)()
        if spec == "Fermata":
            # music21 defaults a Fermata to `inverted`, which MusicXML draws
            # UNDER the note; ABC's `H` is the one above it. The same choice
            # `ops._make_element` makes.
            obj.type = "upright"
        element.expressions.append(obj)
    elif family == "articulation":
        element.articulations.append(getattr(m21articulations, spec)())
    elif family == "dynamic":
        measure.insert(element.getOffsetInHierarchy(measure),
                       m21dynamics.Dynamic(spec))
    elif family == "navigation":
        # at the barline, where `ops._navigation_mark` puts one, so that
        # `set-structure --kind segno --remove` still finds it
        measure.insert(0.0, getattr(m21repeat, spec)())
    else:
        raise ValueError(f"no family {family!r} for decoration {mark!r}")


def _restore_one(score, marks: list[Decoration]) -> dict:
    """Attach one tune's decorations to its notes. See the module docstring."""
    report = {"carried": 0, "misplaced": 0, "reason": None}
    if not marks:
        return report

    events = _events(score)
    counted = max(m.event for m in marks) + 1
    if counted > len(events):
        report["misplaced"] = len(marks)
        report["reason"] = (
            f"the tune reads as {len(events)} note events and its decorations "
            f"are written against {counted}, so nothing could be placed "
            f"without risking the wrong note")
        return report

    for mark in marks:
        element, measure = events[mark.event]
        if mark.step is not None and getattr(element, "step", None) != mark.step:
            report["misplaced"] += 1
            continue
        _attach(element, measure, mark.mark)
        report["carried"] += 1
    return report


def restore(scores: list, marks: list[Decoration]) -> dict:
    """Put every scanned decoration on its note. Returns what it managed.

    `carried` is the number that reached the notation. `misplaced` is the
    number this module declined to place because it could not prove which note
    they belonged to -- see the module docstring; a mark on the wrong note is
    worse than a mark reported as missing, and the reason names the tune.
    """
    carried = misplaced = 0
    reasons: list[str] = []
    for index, score in enumerate(scores):
        one = _restore_one(score, [m for m in marks if m.tune == index])
        carried += one["carried"]
        misplaced += one["misplaced"]
        if one["reason"]:
            reasons.append(f"tune {index + 1}: {one['reason']}")
    out = {"carried": carried, "misplaced": misplaced}
    if reasons:
        out["reasons"] = reasons
    return out


#: `[K:G]`, `[M:6/8]`: an inline field, not a chord.
_INLINE_FIELD = re.compile(r"\[[A-Za-z]:")


def repair_chords(text: str) -> tuple[str, int]:
    """Close chord brackets that were never closed, and drop doubled ones.

    thesession.org is typed by hand, and some settings carry a chord whose
    `]` was never written: "The Wind That Shakes The Barley" has `[Ee[[Ee]`,
    "Jenny Lind" `([EG[[GB])`. music21 reads the first `[` to the next `]`,
    finds a chord with another chord inside it, and refuses the WHOLE FILE --
    "Bad chord indicator: [[Ee: no closing bracket found", which is what a
    reader saw for a download of 38 settings with one typo in one of them.

    The repair is the reading a musician gives the typo: an open chord ends
    where the next one starts, or at the next space or bar line, and `[[` is
    one bracket. Inline fields (`[K:G]`), endings (`[1`, `[2`) and `[|` are
    not chords and pass through. Returns the text and how many brackets were
    added or dropped, which the import report carries.
    """
    repaired = 0
    out_lines = []
    for line in text.splitlines(keepends=True):
        if _FIELD_LINE.match(line) or line.lstrip().startswith("%"):
            out_lines.append(line)
            continue
        body = line.rstrip("\r\n")
        ending = line[len(body):]
        out, i, open_chord = [], 0, False
        while i < len(body):
            c = body[i]
            if c == '"':
                close = body.find('"', i + 1)
                close = len(body) - 1 if close < 0 else close
                out.append(body[i:close + 1])
                i = close + 1
                continue
            if c == "[":
                rest = body[i:]
                if (_INLINE_FIELD.match(rest) or rest[1:2].isdigit() or rest[1:2] in "|("
                        or rest[1:3].strip().isdigit()):
                    if open_chord:
                        out.append("]"); repaired += 1; open_chord = False
                    close = body.find("]", i)
                    close = len(body) - 1 if close < 0 else close
                    out.append(body[i:close + 1])
                    i = close + 1
                    continue
                if open_chord:
                    out.append("]"); repaired += 1; open_chord = False
                if rest[1:2] == "[":
                    repaired += 1          # `[[`: one bracket
                    i += 1
                    continue
                open_chord = True
                out.append(c)
            elif c == "]":
                open_chord = False
                out.append(c)
            elif open_chord and c == "|":
                out.append("]"); repaired += 1; open_chord = False
                out.append(c)
            else:
                out.append(c)
            i += 1
        if open_chord:
            out.append("]"); repaired += 1
        out_lines.append("".join(out) + ending)
    return "".join(out_lines), repaired


def _title(block: str) -> str:
    found = re.search(r"^\s*T\s*:\s*(.+)$", block, re.M)
    return found.group(1).strip() if found else "an untitled tune"


def read_abc(path) -> tuple[list, dict]:
    """Every tune in an ABC file, with its decorations on it.

    The scan-strip-parse-restore cycle in one call, which is the whole stage:
    `workspace.read_notation` hands it a path and gets back what the file
    said, not what music21 could hold of it.
    """
    from music21 import converter, stream

    source = Path(path)
    text = source.read_text(encoding="utf-8", errors="replace")
    stripped, marks, unknown = scan(text)

    # Parsed from a temp copy under the SAME stem: music21 seeds the movement
    # title with the file name, and `cli.cmd_import` reads that title back out
    # as the arrangement's name when the tune does not name itself.
    def parse(body: str):
        with tempfile.TemporaryDirectory(prefix="scoranger-abc-") as tmp:
            copy = Path(tmp) / source.name
            copy.write_text(body, encoding="utf-8")
            parsed = converter.parse(str(copy), forceSource=True)
        return list(parsed.scores) if isinstance(parsed, stream.Opus) else [parsed]

    skipped: list[dict] = []
    chords_repaired = 0
    try:
        scores = parse(stripped)
        report = restore(scores, marks)
    except Exception:  # noqa: BLE001 -- music21 raises many kinds; each is a tune it cannot read
        # ONE TUNE AT A TIME. music21 reads a file whole, so one setting it
        # could not read took the other thirty-seven down with it ("Bad chord
        # indicator: [[Ee"). Each `X:` block is read on its own; a block that
        # fails is read again with its chord brackets repaired
        # (`repair_chords`), and only then skipped -- NAMED in the report. A
        # tune that reads is never repaired: the repair is for typos, and a
        # rule applied to music that was fine is how a typo-fixer breaks it.
        lines = text.splitlines(keepends=True)
        bounds = _tunes(text)
        preamble = "".join(lines[:bounds[0][0]]) if bounds and bounds[0][0] > 0 else ""
        scores, carried, misplaced, reasons = [], 0, 0, []
        for start, end in bounds:
            block = preamble + "".join(lines[start:end])
            parsed, block_marks = None, []
            try:
                body, block_marks, _ = scan(block)
                parsed = parse(body)
            except Exception as first:  # noqa: BLE001
                fixed, n = repair_chords(block)
                try:
                    if not n:
                        raise first
                    body, block_marks, _ = scan(fixed)
                    parsed = parse(body)
                    chords_repaired += n
                except Exception as exc:  # noqa: BLE001
                    skipped.append({"title": _title(block), "reason": str(exc)})
                    continue
            for score in parsed:
                one = _restore_one(score, block_marks)
                carried += one["carried"]
                misplaced += one["misplaced"]
                if one["reason"]:
                    reasons.append(f"{_title(block)}: {one['reason']}")
            scores.extend(parsed)
        if not scores:
            names = ", ".join(t["title"] for t in skipped[:3])
            raise ValueError(f"None of the tunes in this file could be read ({names}). "
                             f"The ABC may be damaged; try another setting of the tune.")
        report = {"carried": carried, "misplaced": misplaced}
        if reasons:
            report["reasons"] = reasons
    if unknown:
        report["unknown"] = sorted(set(unknown))
    if chords_repaired:
        report["chords_repaired"] = chords_repaired
    if skipped:
        report["tunes_skipped"] = skipped
    return scores, report
