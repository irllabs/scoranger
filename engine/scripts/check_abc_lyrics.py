"""ABC words reach the notes they are written under, by the ABC 2.1 rules.

music21 10.5 reads a `w:` line and keeps none of it, so every song imported
from ABC arrived as a tune with no words. `enrich.scan_lyrics` and
`enrich.restore_lyrics` put them back (0.21.0). This check drives the `scor`
BINARY, exports the version and reads the FILE back, because words that are
right in a stream and missing from the MusicXML have not been imported.

The tunes are synthetic and written for this file; no setting is copied from
anybody's transcription, because the repository is public.

WHAT IS ASSERTED, one rule of ABC 2.1 §5 at a time:

  1. A `-` splits a word into syllables (begin/end), `~` keeps two words on
     one note, `_` holds a syllable over the next note and `*` skips one --
     both leave that note with no syllable.
  2. `|` moves on to the next bar when the syllables have not reached it,
     and is ignored when they have.
  3. A rest and a grace note take no syllable; each note of a TIE takes its
     own; a chord takes one.
  4. ADJACENT `w:` lines are verses 1 and 2 over the same notes. A stanza
     number ("2.") is printed in front of the first syllable rather than
     taking a note; written with `~` ("1.~One") it is part of that syllable.
  5. A `w:` that is NOT adjacent to the last one carries on from the first
     note after the notes the last one covered, and `+:` continues a line.
  6. Syllables past the last note are ignored, and COUNTED.
  7. A tune of several voices keeps no words, and is NAMED in the report --
     a verse one note out is worse than a verse reported missing.
  8. Words and decorations in one tune both arrive: the lyric stage counts
     notes by the decorations' own grammar and changes nothing it returns.
  9. `W:` lines are words after the tune: counted, and on no note.

Run: engine/.venv/bin/python engine/scripts/check_abc_lyrics.py
"""

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "engine"))

SCOR = ROOT / "engine" / ".venv" / "bin" / "scor"

FAILURES: list[str] = []


def check(condition: bool, message: str) -> None:
    if condition:
        print(f"  ok   {message}")
    else:
        print(f"  FAIL {message}")
        FAILURES.append(message)


def scor(env: dict, *args: str) -> dict:
    proc = subprocess.run([str(SCOR), *args], capture_output=True, text=True, env=env)
    if proc.returncode != 0:
        raise AssertionError(f"scor {' '.join(args)} exited {proc.returncode}: "
                             f"{(proc.stderr or proc.stdout).strip()[-400:]}")
    return json.loads(proc.stdout)


def sung(env: dict, slug: str, out: Path) -> list[tuple[str, list[tuple[int, str, str]]]]:
    """(pitch, [(verse, text, syllabic)]) for every sung note of the WRITTEN file."""
    from music21 import converter, harmony

    scor(env, "export", slug, "--format", "musicxml", "--out", str(out))
    score = converter.parse(str(out), forceSource=True)
    rows = []
    for n in score.recurse().notes:
        if isinstance(n, harmony.Harmony) or n.duration.isGrace:
            continue
        name = n.nameWithOctave if n.isNote else "chord"
        rows.append((name, sorted((int(l.number), l.text, l.syllabic) for l in n.lyrics)))
    return rows


RULES = """X: 1
T: Syllable Rules
M: 4/4
L: 1/4
K: C
C D E F | G A B c |
w: Ban-bridge town in~the | Coun-ty_ *
d e f g | a b c' d' |
w: one | two three
"""

VERSES = """X: 1
T: Verse Rules
M: 3/4
L: 1/4
K: D
D z {B}A | F2- F | [DF] E D |
w: 1.~One two three four five six
w: 2. Un deux trois quatre cinq six
A B c | d e f |
w: sev-en
+: eight nine ten
w: huit
B A G |
w: a b c d e f g h
W: These are words after the tune,
W: and they belong to no note.
"""

VOICES = """X: 1
T: Two Voices
M: 4/4
L: 1/4
K: G
V: 1
G A B c |
w: one two three four
V: 2
G, A, B, C |
w: un deux trois quatre
"""

DECORATED = """X: 1
T: Rolled Words
M: 4/4
L: 1/4
K: G
~G A !trill!B c |
w: roll-ing a trill
"""


def write(root: Path, name: str, text: str) -> Path:
    path = root / f"{name}.abc"
    path.write_text(text, encoding="utf-8")
    return path


def main() -> int:  # noqa: C901 -- a checklist reads better whole
    with tempfile.TemporaryDirectory(prefix="scoranger-abc-lyrics-") as tmp:
        root = Path(tmp)
        env = dict(os.environ, SCORANGER_WORKSPACE=str(root / "ws"),
                   PYTHONPATH=str(ROOT / "engine"))

        print("1-2. syllables, joins, holds, skips and bars")
        r = scor(env, "import", str(write(root, "rules", RULES)))
        abc = r.get("abc") or {}
        check(abc.get("lyrics_carried") == 9,
              f"the report counts 9 syllables carried (got {abc.get('lyrics_carried')})")
        rows = sung(env, r["score"], root / "rules.musicxml")
        want = [
            ("C4", [(1, "Ban", "begin")]),
            ("D4", [(1, "bridge", "end")]),
            ("E4", [(1, "town", "single")]),
            ("F4", [(1, "in the", "single")]),       # `~`: two words, one note
            ("G4", [(1, "Coun", "begin")]),          # `|` already reached: ignored
            ("A4", [(1, "ty", "end")]),
            ("B4", []),                              # `_` held over it
            ("C5", []),                              # `*` skipped it
            ("D5", [(1, "one", "single")]),
            ("E5", []), ("F5", []), ("G5", []),      # `|` moved on past them
            ("A5", [(1, "two", "single")]),
            ("B5", [(1, "three", "single")]),
            ("C6", []), ("D6", []),
        ]
        check(rows == want, "each syllable is on the note the rules put it on")
        if rows != want:
            for got, exp in zip(rows, want):
                if got != exp:
                    print(f"         got {got}, want {exp}")

        print("3-6. rests, grace notes, ties, chords, verses, continuation")
        r = scor(env, "import", str(write(root, "verses", VERSES)))
        abc = r.get("abc") or {}
        rows = sung(env, r["score"], root / "verses.musicxml")
        pitches = [p for p, _ in rows]
        check(pitches[:6] == ["D4", "A4", "F#4", "F#4", "chord", "E4"],
              f"the rest and the grace note are not sung notes (got {pitches[:6]})")
        lyr = {i: dict((v, t) for v, t, _ in words) for i, (_, words) in enumerate(rows)}
        check(lyr[0] == {1: "1. One", 2: "2. Un"},
              f"a stanza number goes in front of the first syllable (got {lyr[0]})")
        check(lyr[1] == {1: "two", 2: "deux"} and lyr[2] == {1: "three", 2: "trois"}
              and lyr[3] == {1: "four", 2: "quatre"},
              "adjacent lines are verses 1 and 2, and each note of a tie takes a syllable")
        check(lyr[4] == {1: "five", 2: "cinq"},
              f"a chord takes one syllable (got {lyr[4]})")
        check(lyr[6] == {}, f"the line's seventh note has no syllable left for it (got {lyr[6]})")
        check(rows[7][1] == [(1, "sev", "begin"), (2, "huit", "single")]
              and rows[8][1] == [(1, "en", "end")]
              and [lyr[i] for i in (9, 10, 11)] == [{1: "eight"}, {1: "nine"}, {1: "ten"}],
              "a later w: carries on after the notes the last one covered, +: continues "
              "it, and a w: right after it is its second verse")
        check([lyr[i] for i in (13, 14, 15)] == [{1: "a"}, {1: "b"}, {1: "c"}],
              "the last line's first three syllables land on its three notes")
        check(abc.get("lyrics_unplaced") == 5,
              f"the five syllables past the last note are counted "
              f"(got {abc.get('lyrics_unplaced')})")
        check(abc.get("lyric_verses") == 2, "the report says two verses")
        check(abc.get("words_after_tune") == 2,
              f"the two W: lines are counted (got {abc.get('words_after_tune')})")
        all_text = {t for _, words in rows for _, t, _ in words}
        check(not any("belong" in t or "These" in t for t in all_text),
              "W: words are on no note")

        print("7. several voices: no words, and named")
        r = scor(env, "import", str(write(root, "voices", VOICES)))
        abc = r.get("abc") or {}
        withheld = abc.get("lyrics_withheld") or []
        check(any(w.get("title") == "Two Voices" for w in withheld),
              f"the tune is named as keeping no words (got {withheld})")
        check(not abc.get("lyrics_carried"), "and no syllable was placed")

        print("8. decorations and words in one tune")
        r = scor(env, "import", str(write(root, "decorated", DECORATED)))
        abc = r.get("abc") or {}
        check(abc.get("decorations_carried") == 2,
              f"both decorations still arrive (got {abc.get('decorations_carried')})")
        rows = sung(env, r["score"], root / "decorated.musicxml")
        check([w for _, w in rows] == [[(1, "roll", "begin")], [(1, "ing", "end")],
                                       [(1, "a", "single")], [(1, "trill", "single")]],
              f"and the words land on the notes the decorations are on (got {[w for _, w in rows]})")

    if FAILURES:
        print(f"\nABC lyrics: {len(FAILURES)} failed")
        return 1
    print("\nABC lyrics: every word on the note ABC 2.1 puts it on")
    return 0


if __name__ == "__main__":
    sys.exit(main())
