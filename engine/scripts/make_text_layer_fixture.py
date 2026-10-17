"""Build the fixture `check_pdf_text.py` reads: a printed lead sheet and its scan.

The text-layer pass (`scoranger_engine.pdftext`) corrects a SCANNER's reading
of an ENGRAVED PDF, so its fixture is both: a PDF an engraver printed, and the
MusicXML a scanner read off it. Neither can be made inside the check -- the
check runs where MuseScore and Audiveris are not installed -- so this script
makes them once and they are committed beside it, under `text-layer/`
(not `testdata/`, which is gitignored because it holds other people's scores):

  lantern.musicxml   the TRUTH: the tune as written, built here in music21
  lantern.pdf        MuseScore 4's engraving of it, with a block of stanzas
                     printed under the music the way a song sheet prints them
  lantern.mxl        Audiveris 5.11's reading of lantern.pdf (as an image,
                     which is how the app sends it)
  lantern-chords.*   the same tune with its chord names and NO words, and no
                     stanzas: a lead sheet the page has to be lined up with by
                     its chord names alone

The tune and its words are written for this file. No setting or lyric is
copied from anybody's, because the repository is public.

Run (needs /Applications/MuseScore 4.app and ~/Applications/Audiveris.app):
    engine/.venv/bin/python engine/scripts/make_text_layer_fixture.py
"""

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent / "text-layer"
MSCORE = Path("/Applications/MuseScore 4.app/Contents/MacOS/mscore")
AUDIVERIS = Path.home() / "Applications/Audiveris.app/Contents/MacOS/Audiveris"

TITLE = "The Lantern on the Quay"
COMPOSER = "Scoranger test fixture"

# (pitch, quarter length) per bar, 6/8 in G. A pickup, then sixteen bars.
PICKUP = [("D4", 0.5)]
BARS = [
    [("G4", 1.0), ("A4", 0.5), ("B4", 0.75), ("A4", 0.25), ("G4", 0.5)],
    [("E4", 1.0), ("D4", 0.5), ("G4", 1.5)],
    [("B4", 0.5), ("C5", 0.5), ("D5", 0.5), ("E5", 1.0), ("D5", 0.5)],
    [("B4", 1.5), ("A4", 1.0), ("D4", 0.5)],
    [("G4", 1.0), ("A4", 0.5), ("B4", 0.75), ("A4", 0.25), ("G4", 0.5)],
    [("E4", 1.0), ("D4", 0.5), ("G4", 0.5), ("B4", 0.5), ("D5", 0.5)],
    [("C5", 0.5), ("B4", 0.5), ("A4", 0.5), ("G4", 1.0), ("F#4", 0.5)],
    [("G4", 2.5), ("B4", 0.5)],
    [("D5", 1.0), ("B4", 0.5), ("D5", 0.75), ("E5", 0.25), ("D5", 0.5)],
    [("C5", 1.0), ("A4", 0.5), ("C5", 1.5)],
    [("B4", 0.5), ("A4", 0.5), ("G4", 0.5), ("E4", 1.0), ("G4", 0.5)],
    [("A4", 1.5), ("A4", 1.0), ("B4", 0.5)],
    [("D5", 1.0), ("B4", 0.5), ("D5", 0.75), ("E5", 0.25), ("D5", 0.5)],
    [("C5", 1.0), ("A4", 0.5), ("B4", 0.5), ("G4", 0.5), ("E4", 0.5)],
    [("D4", 0.5), ("G4", 0.5), ("A4", 0.5), ("B4", 1.0), ("A4", 0.5)],
    [("G4", 3.0)],
]

# Verse 1 over every note; verse 2 over bars 9-16. "-" ends a syllable that
# continues; "" is a note with no syllable. Written for this fixture.
VERSE_1 = ("By", "the", "lan-", "tern", "on", "the", "quay", "I", "wait-", "ed", "for", "the",
           "tide", "to", "turn", "a-", "way", "and", "the", "gulls", "went", "home", "to",
           "the", "end", "of", "the", "day", "and", "I", "sang", "to", "the", "riv-", "er",
           "a", "song", "for", "the", "night", "and", "the", "wa-", "ter", "came", "back", "with",
           "a", "rib-", "bon", "of", "light", "in", "the", "dark", "of", "the", "har-", "bour",
           "it", "glim-", "mered", "and", "shone", "and", "it", "stayed", "till", "the", "morn-",
           "ing", "had", "come")
VERSE_2 = ("So", "I", "car-", "ried", "it", "home", "in", "the", "palm", "of", "my", "hand",
           "and", "I", "set", "it", "to", "burn", "by", "the", "door", "on", "the", "strand",
           "where", "the", "boats", "still", "come", "in", "and", "the", "nets", "are", "laid",
           "down", "ev-", "ery", "eve-", "ning", "a-", "gain", "by", "the", "light", "of", "the",
           "town")

# (bar, offset in quarters, name) -- on downbeats and on the second beat of 6/8
CHORDS = [(1, 0.0, "G"), (1, 1.5, "D"), (2, 0.0, "Em"), (2, 1.5, "G"), (3, 0.0, "C"),
          (4, 0.0, "D7"), (5, 0.0, "G"), (5, 1.5, "D"), (6, 0.0, "Em"), (7, 0.0, "Am"),
          (7, 1.5, "D7"), (8, 0.0, "G"), (9, 0.0, "G"), (10, 0.0, "Am"), (11, 0.0, "Em"),
          (11, 1.5, "C"), (12, 0.0, "D"), (13, 0.0, "G"), (14, 0.0, "Am"), (14, 1.5, "Em"),
          (15, 0.0, "C"), (15, 1.5, "D7"), (16, 0.0, "G")]

STANZAS = [
    "When the lantern is lit and the harbour is still,",
    "There's a light on the quay and a light on the hill,",
    "And whoever comes home by the water tonight",
    "Will be guided ashore by the lantern's own light.",
    "",
    "Words and music written for the Scoranger test suite.",
]


def build_truth(words: bool = True):
    from music21 import harmony, key, meter, metadata, note, stream

    from scoranger_engine import ops

    score = stream.Score()
    score.metadata = metadata.Metadata(title=TITLE, composer=COMPOSER)
    score.metadata.movementName = TITLE
    part = stream.Part()
    part.partName = "Voice"
    words1 = iter(VERSE_1)
    words2 = iter(VERSE_2)

    def sing(n, word, verse):
        if not word or not words:
            return
        syllabic = "begin" if word.endswith("-") else None
        n.lyrics.append(note.Lyric(text=word.rstrip("-"), number=verse,
                                   syllabic=syllabic or "single", applyRaw=True))

    pickup = stream.Measure(number=0)
    pickup.append(key.Key("G"))
    pickup.append(meter.TimeSignature("6/8"))
    for pitch, ql in PICKUP:
        n = note.Note(pitch, quarterLength=ql)
        sing(n, next(words1), 1)
        pickup.append(n)
    pickup.padAsAnacrusis()
    part.append(pickup)
    for number, bar in enumerate(BARS, start=1):
        m = stream.Measure(number=number)
        for pitch, ql in bar:
            n = note.Note(pitch, quarterLength=ql)
            sing(n, next(words1, ""), 1)
            if number >= 9:
                sing(n, next(words2, ""), 2)
            m.append(n)
        for bar_no, offset, name in CHORDS:
            if bar_no == number:
                m.insert(offset, ops.chord_symbol_from_text(name))
        part.append(m)
    _fix_syllabic(part)
    score.insert(0, part)
    return score


def _fix_syllabic(part):
    """begin ... end: a syllable after a continuing one closes the word."""
    from music21 import harmony

    open_word: dict[int, bool] = {}
    for n in part.recurse().notes:
        if isinstance(n, harmony.Harmony):
            continue
        for lyric in n.lyrics:
            before = open_word.get(lyric.number, False)
            after = lyric.syllabic == "begin"
            lyric.syllabic = {(False, False): "single", (False, True): "begin",
                              (True, True): "middle", (True, False): "end"}[(before, after)]
            open_word[lyric.number] = after


def stanza_overlay(pdf: Path, out: Path) -> None:
    """The stanza block printed under the music, as a song sheet prints it."""
    import cairosvg
    import pypdf

    page = pypdf.PdfReader(str(pdf)).pages[0]
    width, height = float(page.mediabox.width), float(page.mediabox.height)
    lines = []
    y = height - 190
    for line in STANZAS:
        if line:
            lines.append(f'<text x="72" y="{y:.1f}" font-family="Times New Roman" '
                         f'font-size="13">{line}</text>')
        y += 18
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
           f'viewBox="0 0 {width} {height}">{"".join(lines)}</svg>')
    overlay = out.with_suffix(".overlay.pdf")
    cairosvg.svg2pdf(bytestring=svg.encode(), write_to=str(overlay))
    reader = pypdf.PdfReader(str(pdf))
    base = reader.pages[0]
    base.merge_page(pypdf.PdfReader(str(overlay)).pages[0])
    writer = pypdf.PdfWriter()
    writer.add_page(base)
    for extra in reader.pages[1:]:
        writer.add_page(extra)
    with open(out, "wb") as fh:
        writer.write(fh)
    overlay.unlink()


def main() -> int:
    sys.path.insert(0, str(ROOT / "engine"))
    for tool in (MSCORE, AUDIVERIS):
        if not tool.exists():
            print(f"needs {tool}")
            return 1
    OUT.mkdir(parents=True, exist_ok=True)
    for name, words in (("lantern", True), ("lantern-chords", False)):
        if make(name, words) != 0:
            return 1
    print(f"wrote {OUT}")
    return 0


def make(name: str, words: bool) -> int:
    truth = build_truth(words)
    truth_path = OUT / f"{name}.musicxml"
    truth.write("musicxml", fp=str(truth_path))
    with tempfile.TemporaryDirectory(prefix="scoranger-text-layer-") as tmp:
        tmp = Path(tmp)
        engraved = tmp / "engraved.pdf"
        # MuseScore 4.7 writes the PDF and then aborts on its way out (SIGABRT
        # in its crash reporter), so the file, not the exit code, is the test
        subprocess.run([str(MSCORE), "-o", str(engraved), str(truth_path)],
                       capture_output=True)
        if not engraved.exists() or engraved.stat().st_size == 0:
            print("MuseScore wrote no PDF")
            return 1
        if words:
            stanza_overlay(engraved, OUT / f"{name}.pdf")
        else:
            shutil.copy(engraved, OUT / f"{name}.pdf")
        scans = tmp / "omr"
        subprocess.run([str(AUDIVERIS), "-batch", "-export", "-output", str(scans),
                        str(OUT / f"{name}.pdf")], check=True, capture_output=True)
        found = next(scans.rglob("*.mxl"))
        shutil.copy(found, OUT / f"{name}.mxl")
    return 0


if __name__ == "__main__":
    sys.exit(main())
