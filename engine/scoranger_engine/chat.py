"""Provider-neutral chat agent: a Pydantic AI loop over the deterministic ops.

The model is a config choice, never a code choice. Friendly aliases in MODELS
map to pydantic-ai model strings; pick one per request ("model": "kimi") or set
a default with SCORANGER_MODEL. OpenRouter aliases need OPENROUTER_API_KEY;
google-cloud needs GCP ADC; anthropic needs ANTHROPIC_API_KEY.

The LLM never writes notation: every tool is a deterministic music21 operation
that creates a new immutable version. Tool errors are returned to the model as
data so it can correct itself (e.g. bad part names list the real ones).
"""

import json
import os

from pydantic_ai import Agent, RunContext

from . import ops, workspace

# Friendly alias -> pydantic-ai model string. Update slugs freely; nothing
# else in the system knows or cares which model is running.
# (IDs verified 2026-08-15; all tool-calling capable through OpenRouter.)
MODELS = {
    "gemini-flash": "openrouter:google/gemini-3.7-flash",        # $0.38/$1.88 per 1M
    "kimi": "openrouter:moonshotai/kimi-k3",                     # $3.00/$15 (the :exacto route was retired)
    "qwen": "openrouter:qwen/qwen3.8-max",                       # $2.00/$6.00
    "claude": "openrouter:anthropic/claude-sonnet-5",            # $2.00/$10 — best judgment in our bake-off
    "claude-opus": "openrouter:anthropic/claude-opus-5",         # $5.00/$25
    "deepseek": "openrouter:deepseek/deepseek-v4-flash",         # $0.06/$0.13 — untested, absurdly cheap
    # Direct-provider routes (no OpenRouter fee) for models that graduate:
    "gemini-direct": "google-cloud:gemini-3.6-flash",
    "claude-direct": "anthropic:claude-sonnet-5",
    # Offline smoke-testing without any API key:
    "test": "test",
}

DEFAULT_MODEL = os.environ.get("SCORANGER_MODEL", "gemini-flash")

INSTRUCTIONS = """\
You are Scoranger's arrangement agent. You manipulate a musical score ONLY
through the provided tools — deterministic operations that each create a new
immutable version. Never describe notation edits you cannot perform with a tool.

Working rules:
1. Orient first: call get_score_info before planning changes.
2. State your plan briefly, then execute it with tool calls.
3. Verify after: read each tool result; after change_instrument, relay the
   octave-shift and out-of-range report to the user. After pull_part, relay
   `length_warning` if it is there: the staves are now different lengths, and
   that draws as a blank region on the page.
4. If a tool returns an error, read it — bad part names include the real part
   list. Correct and retry.
5. Musical judgment is yours: sensible clefs, octaves, keys. Flag questionable
   requests instead of silently producing garbage.
6. A PIECE is the composition; an ARRANGEMENT is one scoring of it; a VERSION is
   one immutable step in an arrangement's history. You always operate on ONE
   arrangement. When the user writes '#N' they mean arrangement number N of the
   same piece, listed with its 'arr:<slug>' ref in the context: "take the violin
   part from #3" means pull_part from that ref. '#N' never means a version or a
   measure. If no numbered list is in context, say the arrangement isn't filed
   under a piece yet rather than guessing.
7. A HARMONY LINE stays in the key. "A third above", "a sixth below",
   "harmonise it" are diatonic: use transpose_diatonic, which moves by scale
   degrees and leaves the key signature alone. Plain `transpose` is chromatic
   and changes key -- right for "put this in D", wrong for a harmony. Never
   answer that scale-degree transposition within a key is unsupported; it is
   transpose_diatonic.
8. "I can't play this fast", "reduce the 16ths to eighths", "simplify the
   rhythm" is simplify_rhythm, and it has TWO answers that are different pieces
   of music: augment (every value doubles, the meter's denominator halves,
   nothing is lost, the passage lasts twice as long) and thin (notes between
   the beats are dropped, the passage keeps its place and length). Never say
   rhythmic augmentation or quantization is unsupported, and never choose
   between the two silently -- say which you used and what it cost, and relay
   `notes_removed` when you thinned. A solo can have augment for free; a part
   playing with others can only be thinned. The third answer needs no tool:
   play it slower, which is what augmenting writes down.
9. Accidentals ARE yours to control, and the tools are clean_accidentals (a
   whole part or score) and set_accidental (named notes: add, remove, show,
   hide, colour). If a reader says a part has accidentals that are already in
   the key signature, or is cluttered or hard to read, run clean_accidentals on
   that part -- do not answer that display accidentals cannot be overridden.
   Every op that changes pitches already normalises them against each part's
   own WRITTEN key, so a transposing part is judged by what is on its staff.
10. The app can take ABC now -- the text notation thesession.org publishes
    Irish traditional music in. If a reader asks whether they can bring a tune
    in from there, the answer is yes: `.abc` imports like MusicXML or MIDI,
    modal keys included (Edor, Amix). You do not import files yourself -- the
    reader does, from Import -- so say it can be done rather than offering to
    do it. Two things to say if it comes up: a file holding several tunes
    imports as several ARRANGEMENTS, and ABC's `~` rolls and `!...!`
    decorations are not carried into the notation. Scoranger cannot WRITE ABC;
    export is MusicXML, MIDI or PDF.
Answer concisely; the user sees the score update live.
"""


def _latest(slug: str):
    from music21 import converter
    return converter.parse(str(workspace.resolve_path(slug)), forceSource=True)


def _mutate(slug: str, op: str, args: dict, details) -> dict:
    # caller already applied `fn` to the score object it passes via details/score
    raise NotImplementedError


def _part(score, name: str):
    """The part a tool named, resolved the way every other surface resolves it.

    `bridge.py` has carried this helper since it was written; three tools here
    called it while it did not exist here and raised NameError on every
    invocation. The same shape of failure as `scor whistle-fingerings`, and
    invisible for the same reason: nothing ever ran the agent's tool functions.
    """
    return ops.find_parts(score, [name])[0]


def _apply(slug: str, op: str, args: dict, fn) -> dict:
    """Load latest, apply fn(score) -> details, save as a new version."""
    try:
        score = _latest(slug)
        details = fn(score)
        entry = workspace.add_version(slug, score, op, args)
        return {"ok": True, "new_version": entry["id"], "details": details}
    except Exception as e:
        return {"ok": False, "error": f"{type(e).__name__}: {e}"}


# --- tools -------------------------------------------------------------------
# Each takes RunContext[str] where deps is the score slug.

def get_score_info(ctx: RunContext[str]) -> dict:
    """Parts, instruments, clefs, ranges, measure counts, key and time signatures of the current score."""
    try:
        return ops.info(_latest(ctx.deps))
    except Exception as e:
        return {"ok": False, "error": f"{type(e).__name__}: {e}"}


def list_versions(ctx: RunContext[str]) -> dict:
    """The score's version history (op + args per version) and its sources (other editions of the piece)."""
    # workspace.version_history, not load_meta: see the note on VERSION_FIELDS
    # for what is dropped and why. Shared with the iOS bridge's `versions` op.
    return workspace.version_history(ctx.deps)


def keep_parts(ctx: RunContext[str], parts: list[str]) -> dict:
    """Keep only the named parts; remove all others. Part names match case-insensitively; '#N' targets by index."""
    return _apply(ctx.deps, "keep-parts", {"parts": parts},
                  lambda s: {"kept": ops.list_part_labels(s), "removed": ops.keep_parts(s, parts)})


def remove_parts(ctx: RunContext[str], parts: list[str]) -> dict:
    """Remove the named parts from the score."""
    return _apply(ctx.deps, "remove-parts", {"parts": parts},
                  lambda s: {"removed": ops.remove_parts(s, parts)})


def transpose(ctx: RunContext[str], interval: str, parts: list[str] | None = None,
              from_measure: int | None = None, to_measure: int | None = None) -> dict:
    """CHROMATIC transposition: shift by a fixed interval and CHANGE KEY.

    Use this when the user wants the music in a DIFFERENT key — "put this in D",
    "a whole step up so I can sing it", "transpose for B-flat clarinet". Every pitch
    moves by the same interval and the key signature is rewritten to match.

    Do NOT use this for a harmony line. "A third above", "a sixth below", "harmonise
    it" mean the notes must stay IN THE CURRENT KEY, and this tool cannot do that —
    it would take a G major tune a sixth down into B-flat major. Use
    transpose_diatonic for those.

    `interval` is a named interval ('M2', 'm-3', 'P8') or a semitone count ('-3').
    Set from_measure/to_measure (inclusive) for a measure range."""
    return _apply(ctx.deps, "transpose",
                  {"interval": interval, "parts": parts,
                   "from_measure": from_measure, "to_measure": to_measure},
                  lambda s: ops.transpose(s, interval, parts, from_measure, to_measure))


def transpose_elements(ctx: RunContext[str], interval: str, elements: list[str]) -> dict:
    """Transpose ONLY the given elements, by their addresses.

    Use this -- never plain `transpose` with from_measure/to_measure -- whenever the user
    refers to a selection and the context lists selected element addresses. An address looks
    like 's1/m15/l1/note#3' (staff/measure/layer/kind#ordinal); pass exactly the ones the
    context gives you, unchanged. `transpose` with a measure range moves EVERY note in those
    bars, which is wrong when the user selected particular notes."""
    return _apply(ctx.deps, "transpose-elements",
                  {"interval": interval, "elements": elements},
                  lambda s: ops.transpose_elements(s, interval, elements))


def transpose_diatonic(ctx: RunContext[str], degrees: str, parts: list[str] | None = None,
                       from_measure: int | None = None, to_measure: int | None = None,
                       key: str | None = None) -> dict:
    """DIATONIC transposition: move by SCALE DEGREES and STAY IN THE KEY.

    This is the tool for a harmony line. "Down a sixth", "a third above the melody",
    "harmonise this in thirds", "add a second violin part below" — all of them mean
    the new line must sit in the same key as the tune, so the key signature does not
    change and no accidentals appear that were not there before. Some of the sixths
    come out major and some minor, exactly as the key requires; that is what makes it
    sound like a harmony rather than a modulation.

    `degrees` is a signed generic interval — the number a musician says. -6 is down a
    sixth, 3 is up a third, -3 down a third, 8 up an octave. Names work too:
    'down a sixth'. There is no zeroth interval; a unison is 1.

    To write a harmony line as a NEW part, first copy the melody part (pull_part from
    the current version) and then run this on the copy — this tool moves the notes of
    the parts you name, it does not add a staff.

    `key`: only needed when the staff carries no key signature (common in scanned
    scores) — the tool refuses rather than guessing, and tells you so. Give 'G', 'e'
    for e minor, 'Bb'.

    The result reports any note that was OUTSIDE the key (a chromatic passing note has
    no scale degree, so the tool has to make a choice there); relay those bars to the
    user if there are any."""
    return _apply(ctx.deps, "transpose-diatonic",
                  {"degrees": degrees, "parts": parts, "key": key,
                   "from_measure": from_measure, "to_measure": to_measure},
                  lambda s: ops.transpose_diatonic(s, degrees, parts,
                                                   from_measure, to_measure, key))


def transpose_diatonic_elements(ctx: RunContext[str], degrees: str, elements: list[str],
                                key: str | None = None) -> dict:
    """Move ONLY the given elements by scale degrees, staying in the key.

    The selection form of transpose_diatonic, and the same rule applies as for
    transpose_elements: use this — never transpose_diatonic with a measure range —
    whenever the user refers to a selection and the context lists selected element
    addresses. Pass them unchanged ('s1/m15/l1/note#3')."""
    return _apply(ctx.deps, "transpose-diatonic-elements",
                  {"degrees": degrees, "elements": elements, "key": key},
                  lambda s: ops.transpose_diatonic_elements(s, degrees, elements, key))


def respell(ctx: RunContext[str], prefer: str = "flats", parts: list[str] | None = None,
            from_measure: int | None = None, to_measure: int | None = None) -> dict:
    """Respell accidentals enharmonically: prefer='flats' turns G# into Ab (right for flat keys
    like F minor); prefer='sharps' does the reverse. Key signatures are untouched. Set
    from_measure/to_measure (inclusive) to respell only that measure range."""
    return _apply(ctx.deps, "respell",
                  {"prefer": prefer, "parts": parts,
                   "from_measure": from_measure, "to_measure": to_measure},
                  lambda s: ops.respell(s, prefer, parts, from_measure, to_measure))


def set_rehearsal(ctx: RunContext[str], measure: int | None = None,
                  mark: str | None = None, remove: bool = False,
                  move_to: int | None = None, reletter: bool = False) -> dict:
    """Add, remove, move or re-letter rehearsal marks.

    measure=9 adds one at bar 9, lettered with the next free letter unless you pass
    mark='C'. remove=True takes the mark at that bar off; move_to=13 moves it there;
    reletter=True re-labels every mark in bar order (A-Z, then AA, BB, CC), which is what
    you want after inserting one in the middle.

    Marks are written to EVERY part, so extracted parts keep them; the combined score
    draws each one once. To change how big a mark is or where it sits, use adjust_element."""
    return _apply(ctx.deps, "set-rehearsal",
                  {"measure": measure, "mark": mark, "remove": remove,
                   "move_to": move_to, "reletter": reletter},
                  lambda s: ops.set_rehearsal(s, measure=measure, mark=mark,
                                              remove=remove, move_to=move_to,
                                              reletter=reletter))


def clean_accidentals(ctx: RunContext[str], parts: list[str] | None = None) -> dict:
    """Hide accidentals that the key signature already implies, so the part reads cleanly.

    Use this when a reader says there are too many accidentals, that accidentals are
    "already in the key signature", or that a part is cluttered or hard to read. Each part
    is judged by the key signature ON ITS OWN STAFF, so a transposing instrument (an E-flat
    alto saxophone, a B-flat clarinet) is judged by its WRITTEN key, not concert pitch.

    Display only: no pitch, no spelling and no key signature changes. Accidentals that are
    genuinely needed -- outside the key, or cancelling an earlier one in the bar -- are kept.
    Every op that changes pitches already runs this, so you rarely need it after your own
    edits; it is for cleaning up material that arrived cluttered."""
    return _apply(ctx.deps, "clean-accidentals", {"parts": parts},
                  lambda s: ops.normalize_accidentals(s, parts))


def set_accidental(ctx: RunContext[str], elements: list[str],
                   show: bool | None = None, add: str | None = None,
                   remove: bool = False, color: str | None = None) -> dict:
    """Add, remove, show, hide or colour the accidentals on particular notes.

    `elements` are addresses like 's1/m15/l1/note#3' (staff/measure/layer/kind#ordinal) --
    pass exactly the ones the context gives you for a selection, unchanged.

    Two of these change the MUSIC:
      add='sharp'|'flat'|'natural'|'double-sharp'|'double-flat' gives the note that
        accidental, which CHANGES ITS PITCH
      remove=True takes the accidental off, which also CHANGES ITS PITCH

    Three change only the DISPLAY, never the pitch:
      show=True  forces the glyph to be drawn (a courtesy accidental)
      show=False stops it being drawn
      color='#CC4125' draws it in that colour; color='none' clears it

    To clean up a whole part rather than named notes, use clean_accidentals."""
    return _apply(ctx.deps, "set-accidental",
                  {"elements": elements, "show": show, "add": add,
                   "remove": remove, "color": color},
                  lambda s: ops.set_accidental(s, elements, show=show, add=add,
                                               remove=remove, color=color))


def change_clef(ctx: RunContext[str], part: str, clef: str, from_measure: int = 1) -> dict:
    """Set a part's clef (treble, bass, alto, tenor, treble8vb, bass8vb) from a given measure."""
    return _apply(ctx.deps, "change-clef", {"part": part, "clef": clef},
                  lambda s: ops.change_clef(ops.find_parts(s, [part])[0], clef, from_measure))


def change_instrument(ctx: RunContext[str], part: str, to_instrument: str) -> dict:
    """Reassign a part to another instrument: converts transposition, octave-fits the line to the
    instrument's range, sets the idiomatic clef, and reports remaining out-of-range notes."""
    return _apply(ctx.deps, "change-instrument", {"part": part, "to": to_instrument},
                  lambda s: ops.change_instrument(ops.find_parts(s, [part])[0], to_instrument))


def rename_part(ctx: RunContext[str], part: str, name: str, abbreviation: str | None = None) -> dict:
    """Rename a part (label only, no musical change)."""
    return _apply(ctx.deps, "rename-part", {"part": part, "name": name},
                  lambda s: ops.rename_part(ops.find_parts(s, [part])[0], name, abbreviation))


def check_range(ctx: RunContext[str], part: str, instrument: str | None = None) -> dict:
    """List notes outside an instrument's range (the part's own instrument, or the named one). Read-only."""
    try:
        from music21 import instrument as m21instrument
        score = _latest(ctx.deps)
        p = ops.find_parts(score, [part])[0]
        cls = (type(m21instrument.fromString(instrument)).__name__ if instrument
               else type(p.getInstrument(returnDefault=False)).__name__)
        if cls not in ops.RANGES:
            return {"ok": False, "error": f"No range data for '{cls}'. Known: {sorted(ops.RANGES)}"}
        return {"part": ops.part_label(p), "instrument": cls,
                "violations": ops.range_violations(p, cls)}
    except Exception as e:
        return {"ok": False, "error": f"{type(e).__name__}: {e}"}


def octave_shift(ctx: RunContext[str], part: str, octaves: int,
                 from_measure: int, to_measure: int) -> dict:
    """Shift a part by whole octaves within an inclusive measure range."""
    return _apply(ctx.deps, "octave-shift",
                  {"part": part, "octaves": octaves, "measures": f"{from_measure}-{to_measure}"},
                  lambda s: ops.octave_shift(s, part, octaves, from_measure, to_measure))


def simplify_rhythm(ctx: RunContext[str], mode: str, part: str | None = None,
                    unit: str = "eighth", from_measure: int | None = None,
                    to_measure: int | None = None) -> dict:
    """Make a passage slower to READ. This is the tool for "I can't play this
    fast", "reduce the 16th notes down to eighth notes", "simplify the rhythm",
    "this run is too quick for me", "make it easier to play".

    Never answer that rhythmic augmentation or quantization is unsupported; it
    is this tool. But DO NOT pick a mode silently -- the two are different
    pieces of music and the reader has to know which one they are getting.

    mode='augment' -- every value doubles and the meter's denominator halves
    (4/4 becomes 4/2), so every sixteenth is written as an eighth. NOT ONE NOTE
    IS LOST and no bar is added or renumbered. The cost is time: the passage
    lasts twice as long, which is to say it sounds at half speed. This is the
    right answer for a SOLO, where nothing has to line up with anything. It
    changes how long a bar lasts, so it applies to the whole score -- naming one
    part of a multi-part score is refused, and rightly.

    mode='thin' -- attacks are quantized onto the `unit` grid and the notes
    between them are DROPPED. The passage keeps its place in the bar and its
    length, so it still fits everything else playing. It is no longer the same
    tune. This is the right answer for a part in an ensemble. The result
    reports `notes_removed` and `removed_by_measure`: RELAY THEM. That is
    someone's music.

    And there is a third answer that needs no tool at all: play it slower.
    Augmenting IS that answer written into the notation, so if the reader only
    wants relief and does not need the page changed, say so before rewriting
    anything.

    How to choose: if the score has one part, offer augment first -- it costs
    nothing. If the part plays with others, augment is not available and thin
    is the only notation change there is; say what it will cost before doing
    it. When you are unsure which the reader wants, ASK; the difference between
    "the same tune, slower" and "fewer notes, same speed" is not yours to
    decide for them.

    `unit` is the fastest value they want to read: 'eighth' (default), '16th',
    'quarter'. Set from_measure/to_measure (inclusive) to fix just the passage
    that defeats them rather than the whole piece -- usually what is wanted.

    Read the result's `cost` sentence and pass its substance on. Augment can
    take a passage carrying 32nds only as far as 16ths in one pass, and 4/4
    doubles to 4/2 and no further; when that happens the result says so and
    names thinning as what is left."""
    return _apply(ctx.deps, "simplify-rhythm",
                  {"mode": mode, "part": part, "unit": unit,
                   "from_measure": from_measure, "to_measure": to_measure},
                  lambda s: ops.simplify_rhythm(s, mode, [part] if part else None,
                                                unit, from_measure, to_measure))


def merge_parts(ctx: RunContext[str], parts: list[str], new_name: str, clef: str = "treble") -> dict:
    """Merge several parts losslessly into one staff (each source becomes a voice)."""
    return _apply(ctx.deps, "merge-parts", {"parts": parts, "name": new_name, "clef": clef},
                  lambda s: ops.merge_parts(s, parts, new_name, clef))


def split_bass(ctx: RunContext[str], part: str, bass_name: str, chords_name: str,
               instrument: str | None = None) -> dict:
    """Split a part into a bass staff (lowest pitch per moment, bass clef) and a chords staff (the rest, treble)."""
    return _apply(ctx.deps, "split-bass", {"part": part},
                  lambda s: ops.split_bass(s, part, bass_name, chords_name, instrument))


def absorb_part(ctx: RunContext[str], source: str, target: str, rules: dict | None = None) -> dict:
    """Fold a chordal part into a melodic part as a second voice under the melody.
    Optional rules override: below_melody(bool), drop_doubling(bool), min_pitch(str), max_span(int)."""
    return _apply(ctx.deps, "absorb-part", {"source": source, "target": target, "rules": rules},
                  lambda s: ops.absorb_part(s, source, target, rules))


def flatten_voices(ctx: RunContext[str], part: str) -> dict:
    """Collapse a multi-voice staff into one voice of chords (piano right-hand style)."""
    return _apply(ctx.deps, "flatten-voices", {"part": part},
                  lambda s: ops.flatten_voices(s, part))


def consolidate_ties(ctx: RunContext[str], parts: list[str]) -> dict:
    """Merge runs of tied same-pitch notes into single longer notes (notational cleanup)."""
    return _apply(ctx.deps, "consolidate-ties", {"parts": parts},
                  lambda s: ops.consolidate_ties(s, parts))


def limit_part(ctx: RunContext[str], part: str, max_pitch: str | None = None,
               monophonic: bool = False) -> dict:
    """Enforce playability limits on a part, always dropping higher notes: a pitch ceiling and/or monophony."""
    return _apply(ctx.deps, "limit-part", {"part": part, "max_pitch": max_pitch, "monophonic": monophonic},
                  lambda s: ops.limit_part(s, part, max_pitch, monophonic))


def simplify_repeats(ctx: RunContext[str], part: str) -> dict:
    """Collapse measures that only restate one pitch class (octave jumps/repeats) to a downbeat note + rests."""
    return _apply(ctx.deps, "simplify-repeats", {"part": part},
                  lambda s: ops.simplify_repeats(s, part))


def analyze_harmony(ctx: RunContext[str], parts: list[str] | None = None) -> dict:
    """Per-measure harmony analysis: ranked chord candidates per bar with the downbeat bass note. Read-only;
    you adjudicate the final chart (prefer functional readings, name secondary dominants literally)."""
    try:
        return ops.analyze_harmony(_latest(ctx.deps), parts)
    except Exception as e:
        return {"ok": False, "error": f"{type(e).__name__}: {e}"}


def set_chords(ctx: RunContext[str], part: str, chords: list[dict]) -> dict:
    """Write chord symbols onto a part: [{"measure": 1, "symbol": "Fm"}, ...].
    Qualities: '', m, 7, m7, maj7, m7b5, 6, m6, dim, dim7, aug; roots may carry b/#."""
    return _apply(ctx.deps, "set-chords", {"part": part, "count": len(chords)},
                  lambda s: ops.set_chord_symbols(s, part, chords))


def chart_style(ctx: RunContext[str], part: str) -> dict:
    """Real Book styling for a chord-symbol staff: hide rests, put the names on the staff."""
    return _apply(ctx.deps, "chart-style", {"part": part},
                  lambda s: ops.chart_style(s, part))


def pull_part(ctx: RunContext[str], from_ref: str, part: str, as_name: str | None = None,
              replace: str | None = None, measures: str | None = None) -> dict:
    """Bring a part (or 'A-B' measure range, requires replace) from a source ('src:s01') or a
    historical version ('v007') into the arrangement.

    Reports how many bars it brought and how long every staff now is. If the
    result carries `length_warning`, SAY IT: the staves are different lengths,
    which draws as a blank region on the page, and nothing pads them."""
    def fn(s):
        from music21 import converter
        if from_ref.startswith("src:"):
            path = workspace.source_path(ctx.deps, from_ref[4:])
        else:
            path = workspace.resolve_path(ctx.deps, from_ref)
        src_score = converter.parse(str(path), forceSource=True)
        rng = None
        if measures:
            a, b = measures.split("-")
            rng = (int(a), int(b))
        return ops.pull_part(s, src_score, part, as_name, replace, rng)
    return _apply(ctx.deps, "pull-part",
                  {"from": from_ref, "part": part, "replace": replace, "measures": measures}, fn)


def staff_spacing(ctx: RunContext[str], staff: int | None = None,
                  system: int | None = None, fingering_rows: int | None = None,
                  reset: bool = False) -> dict:
    """Change how much room the page gives. staff is the minimum space between
    the staves of one system and system the minimum space between systems, both
    in MEI units (staff 0-48, default 12; system 0-48, default 4). They are
    MINIMUMS: they open space up, and cannot close space the music needs, so
    asking for "tighter" below what the notes require changes nothing -- say so
    rather than trying again. fingering_rows is the band a penny-whistle
    fingering column takes above its staff, in rows (4-6, default 4): raise it
    for more air around the diagrams, lower it to fit more lines on a page.
    reset=True puts all three back."""
    def fn(s):
        return ops.staff_spacing(s, staff=staff, system=system,
                                 fingering_rows=fingering_rows, reset=reset)
    return _apply(ctx.deps, "staff-spacing",
                  {"staff": staff, "system": system,
                   "fingering_rows": fingering_rows, "reset": reset}, fn)


def paginate(ctx: RunContext[str], measures_per_line: int | None = None,
             break_at: list[int] | None = None,
             remove_at: list[int] | None = None, clear: bool = False,
             end_at: list[int] | None = None) -> dict:
    """Decide where the lines break. measures_per_line lays the whole score out
    at that many bars a line ("four bars to a line"). end_at is a list of bars
    that must END a line ("end the line at bar 12"); the bars after move on.
    break_at is a list of bars that must START a line ("start a new line at
    bar 17"). remove_at takes a line break off. clear=True removes every break
    and hands the layout back to the engraver ("repaginate automatically").
    Forced lines are remembered and the rest is laid out again around them:
    the lines before a forced ending are evened out and no line holds one bar
    alone. With no line length yet and none given, one is CHOSEN from how busy
    the bars are and the result says measures_per_line_chosen -- relay it."""
    def fn(s):
        return ops.paginate(s, measures_per_line=measures_per_line,
                            break_at=break_at, remove_at=remove_at, clear=clear,
                            end_at=end_at)
    return _apply(ctx.deps, "paginate",
                  {"measures_per_line": measures_per_line, "break_at": break_at,
                   "end_at": end_at, "remove_at": remove_at, "clear": clear}, fn)


def measure_numbers(ctx: RunContext[str], every: int | None = None,
                    system: bool = False, none: bool = False,
                    reset: bool = False) -> dict:
    """Decide which bars carry a measure number. every=1 numbers every bar
    ("add measure numbers"); every=N the bars whose number divides by N
    ("every third measure" is every=3); system=True the first bar of each line,
    the engraver's default; none=True takes them all off. Exactly one."""
    def fn(s):
        return ops.measure_numbers(s, every=every, system=system, none=none,
                                   reset=reset)
    return _apply(ctx.deps, "measure-numbers",
                  {"every": every, "system": system, "none": none,
                   "reset": reset}, fn)


def set_structure(ctx: RunContext[str], kind: str, measure: int | None = None,
                  to_measure: int | None = None, number: int | None = None,
                  times: int | None = None, remove: bool = False,
                  move_to: int | None = None) -> dict:
    """Add, remove or move a repeat sign, a volta (1st/2nd ending) or a
    navigation mark. kind is one of: repeat-start, repeat-end, repeat-both,
    volta, segno, coda, fine, da-capo, da-capo-al-fine, da-capo-al-coda,
    dal-segno, dal-segno-al-fine, dal-segno-al-coda. A volta needs measure and
    to_measure and a number; a repeat-end can take times. Set remove=True to
    take one off, or move_to to shift it to another measure."""
    def fn(s):
        return ops.set_structure(s, kind, measure=measure, to_measure=to_measure,
                                 number=number, times=times, remove=remove,
                                 move_to=move_to)
    return _apply(ctx.deps, "set-structure",
                  {"kind": kind, "measure": measure, "remove": remove}, fn)


def adjust_element(ctx: RunContext[str], part: str, measure: int | None = None,
                   kind: str = "harm", ordinal: int = 0, scale: float | None = None,
                   size: float | None = None,
                   offset_x: float | None = None, offset_y: float | None = None,
                   reset: bool = False, all_elements: bool = False) -> dict:
    """Change how big an added element is, or where it sits.

    `kind` is "harm" (a chord symbol), "diagram" (a guitar chord diagram),
    "tab" (a tablature column), or one of the six marks add_element writes:
    "dynamic", "text", "fermata", "articulation", "ornament", "lyric".

    "MAKE THAT ROLL BIGGER" IS kind="ornament". So is a trill, a mordent, a
    turn or a slide -- every squiggle over a notehead is that one kind, and
    which squiggle it is is the `value` add_element took. A fermata is its
    own kind, not an ornament.

    A LYRIC TAKES A SIZE AND NOTHING ELSE. "Make the words bigger" is a scale
    and works; "move the lyric to the left" is refused by name, because a word
    is drawn under the note it belongs to and no renderer here honours an
    offset on one. A word that belongs somewhere else belongs under another
    NOTE: that is move_element, not an offset.

    SIZE IS RELATIVE. `scale` is the interface: 1.0 is the engraved default,
    1.5 is half again, 0.75 is three quarters. "Make that dynamic bigger" is a
    scale, and so is every other size request a reader phrases in words.
    `size` is the ABSOLUTE point value (12 engraves as the default) and exists
    for a caller that already holds one -- the app's chord-symbol row reads a
    point size back out of the notation and sends it. Pass one or the other,
    never both; the op refuses both at once rather than letting one win.

    `offset_x`/`offset_y` nudge it sideways and up in MusicXML tenths, positive
    y being UP. Address one element with measure (plus ordinal when a bar has
    several), or pass all_elements=True for every element of that kind in the
    part. reset=True puts them back."""
    def fn(s):
        return ops.adjust_element(s, part, kind=kind, measure=measure, ordinal=ordinal,
                                  size=size, scale=scale,
                                  offset_x=offset_x, offset_y=offset_y,
                                  reset=reset, all_elements=all_elements)
    return _apply(ctx.deps, "adjust-element",
                  {"part": part, "kind": kind, "measure": measure,
                   "scale": scale, "size": size, "reset": reset}, fn)


def add_element(ctx: RunContext[str], part: str, kind: str, measure: int,
                value: str | None = None, offset: float = 0.0,
                placement: str | None = None) -> dict:
    """Put a mark on the page: a dynamic, words, a fermata, an articulation, an ornament or a word.

    `kind` is "dynamic", "text", "fermata", "articulation", "ornament" or
    "lyric". `value` is the dynamic ("mf"), the words ("dolce"), the
    articulation (accent, staccato, tenuto, marcato...), the ornament, the
    fermata's shape (normal|angled|square), or the syllable to sing ("la").

    ORNAMENTS are what a player calls them: "roll", "trill", "mordent",
    "turn", "inverted-turn", "inverted-mordent" (also "pralltriller" or
    "upper-mordent"), "lower-mordent", "slide". A ROLL is the Irish
    ornament; it is engraved as a turn sign, which is what that repertoire
    prints, so "roll" and "turn" draw the same mark.

    A LYRIC hangs off the note that starts at the offset, like a fermata, and
    lands in the lowest verse that note has free -- verse 1 under a note with
    no words, verse 2 under one already singing. It takes no `placement`:
    verses are drawn below the staff and asking for "above" is refused rather
    than written down and ignored.

    THE DESTINATION IS A BAR PLUS AN OFFSET INSIDE IT, in quarter notes from
    the barline: 0 is the downbeat, 1.5 the second half of beat two in 4/4.
    Offset-anchored marks (dynamic, text) are inserted at that offset;
    note-attached ones (fermata, articulation, ornament, lyric) are attached
    to the note that STARTS there, and if nothing does the op refuses and lists the
    bar's real onsets -- read them and pick one rather than retrying the same
    offset.
    `placement` is "above" or "below".

    Spanners (hairpins, slurs) are refused: they have two anchors. So are the
    three kinds that already have their own creating op -- a chord symbol is
    set_chords, a diagram guitar_chord_diagrams, a tab guitar_tablature.

    The result carries the ORDINAL the mark landed at, which is what
    adjust_element and move_element address it by."""
    return _apply(ctx.deps, "add-element",
                  {"part": part, "kind": kind, "measure": measure, "value": value},
                  lambda s: ops.add_element(s, part, kind, measure, value=value,
                                            offset=offset, placement=placement))


def move_element(ctx: RunContext[str], part: str, kind: str, measure: int,
                 ordinal: int = 0, to_measure: int | None = None,
                 to_offset: float = 0.0) -> dict:
    """Move an added element to another bar.

    Address the one you mean with `measure` (plus `ordinal` when the bar holds
    several of that kind, counting from 0). The destination is `to_measure`
    plus `to_offset` quarter notes from its barline, the same destination
    add_element takes.

    Offset-anchored elements (harm, diagram, dynamic, text) land at that
    offset; note-attached ones (fermata, articulation, ornament, lyric) attach
    to the note that STARTS there, and the op refuses and lists the onsets
    rather than guessing. "Move the trill onto the next note" is this op with
    the next note's onset as `to_offset` -- read the onsets off the refusal if
    you do not already know them. THIS IS THE ONLY WAY A LYRIC MOVES -- off
    one note and onto another, keeping its verse. If the destination note
    already sings that verse the op says whose word is in the way instead of
    stacking two on one notehead.
    Spanners are refused by name: a spanner has two anchors and a destination
    names one. A move never touches pitch or rhythm."""
    return _apply(ctx.deps, "move-element",
                  {"part": part, "kind": kind, "measure": measure,
                   "ordinal": ordinal, "to_measure": to_measure,
                   "to_offset": to_offset},
                  lambda s: ops.move_element(s, part, kind, measure, ordinal=ordinal,
                                             to_measure=to_measure,
                                             to_offset=to_offset, duplicate=False))


def remove_element(ctx: RunContext[str], part: str, kind: str,
                   measure: int | None = None, ordinal: int = 0,
                   all_elements: bool = False) -> dict:
    """Take an added mark off the page.

    "Take the ornament off bar 12", "lose that fermata", "clear the dynamics
    from this part". `kind` is the same set adjust_element takes: "harm",
    "diagram", "dynamic", "text", "fermata", "articulation", "ornament",
    "lyric".

    Address the one you mean with `measure` plus `ordinal` (counting from 0
    in the bar's document order), or pass all_elements=True for every one of
    that kind in the part. A tab column is refused by name: it IS the note,
    and guitar_tablature's clear is what takes one off.

    A LYRIC CAN BE REMOVED -- "drop that word" takes the verse off the note it
    is sung on. It takes the sung words only: a whistle's fingerings and a
    guitar tab's frets are verses too, and all_elements=True leaves both
    alone. The verses left keep their numbers, so taking verse 1 off a note
    singing two leaves the other on the second line of text."""
    return _apply(ctx.deps, "remove-element",
                  {"part": part, "kind": kind, "measure": measure,
                   "ordinal": ordinal, "all": all_elements},
                  lambda s: ops.remove_element(s, part, kind, measure,
                                               ordinal=ordinal,
                                               all_elements=all_elements))


def duplicate_element(ctx: RunContext[str], part: str, kind: str, measure: int,
                      ordinal: int = 0, to_measure: int | None = None,
                      to_offset: float = 0.0) -> dict:
    """Copy an added element into another bar, leaving the original where it is.

    Everything move_element says about addressing and about the destination
    applies here -- this is the same placement with the source left alone. Use
    it for "put that same accent on bar 9 too"."""
    return _apply(ctx.deps, "duplicate-element",
                  {"part": part, "kind": kind, "measure": measure,
                   "ordinal": ordinal, "to_measure": to_measure,
                   "to_offset": to_offset},
                  lambda s: ops.move_element(s, part, kind, measure, ordinal=ordinal,
                                             to_measure=to_measure,
                                             to_offset=to_offset, duplicate=True))


def strip_notes(ctx: RunContext[str], part: str) -> dict:
    """Empty a staff of its notes and keep its chord symbols -- a names-only staff.

    What a chart wants: the changes over the bars with nothing engraved under
    them. Every bar is left with a whole-bar rest, so the meter is intact and
    the chord symbols still sit where they sat. Pair it with chart_style, which
    hides those rests and puts the names on the staff."""
    return _apply(ctx.deps, "strip-notes", {"part": part},
                  lambda s: ops.strip_notes(s, part))


def guitar_tablature(ctx: RunContext[str], part: str, tuning: str = "EADGBE",
                     capo: int = 0, clear: bool = False,
                     position: int | None = None) -> dict:
    """Write guitar tablature under a part: a fret number per note on a
    six-line tab staff. The hand covers four frets, plays what is inside them
    across the strings, and shifts only where the line leaves its reach --
    every shift is in the report with the bar it lands in. `tuning` is EADGBE
    (standard), DADGAD or DADGBE (drop D); `capo` is the fret the capo sits on;
    `position` pins the fret the hand starts at, and left alone the line
    settles as low on the neck as the music allows. Notes the tuning cannot
    play are reported, and so is any bar where a chord forced the hand higher
    up the neck than its own notes needed. `clear` removes the tab."""
    def fn(s):
        return ops.guitar_tab(s, _part(s, part), tuning, capo=capo, clear=clear,
                              position=position)
    return _apply(ctx.deps, "guitar-tab",
                  {"part": part, "tuning": tuning, "capo": capo,
                   "clear": clear, "position": position}, fn)


def guitar_chord_diagrams(ctx: RunContext[str], part: str, tuning: str = "EADGBE",
                          clear: bool = False,
                          shapes: list[str] | None = None) -> dict:
    """Draw a guitar chord diagram above every chord symbol already on a part:
    the grid, the dots, the barre, the nut, the row of finger numbers over it,
    and a "5 fr." label when the shape sits up the neck. `tuning` is EADGBE
    (standard), DADGAD or DADGBE (drop D). Chords with no playable shape are
    reported. `shapes` pins chords to shapes of the player's choosing, ahead of
    the conventional chart -- ["A7=x02020"] asks for the open A7 rather than
    the fifth-fret barre. `clear` removes the diagrams.
    Size and position are `adjust_element`'s business, with kind="diagram"."""
    def fn(s):
        return ops.chord_diagrams(s, _part(s, part), tuning, clear=clear,
                                  shapes=ops.parse_shape_overrides(shapes))
    return _apply(ctx.deps, "chord-diagrams",
                  {"part": part, "tuning": tuning, "clear": clear,
                   "shape": shapes}, fn)


def penny_whistle_fingerings(ctx: RunContext[str], part: str, whistle: str = "D",
                             clear: bool = False) -> dict:
    """Write penny-whistle fingerings under every note of a part, as stacked
    hole diagrams in the notation (X covered, O open, / half, + overblown).
    `whistle` is the instrument's key (D by default). `clear` removes them."""
    def fn(s):
        return ops.whistle_fingerings(s, _part(s, part), whistle, clear=clear)
    return _apply(ctx.deps, "whistle-fingerings",
                  {"part": part, "whistle": whistle, "clear": clear}, fn)


def set_metadata(ctx: RunContext[str], title: str | None = None,
                 composer: str | None = None, arranger: str | None = None) -> dict:
    """Set the arrangement's title (engraved at the top of the page AND its name
    in the library -- one value, not two), its composer or its arranger.
    An empty string clears a credit."""
    try:
        return workspace.set_score_metadata(ctx.deps, title=title, composer=composer,
                                            arranger=arranger)
    except Exception as e:
        return {"ok": False, "error": f"{type(e).__name__}: {e}"}


def assign_to_piece(ctx: RunContext[str], piece_name: str) -> dict:
    """File this arrangement under a piece, creating it if needed."""
    try:
        return workspace.assign_score_to_piece(ctx.deps, piece_name, create_if_missing=True)
    except Exception as e:
        return {"ok": False, "error": f"{type(e).__name__}: {e}"}


TOOLS = [get_score_info, list_versions, keep_parts, remove_parts, transpose,
         transpose_elements, transpose_diatonic, transpose_diatonic_elements,
         respell, clean_accidentals, set_accidental, set_rehearsal,
         change_clef, change_instrument, rename_part, check_range, octave_shift,
         merge_parts, split_bass, absorb_part, flatten_voices, consolidate_ties,
         limit_part, simplify_repeats, simplify_rhythm, strip_notes,
         analyze_harmony, set_chords, chart_style,
         pull_part, set_metadata, penny_whistle_fingerings, guitar_chord_diagrams,
         guitar_tablature,
         set_structure, paginate, measure_numbers, staff_spacing,
         add_element, adjust_element, move_element, duplicate_element,
         remove_element,
         assign_to_piece]


def resolve_model(alias_or_string):
    """A friendly alias, a raw pydantic-ai model string, or a Model already built.

    The third case is how this agent is testable at all: a check hands in a
    scripted stub instead of a provider, and nothing else about the run
    changes. An unknown alias falls through as a raw model string, which is
    what lets a new slug be tried without editing MODELS.
    """
    name = alias_or_string or DEFAULT_MODEL
    if not isinstance(name, str):
        return name
    return MODELS.get(name, name)


def model_name(resolved) -> str:
    """What to call the model in a reply, whether it arrived as a string or as
    an object."""
    return resolved if isinstance(resolved, str) else getattr(
        resolved, "model_name", type(resolved).__name__)


def run_chat(slug: str, message: str, model: str | None = None,
             history_json: str | None = None) -> dict:
    """One chat turn. Returns the reply, serialized history for the next turn,
    and the score's new latest version."""
    from pydantic_ai.messages import ModelMessagesTypeAdapter

    workspace.load_meta(slug)  # validate score exists before spending tokens
    agent = Agent(resolve_model(model), deps_type=str, instructions=INSTRUCTIONS,
                  tools=TOOLS, retries=2)
    history = ModelMessagesTypeAdapter.validate_json(history_json) if history_json else None
    result = agent.run_sync(message, deps=slug, message_history=history)
    usage = result.usage if not callable(result.usage) else result.usage()
    return {
        "reply": result.output,
        "model": model_name(resolve_model(model)),
        "usage": {k: getattr(usage, k, None) for k in
                  ("input_tokens", "output_tokens", "requests")},
        "history": result.all_messages_json().decode(),
        "latest": workspace.load_meta(slug).get("latest"),
    }
