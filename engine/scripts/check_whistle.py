"""Regression check for the penny-whistle fingering chart, and what it writes on.

The chart is a table of published fact, so it is checked against the published
fact: the six-hole D whistle's fingerings, the two cross-fingerings every
player knows, the octave boundary that is easy to get wrong (C#5 is the top of
the *first* octave, not the bottom of the second), and the notes the instrument
simply cannot play.

Then WHERE the fingerings land, which is a separate way to be wrong and was:

  - A chord SYMBOL is a Chord in music21, so `recurse().notes` hands the op the
    chart along with the music. A part carrying chord symbols had six holes and
    an octave mark written onto every symbol -- a fingering for a chord, on an
    element that is not on the staff at all. `guitar_tab` was written knowing
    this and this was not, so the same iteration is now asserted for both.
  - A whistle's fingerings are verses 1-7 and a guitar tab's frets are verses
    1-6, so one note cannot carry both. `addLyric` writes the TEXT of the verse
    at a number and leaves its NAME alone, which put fret numbers under a `wf`
    label -- and the renderers key on that label, so "3" engraved as a row of
    circles. Whichever op runs last takes those verses outright and says how
    many notes it took them from; and CLEARING one leaves the other alone,
    which is not the same rule and had to be checked separately.

Run: engine/.venv/bin/python engine/scripts/check_whistle.py
"""

import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from music21 import harmony as m21harmony  # noqa: E402
from music21 import converter, meter, note as m21note, stream  # noqa: E402

from scoranger_engine import ops  # noqa: E402


def fingering(pitch: str, whistle: str = "D"):
    """(holes, overblown, playable) for one pitch on one whistle."""
    score = stream.Score()
    part = stream.Part()
    measure = stream.Measure(number=1)
    measure.append(meter.TimeSignature("4/4"))
    measure.append(m21note.Note(pitch, quarterLength=1))
    part.append(measure)
    score.append(part)
    report = ops.whistle_fingerings(score, part, whistle)
    note = next(iter(part.recurse().notes))
    holes = "".join(l.text for l in sorted(note.lyrics, key=lambda l: l.number)
                    if l.number <= 6)
    overblown = any(l.number == 7 for l in note.lyrics)
    return holes, overblown, report["unplayable_count"] == 0


FAILURES = []


def expect(pitch, holes, overblown=False, whistle="D"):
    got_holes, got_over, playable = fingering(pitch, whistle)
    if not playable or got_holes != holes or got_over != overblown:
        FAILURES.append(
            f"{whistle} whistle, {pitch}: expected {holes}"
            f"{' +' if overblown else ''}, got {got_holes or '(none)'}"
            f"{' +' if got_over else ''}")


def expect_unplayable(pitch, whistle="D"):
    holes, _, playable = fingering(pitch, whistle)
    if playable:
        FAILURES.append(f"{whistle} whistle, {pitch}: expected unplayable, got {holes}")


# the D-major scale, first octave: one hole lifts at a time
expect("D4",  "XXXXXX")
expect("E4",  "XXXXXO")
expect("F#4", "XXXXOO")
expect("G4",  "XXXOOO")
expect("A4",  "XXOOOO")
expect("B4",  "XOOOOO")
expect("C#5", "OOOOOO")            # top of the FIRST octave: not overblown

# the same fingerings an octave up, overblown
expect("D5",  "XXXXXX", overblown=True)
expect("G5",  "XXXOOO", overblown=True)
expect("C#6", "OOOOOO", overblown=True)

# the cross-fingerings every whistle player knows
expect("C5",  "OXXOOO")            # C natural: "oxx ooo"
expect("F5",  "XXXOXX", overblown=True)   # F natural: "xxx oxx"
expect("F4",  "XXXOXX")
expect("B-4", "XOXXXO")

# half-holed accidentals
expect("E-4", "XXXXX/")
expect("G#4", "XXX/OO")

# The TOP of the range, which was wrong here before it was wrong on Ali's
# page. This asserted that D6 -- the tonic two octaves up -- was outside the
# instrument. It is not: it is all six holes covered and blown hard, it is in
# every tutor book, and it is the top note of a great many tunes, so treating
# it as out of range put a gap under a note players use constantly.
expect("D6",  "XXXXXX", overblown=True)
# Above it is where the honest line falls. The third-octave E is possible on
# some instruments and standard on none, so it is reported rather than guessed.
expect_unplayable("E6")

# outside the instrument
expect_unplayable("C4")            # below the low D
expect_unplayable("A3")

# THE SAME PITCH, SPELLED THE OTHER WAY.
#
# Ali's screenshot: diagrams under most notes and none under three of them,
# circled, "missing tablature". The chart was keyed by the pitch's NAME, so a
# D# found no entry -- and was reported as having no standard fingering -- while
# the E-flat it is played identically to found one. Every enharmonic failed the
# same way, and optical recognition and transposition both produce those
# spellings freely, which is how a run of ordinary notes ends up with holes in
# it. A fingering is a fact about a SOUNDING pitch: one hole pattern per
# semitone, twelve of them.
for flat, sharp in (("E-4", "D#4"), ("F#4", "G-4"), ("G#4", "A-4"),
                    ("B-4", "A#4"), ("C#5", "D-5"), ("C5", "B#4"),
                    ("B4", "C-5"), ("F4", "E#4"), ("E4", "F-4")):
    left, left_over, left_ok = fingering(flat)
    right, right_over, right_ok = fingering(sharp)
    if not (left == right and left_over == right_over and left_ok and right_ok):
        FAILURES.append(f"{flat} and {sharp} are the same pitch and must be the "
                        f"same fingering: {left} vs {right}")
    print(f"  ok   {flat} and {sharp} are one fingering: {left}"
          if left == right and left_ok and right_ok
          else f"  FAIL {flat} {left} != {sharp} {right}")

# A C whistle is the same chart transposed down a tone, so its home scale is
# C major: all covered is C, and the flattened seventh (B flat) takes the same
# cross-fingering that C natural takes on a D whistle.
expect("C4",  "XXXXXX", whistle="C")
expect("D4",  "XXXXXO", whistle="C")
expect("B4",  "OOOOOO", whistle="C")
expect("B-4", "OXXOOO", whistle="C")
expect("C5",  "XXXXXX", overblown=True, whistle="C")



# --- where the fingerings land ----------------------------------------------

def charted_part(pitches=("D4", "E4", "D5"), symbols=("D", "G")):
    """A whistle part that also carries a chord chart, which is ordinary: a
    tune is written with its changes over it."""
    score = stream.Score()
    part = stream.Part()
    part.partName = "Whistle"
    measure = stream.Measure(number=1)
    measure.append(meter.TimeSignature("4/4"))
    for name in symbols:
        measure.insert(0.0, m21harmony.ChordSymbol(name))
    for name in pitches:
        measure.append(m21note.Note(name, quarterLength=1))
    part.append(measure)
    score.append(part)
    return score, part


def note(msg, ok):
    if not ok:
        FAILURES.append(msg)


score, part = charted_part()
report = ops.whistle_fingerings(score, part, "D")
symbols = [n for n in part.recurse().notes if isinstance(n, m21harmony.Harmony)]
tunes = [n for n in part.recurse().notes if not isinstance(n, m21harmony.Harmony)]
note(f"a chord symbol is not a note to be fingered: {[len(s.lyrics) for s in symbols]}",
     len(symbols) == 2 and all(not s.lyrics for s in symbols))
note(f"and the notes still are: {report}",
     report["notes_fingered"] == 3 and all(n.lyrics for n in tunes))

# tab over fingerings: the tab takes the verses, correctly named, and says so
tab = ops.guitar_tab(score, part, "EADGBE")
labels = {str(ly.identifier or "") for n in tunes for ly in n.lyrics}
note(f"tab written over fingerings takes the verses cleanly: {labels}",
     labels == {ops.TAB_LYRIC_TAG})
note(f"...and says how many notes it took them from: {tab}",
     tab["whistle_fingerings_replaced"] == 3)

# and back the other way, including the overblown seventh verse
again = ops.whistle_fingerings(score, part, "D")
labels = {str(ly.identifier or "") for n in tunes for ly in n.lyrics}
note(f"fingerings written over tab take the verses cleanly: {labels}",
     labels == {ops.WHISTLE_LYRIC_TAG})
note(f"...and say how many notes they took them from: {again}",
     again["guitar_tab_replaced"] == 3)
note("the overblown mark is back on the note that needs it",
     any(ly.number == 7 for ly in tunes[2].lyrics))

# clearing one leaves the other alone -- a different rule from writing over it
ops.guitar_tab(score, part, "EADGBE")
cleared = ops.whistle_fingerings(score, part, "D", clear=True)
note(f"clearing fingerings that are not there takes nothing: {cleared}",
     cleared["cleared"] == 0 and all(n.lyrics for n in tunes))
ops.whistle_fingerings(score, part, "D")
tab_cleared = ops.guitar_tab(score, part, "EADGBE", clear=True)
note(f"and clearing a tab that is not there takes nothing either: {tab_cleared}",
     tab_cleared["cleared"] == 0 and all(n.lyrics for n in tunes))
mine = ops.whistle_fingerings(score, part, "D", clear=True)
note(f"clearing its own fingerings takes them: {mine}",
     mine["cleared"] == 3 and not any(n.lyrics for n in tunes))

# ---------------------------------------------- every note, over a whole part
#
# The assertion Ali asked for, and the one the per-pitch checks above could not
# make: a diagram under EVERY note of a whistle part, and the count to prove it.
# His screenshot had diagrams under most notes and gaps under three, and every
# check here passed at the time, because each one asked about a pitch it had
# thought to name. This one asks about all of them at once:
#
#     notes fingered + notes reported unplayable == notes on the staff
#
# Over a real write and read, because that is the score the app holds: nothing
# in this app is ever engraved from a stream built in memory.
def round_tripped(score):
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "whistle.musicxml"
        score.write("musicxml", fp=str(path))
        return converter.parse(str(path), forceSource=True)


# A tune in the shape of the ones this is for: D major, up to the top D, with
# the spellings optical recognition and transposition actually produce.
TUNE = ["D4", "E4", "F#4", "G4", "A4", "B4", "C#5", "D5",
        "E5", "F#5", "G5", "A5", "B5", "C#6", "D6", "D5",
        "D#4", "A#4", "G-4", "A-4", "D-5", "B#4",       # enharmonics
        "F4", "C5", "E-4", "G#4",                        # the cross- and half-holes
        "A3", "E6"]                                      # genuinely out of range

whole = stream.Score()
whole_part = stream.Part()
for index in range(0, len(TUNE), 4):
    measure = stream.Measure(number=index // 4 + 1)
    if index == 0:
        measure.append(meter.TimeSignature("4/4"))
    for pitch in TUNE[index:index + 4]:
        measure.append(m21note.Note(pitch, quarterLength=1))
    whole_part.append(measure)
whole.append(whole_part)

whole_report = ops.whistle_fingerings(whole, whole_part, "D")
reloaded = round_tripped(whole)
reloaded_part = next(iter(reloaded.parts))
staff_notes = [n for n in reloaded_part.recurse().notes
               if not isinstance(n, m21harmony.Harmony)]


def has_full_fingering(n):
    """Six holes on this note, tagged as fingerings."""
    holes = [ly for ly in n.lyrics
             if str(ly.identifier or "") == ops.WHISTLE_LYRIC_TAG
             and (ly.number or 0) <= 6]
    return len(holes) == 6 and all(ly.text in (ops.COVERED, ops.OPEN, ops.HALF)
                                   for ly in holes)


drawn = [n for n in staff_notes if has_full_fingering(n)]
bare = [n for n in staff_notes if not has_full_fingering(n)]
reported = {(u["bar"], u["pitch"]) for u in whole_report["unplayable"]}

print(f"\n  whole part: {len(staff_notes)} notes on the staff, {len(drawn)} fingered, "
      f"{whole_report['unplayable_count']} reported out of range "
      f"({', '.join(sorted(p for _, p in reported)) or 'none'})")
note(f"the part survived the round trip whole: {len(staff_notes)} notes",
     len(staff_notes) == len(TUNE))
note(f"every note is either fingered or reported: "
     f"{len(drawn)} + {whole_report['unplayable_count']} of {len(staff_notes)}",
     len(drawn) + whole_report["unplayable_count"] == len(staff_notes))
note(f"and the bare ones are exactly the reported ones: "
     f"{[n.pitch.nameWithOctave for n in bare]}",
     len(bare) == whole_report["unplayable_count"]
     and all((ops.bar_label(n), n.pitch.nameWithOctave) in reported for n in bare))
note(f"the only notes without a diagram are the two out of range: {sorted(reported)}",
     {p for _, p in reported} == {"A3", "E6"})
note("the top D is fingered rather than reported",
     all(u["pitch"] != "D6" for u in whole_report["unplayable"]))
note("and the overblown mark survives the write, on the notes above the octave",
     all(any(ly.number == 7 and str(ly.identifier or "") == ops.WHISTLE_LYRIC_TAG
             for ly in n.lyrics)
         for n in staff_notes
         if n.pitch.ps >= ops.m21pitch.Pitch("D5").ps and has_full_fingering(n)))

# --- the bar a report names is a bar the page has ---------------------------
#
# music21 numbers a pickup 0. A report that passes that number through says
# "bar 0", and one did, on a photographed screen: "3 notes (B3 in bars 0, 3,
# and 11)" for a tune whose bar 0 is its upbeat. No page prints a bar 0 and
# `--from-measure` starts at 1, so the reader is sent to a bar that is not
# there. The pickup is named; every other bar is its own number.
print("\na pickup is named rather than numbered 0")

pickup_score = stream.Score()
pickup_part = stream.Part()
upbeat = stream.Measure(number=0)
upbeat.append(meter.TimeSignature("4/4"))
upbeat.paddingLeft = 3.0
upbeat.append(m21note.Note("A3", quarterLength=1))     # below a D whistle
pickup_part.append(upbeat)
first = stream.Measure(number=1)
first.append(m21note.Note("A3", quarterLength=1))      # and again, in bar 1
first.append(m21note.Note("E5", quarterLength=3))      # this one plays
pickup_part.append(first)
pickup_score.append(pickup_part)
pickup_report = ops.whistle_fingerings(pickup_score, pickup_part, "D")
pickup_bars = [u["bar"] for u in pickup_report["unplayable"]]

note(f"both out-of-range notes are reported: {pickup_bars}",
     len(pickup_bars) == 2)
note("the upbeat is called the pickup, not bar 0",
     pickup_bars[0] == "pickup")
note("and the bar after it is still 1",
     pickup_bars[1] == "1")
note("no report carries a zero for a bar",
     not any(u.get("bar") in (0, "0") for u in pickup_report["unplayable"]))

# ...and the other half, which the first version of this got WRONG and shipped.
# music21's ABC reader numbers EVERY tune from 0, so a bar 0 is usually just
# the first bar. Only `paddingLeft` says an anacrusis: a full bar 0 is a bar,
# and calling it "the pickup" mislabels every jig in the library.
whole_first = stream.Score()
whole_part = stream.Part()
bar_zero = stream.Measure(number=0)          # numbered 0, but a WHOLE bar
bar_zero.append(meter.TimeSignature("4/4"))
bar_zero.append(m21note.Note("A3", quarterLength=4))
whole_part.append(bar_zero)
bar_one = stream.Measure(number=1)
bar_one.append(m21note.Note("E5", quarterLength=4))
whole_part.append(bar_one)
whole_first.append(whole_part)
whole_first_report = ops.whistle_fingerings(whole_first, whole_part, "D")
whole_bars = [u["bar"] for u in whole_first_report["unplayable"]]

note(f"a FULL bar numbered 0 is not a pickup and is not called one: {whole_bars}",
     whole_bars == ["0"])

print("\na part with no name is found by the name the refusal offers (0.17.0)")
# Ali's Molly Ban: the chat asked for fingerings "under Part", was told "No part
# matches 'Part'. Available parts: ['Part']", and had to fall back to #0. A
# part with no name is LISTED as "Part" (ops.part_label), so it must answer to it.
from music21 import stream as m21stream  # noqa: E402
nameless = m21stream.Score()
nameless_part = m21stream.Part()
nameless_measure = m21stream.Measure(number=1)
nameless_measure.append(m21note.Note("D5", quarterLength=4))
nameless_part.append(nameless_measure)
nameless.insert(0, nameless_part)
offered = ops.list_part_labels(nameless)
note(f"the refusal lists it as {offered}", offered == ["Part"])
try:
    found = ops.find_parts(nameless, offered)
    note("...and that name finds it", found == [nameless.parts[0]])
except ValueError as exc:
    note(f"...and that name finds it: {exc}", False)

if FAILURES:
    print(f"FAIL: {len(FAILURES)} fingering(s) wrong")
    for line in FAILURES:
        print("   ", line)
    sys.exit(1)
print("OK: whistle fingerings match the published chart, and land on the notes")
