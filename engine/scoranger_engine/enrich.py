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
from dataclasses import dataclass, field
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


@dataclass
class _Walk:
    """What the lyric stage needs from the same walk the decorations take.

    Kept across a tune's lines, because a bar and a brace can both outlast
    the line they open on. `notes` is every note a syllable can land on --
    a note or a chord, never a rest or a grace note (ABC 2.1 §5.1) -- as
    (ABC note letter or None for a chord, bar index), in the order written.
    """

    bar: int = 0
    grace: bool = False
    notes: list[tuple[str | None, int]] = field(default_factory=list)


def _scan_line(line: str, tune: int, events: int, walk: _Walk | None = None
               ) -> tuple[str, int, list[Decoration], list[str]]:
    """One body line: the same line with decorations cut out, and what they were.

    A character walk rather than a regular expression, because whether a `T`
    is a trill depends on what precedes it -- inside `"..."` it is part of a
    chord symbol, before a `:` it opens a field somebody wrote without
    brackets, and `[K:G]` is not a chord. Each of those is one branch here and
    none of them is expressible as a pattern over the whole line.

    `walk`, when given, is told where the bars and the lyric-bearing notes
    are, so `scan_lyrics` counts notes by the same grammar the decorations are
    counted by. It changes nothing this function returns.
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

    def sung(step: str | None) -> None:
        if walk is not None and not walk.grace:
            walk.notes.append((step, walk.bar))

    while i < n:
        c = line[i]

        if c == "%":                      # comment to end of line
            kept.append(line[i:])
            break

        if c in "{}":                     # grace notes take no syllable
            if walk is not None:
                walk.grace = c == "{"
            kept.append(c)
            i += 1
            continue

        if c == "|" or (c == ":" and line[i + 1:i + 2] in ("|", ":")):
            # ONE barline however it is spelled: `|`, `||`, `|]`, `:|`, `|:`,
            # `::`. A `[|` reaches here as its `|`, the `[` kept below.
            j = i
            while j < n and line[j] in "|:]":
                j += 1
            kept.append(line[i:j])
            i = j
            if walk is not None:
                walk.bar += 1
            continue

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
            sung(None)
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
            sung(c.upper())
            continue

        kept.append(c)                    # bars, slurs, ties, lengths, spaces
        i += 1

    # a decoration at the end of a line applies to the next line's first note;
    # carrying it would need state across lines, and no real file does it
    return "".join(kept), events, found, unknown


# -- lyrics -----------------------------------------------------------------
#
# music21's ABC reader parses `w:` lines and keeps none of them (10.5: the
# tokenizer collects the field and nothing turns it into a Lyric), so a song
# from thesession.org or anywhere else imported as a tune with no words. The
# same scan-then-restore shape as the decorations, with the ABC 2.1 §5 rules:
#
#   - a syllable lands on a NOTE or a CHORD; rests and grace notes take none,
#     and every note of a tie takes its own (§5.1);
#   - a `w:` covers the notes written since the notes the previous `w:`
#     covered, up to the line it is on -- not only the line above it;
#   - ADJACENT `w:` lines are VERSES over the same notes (§5.2), and `+:`
#     continues the line before it;
#   - `-` breaks a word into syllables, `_` holds the last syllable over one
#     more note, `*` skips a note, `~` is a space that keeps words on one
#     note, `\-` is a printed hyphen, `|` moves on to the next bar if the
#     syllables have not reached it already;
#   - a first word that is a number ("1.") is the stanza number and is
#     printed in front of the first syllable rather than taking a note (§5.3).
#
# What music21 cannot hold: the extender line `_` draws. A held syllable
# leaves its extra notes with no syllable, which is the reading; the line is
# not drawn.

_LYRIC_LINE = re.compile(r"^\s*w\s*:(.*)$")
_LYRIC_CONTINUATION = re.compile(r"^\s*\+\s*:(.*)$")
_WORDS_LINE = re.compile(r"^\s*W\s*:(.*)$")
_VOICE = re.compile(r"(^\s*V\s*:)|(\[V:)")
_STANZA = re.compile(r"^\d+[.)]?$")


@dataclass(frozen=True)
class LyricBlock:
    """One run of adjacent `w:` lines and the notes it is laid over."""

    tune: int
    #: first and one-past-last index into the tune's sung notes (`_Walk.notes`)
    start: int
    end: int
    #: each verse's text, `+:` continuations joined on
    verses: tuple[str, ...]


@dataclass(frozen=True)
class LyricScan:
    """What one tune's words are and the notes they belong to."""

    tune: int
    notes: tuple[tuple[str | None, int], ...]
    blocks: tuple[LyricBlock, ...]
    #: `W:` lines, the words printed after the tune; reported, not engraved
    words_after: tuple[str, ...]
    #: the tune has more than one voice, which this stage does not align
    voices: bool


def _strip_comment(text: str) -> str:
    out, i = [], 0
    while i < len(text):
        if text[i] == "\\" and text[i + 1:i + 2] == "%":
            out.append("%")
            i += 2
            continue
        if text[i] == "%":
            break
        out.append(text[i])
        i += 1
    return "".join(out)


def scan_lyrics(text: str) -> list[LyricScan]:
    """Every tune's `w:` blocks and the notes each one covers. Writes nothing."""
    lines = text.splitlines()
    out: list[LyricScan] = []
    for tune_index, (start, end) in enumerate(_tunes(text)):
        walk = _Walk()
        events = 0
        blocks: list[LyricBlock] = []
        words_after: list[str] = []
        voices = False
        aligned = 0
        current: list | None = None   # [start, end, [verse text, ...]]
        in_body = False

        def close() -> None:
            nonlocal current, aligned
            if current is not None:
                blocks.append(LyricBlock(tune_index, current[0], current[1],
                                         tuple(current[2])))
                aligned = current[1]
                current = None

        for row in range(start, min(end, len(lines))):
            line = lines[row]
            lyric = _LYRIC_LINE.match(line)
            if lyric:
                words = _strip_comment(lyric.group(1))
                if current is None:
                    current = [aligned, len(walk.notes), [words]]
                else:
                    current[2].append(words)
                continue
            more = _LYRIC_CONTINUATION.match(line)
            if more and current is not None:
                current[2][-1] += " " + _strip_comment(more.group(1))
                continue
            if line.lstrip().startswith("%"):
                continue                  # a comment does not end a block
            close()
            words = _WORDS_LINE.match(line)
            if words:
                words_after.append(_strip_comment(words.group(1)).strip())
                continue
            if _VOICE.search(line):
                voices = True
            if _FIELD_LINE.match(line):
                if re.match(r"^\s*K\s*:", line):
                    in_body = True
                continue
            if in_body:
                _, events, _, _ = _scan_line(line, tune_index, events, walk)
        close()
        out.append(LyricScan(tune_index, tuple(walk.notes), tuple(blocks),
                             tuple(w for w in words_after if w), voices))
    return out


def _lyric_tokens(text: str) -> list[tuple]:
    """A `w:` line as ('syl', text, hyphen_after) / ('skip',) / ('bar',).

    `hold` (`_`) and `*` both consume a note and print nothing there, so they
    are one token; a hyphen with no syllable before it (`a -- b`) is one too.
    """
    tokens: list[tuple] = []
    buf: list[str] = []
    last = " "

    def flush(hyphen: bool) -> None:
        if buf:
            tokens.append(("syl", "".join(buf), hyphen))
            buf.clear()

    i = 0
    while i < len(text):
        c = text[i]
        if c == "\\" and text[i + 1:i + 2] == "-":
            buf.append("-")
            i += 2
            last = "-x"               # a printed hyphen is a letter here
            continue
        if c == "~":
            buf.append(" ")
        elif c in " \t":
            flush(False)
        elif c == "-":
            if buf:
                flush(True)
            elif last in (" ", "\t", "-"):
                tokens.append(("skip",))
        elif c in "_*":
            flush(False)
            tokens.append(("skip",))
        elif c == "|":
            flush(False)
            tokens.append(("bar",))
        else:
            buf.append(c)
        last = c if c in " \t-" else "x"
        i += 1
    flush(False)
    return tokens


def _lay_verse(tokens: list[tuple], notes, start: int, end: int,
               in_word: bool) -> tuple[list[tuple[int, str, str]], int, bool]:
    """Where one verse's syllables land: [(note index, text, syllabic)].

    Returns the placements, the syllables left over when the notes ran out
    (ignored, per §5.1, and counted), and whether a word is still open at the
    end -- a word may run on into the next block.
    """
    placed: list[tuple[int, str, str]] = []
    idx, last_bar, prefix, excess = start, None, "", 0
    if tokens and tokens[0][0] == "syl" and not tokens[0][2] and _STANZA.match(tokens[0][1]):
        prefix = tokens[0][1] + " "
        tokens = tokens[1:]
    for token in tokens:
        if token[0] == "bar":
            if last_bar is not None:
                while idx < end and notes[idx][1] == last_bar:
                    idx += 1
            continue
        if idx >= end:
            excess += token[0] == "syl"
            continue
        last_bar = notes[idx][1]
        if token[0] == "skip":
            idx += 1
            continue
        _, text, hyphen = token
        if in_word:
            syllabic = "middle" if hyphen else "end"
        else:
            syllabic = "begin" if hyphen else "single"
        in_word = hyphen
        placed.append((idx, prefix + text, syllabic))
        prefix = ""
        idx += 1
    return placed, excess, in_word


def _sung_notes(score) -> list:
    """The notes a syllable can land on, in written order: `_Walk.notes`'s twin."""
    from music21 import harmony as m21harmony

    return [n for n in score.recurse().notes
            if not isinstance(n, m21harmony.Harmony) and not n.duration.isGrace]


def restore_lyrics(score, scanned: LyricScan) -> dict:
    """Put one tune's `w:` words on its notes. Returns what it managed.

    The same proof the decorations owe: the ABC's count of sung notes against
    the stream's, and every syllable's note letter against the note it is
    about to land on. Unlike a decoration, ONE disagreement withdraws the
    tune's words entirely -- syllables are placed by counting, so a single
    note miscounted moves every syllable after it, and a verse sung one note
    late is worse than a verse reported as not carried.
    """
    from music21 import note as m21note

    report: dict = {"syllables": 0, "verses": 0, "reason": None, "excess": 0}
    if not scanned.blocks:
        return report
    if scanned.voices or len(getattr(score, "parts", [])) > 1:
        report["reason"] = ("its words are written against more than one voice, "
                            "which this import does not align")
        return report
    sung = _sung_notes(score)
    if len(sung) != len(scanned.notes):
        report["reason"] = (f"the tune reads as {len(sung)} sung notes and its "
                            f"words are written against {len(scanned.notes)}")
        return report

    placements: list[tuple[int, int, str, str]] = []   # (note, verse, text, syllabic)
    open_word: dict[int, bool] = {}
    verses = 0
    for block in scanned.blocks:
        for number, text in enumerate(block.verses, start=1):
            placed, excess, open_word[number] = _lay_verse(
                _lyric_tokens(text), scanned.notes, block.start, block.end,
                open_word.get(number, False))
            report["excess"] += excess
            placements.extend((i, number, t, s) for i, t, s in placed)
            verses = max(verses, number)

    for index, _, _, _ in placements:
        step = scanned.notes[index][0]
        if step is not None and getattr(sung[index], "step", None) != step:
            report["reason"] = (f"syllable {index + 1}'s note is written as {step} "
                                f"and reads as {sung[index].step}")
            return report

    for index, number, text, syllabic in placements:
        sung[index].lyrics.append(
            m21note.Lyric(text=text, number=number, syllabic=syllabic, applyRaw=True))
    report["syllables"] = len(placements)
    report["verses"] = verses
    return report


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


def fold_continuations(text: str) -> str:
    """`+:` lines joined onto the field they continue (ABC 2.1 §3.3).

    music21 does not know `+:` and reads its text as MUSIC: `+: eight nine
    ten` parsed as four extra notes (e, g, e, e), which shifted every
    decoration and every syllable after it. A continuation adds a space
    between the two halves, so that is what joins them.
    """
    out: list[str] = []
    for line in text.splitlines(keepends=True):
        more = _LYRIC_CONTINUATION.match(line.rstrip("\r\n"))
        if more and out and _FIELD_LINE.match(out[-1]):
            previous = out[-1].rstrip("\r\n")
            ending = out[-1][len(previous):] or "\n"
            out[-1] = f"{previous} {more.group(1).strip()}{ending}"
            continue
        out.append(line)
    return "".join(out)


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
    text = fold_continuations(source.read_text(encoding="utf-8", errors="replace"))
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
    lyrics = {"syllables": 0, "verses": 0, "excess": 0, "withheld": [], "words_after": 0}

    def sing(score, scanned: LyricScan | None, title: str) -> None:
        if scanned is None:
            return
        lyrics["words_after"] += len(scanned.words_after)
        one = restore_lyrics(score, scanned)
        lyrics["syllables"] += one["syllables"]
        lyrics["verses"] = max(lyrics["verses"], one["verses"])
        lyrics["excess"] += one["excess"]
        if one["reason"]:
            lyrics["withheld"].append({"title": title, "reason": one["reason"]})

    try:
        scores = parse(stripped)
        report = restore(scores, marks)
        scans = scan_lyrics(text)
        blocks = [text.splitlines()[a:b] for a, b in _tunes(text)]
        if len(scans) == len(scores):
            for score, scanned, block in zip(scores, scans, blocks):
                sing(score, scanned, _title("\n".join(block)))
        elif any(s.blocks for s in scans):
            # the tunes and the parsed scores do not pair up, so no tune's
            # words can be proved to be its own
            lyrics["withheld"].append({"title": _title(text), "reason": (
                f"the file reads as {len(scores)} tunes and is written as "
                f"{len(scans)}")})
    except Exception:  # noqa: BLE001 -- music21 raises many kinds; each is a tune it cannot read
        # ONE TUNE AT A TIME. music21 reads a file whole, so one setting it
        # could not read took the other thirty-seven down with it ("Bad chord
        # indicator: [[Ee"). Each `X:` block is read on its own; a block that
        # fails is read again with its chord brackets repaired
        # (`repair_chords`), and only then skipped -- NAMED in the report. A
        # tune that reads is never repaired: the repair is for typos, and a
        # rule applied to music that was fine is how a typo-fixer breaks it.
        # the whole-file attempt may have counted words onto scores that are
        # now thrown away and read again one tune at a time
        lyrics.update(syllables=0, verses=0, excess=0, withheld=[], words_after=0)
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
            block_scans = scan_lyrics(block)
            for score in parsed:
                one = _restore_one(score, block_marks)
                carried += one["carried"]
                misplaced += one["misplaced"]
                if one["reason"]:
                    reasons.append(f"{_title(block)}: {one['reason']}")
            if len(parsed) == 1 and len(block_scans) == 1:
                sing(parsed[0], block_scans[0], _title(block))
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
    report["lyrics"] = lyrics
    return scores, report
