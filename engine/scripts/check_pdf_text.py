"""A PDF's own text corrects what the scanner read off it (0.21.0, `pdftext`).

The fixture is a lead sheet engraved by MuseScore 4 with a stanza block
printed under the music, and Audiveris 5.11's reading of it -- made once by
`make_text_layer_fixture.py` and committed under `engine/scripts/text-layer/`,
because neither program is here when the checks run. `lantern.musicxml` is
what was engraved, so every syllable and chord is checked against the TRUTH
rather than against an expectation written down beside the code.

What the scanner made of it, for the record: 34 of 98 syllables right, 16 of
23 chord names, none on the last system, five lines of the stanza block hung
on the notes as extra verses, and a bar number read as page text.

WHAT IS ASSERTED

  1. Every printed syllable is on the note it is printed under, with its
     hyphen where the page draws one; every chord name on the note it is
     printed over; nothing extra on either.
  2. The stanza block is reported as text below the music, line by line and
     readable, and is on no note; the bar number read as a credit is gone
     and the title and composer are not.
  3. With no PDF the scanner's positions alone still take the stanza lines
     off the notes and the misread credit off the page -- what a scan with
     no text layer gets.
  3b. A lead sheet with chord names and NO words lines up by its chord
     names alone -- left edge to left edge, every repeated "G" and "D" sorted
     out by agreement, the scanner having read chords on its first system
     only -- and every chord lands.
  4. A PDF that is not the one the scanner read does not line up, is NAMED
     as not lining up, and leaves the scanner's words where they were.
  4b. A PDF whose only text is a header has no printed words to line up and
     counts no page as misaligned; one that prints the scanner's words in the
     wrong places counts its page.
  5. The two ways the app transcribes, through the bridge it ships: a new
     version of a scan arrangement (the scan is the PDF), and a straight
     import handed the PDF. Both write the corrected score to disk and
     return the report; the version's history keeps its counts.
  6. `scor import --pdf`, the desktop path, through the binary.

Run: engine/.venv/bin/python engine/scripts/check_pdf_text.py
"""

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "engine"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
FIXTURE = Path(__file__).resolve().parent / "text-layer"
TRUTH, PDF, SCAN = (FIXTURE / "lantern.musicxml", FIXTURE / "lantern.pdf",
                    FIXTURE / "lantern.mxl")
SCOR = ROOT / "engine" / ".venv" / "bin" / "scor"

FAILURES: list[str] = []


def check(condition: bool, message: str) -> None:
    print(f"  {'ok  ' if condition else 'FAIL'} {message}")
    if not condition:
        FAILURES.append(message)


def table(score):
    """(bar, beat, verse) -> (syllable, syllabic), and (bar, beat) -> chord."""
    from music21 import harmony, stream

    words, chords = {}, {}
    for m in score.parts[0].getElementsByClass(stream.Measure):
        for n in m.recurse().notes:
            at = round(float(n.getOffsetInHierarchy(m)), 3)
            if isinstance(n, harmony.Harmony):
                chords[(m.number, at)] = n.figure
            else:
                for lyric in n.lyrics:
                    words[(m.number, at, int(lyric.number))] = (lyric.text, lyric.syllabic)
    return words, chords


def credits(score) -> list[str]:
    from music21 import text

    return [str(box.content) for box in score.getElementsByClass(text.TextBox)]


def main() -> int:  # noqa: C901 -- a checklist reads better whole
    from music21 import converter

    from scoranger_engine import pdftext

    truth_words, truth_chords = table(converter.parse(str(TRUTH), forceSource=True))
    scanned = converter.parse(str(SCAN), forceSource=True)
    read_words, read_chords = table(scanned)
    print(f"the scanner read {sum(read_words.get(k, (None,))[0] == v[0] for k, v in truth_words.items())}"
          f" of {len(truth_words)} syllables and {sum(read_chords.get(k) == v for k, v in truth_chords.items())}"
          f" of {len(truth_chords)} chord names right")
    check(any(k[2] > 2 for k in read_words),
          "the scanner hung lines of the stanza block on the notes as extra verses "
          "(the fixture still shows the fault)")

    print("\n1-2. the text layer, against the truth")
    report = pdftext.correct(scanned, SCAN, PDF)
    words, chords = table(scanned)
    check(report["pages_lined_up"] == 1, "the page lines up")
    wrong = {k: (v, words.get(k)) for k, v in truth_words.items() if words.get(k) != v}
    check(not wrong, f"every syllable on its note with its hyphen ({len(truth_words) - len(wrong)}"
                     f"/{len(truth_words)})")
    for k, (want, got) in list(wrong.items())[:6]:
        print(f"         bar {k[0]} beat {k[1]} verse {k[2]}: want {want}, got {got}")
    check(not set(words) - set(truth_words), "and no syllable on a note the page puts none under")
    check(chords == truth_chords,
          f"every chord name on its note, none extra ({sum(chords.get(k) == v for k, v in truth_chords.items())}"
          f"/{len(truth_chords)}, {len(set(chords) - set(truth_chords))} extra)")
    below = report["text_below_music"]
    check("When the lantern is lit and the harbour is still," in below
          and "Will be guided ashore by the lantern's own light." in below,
          f"the stanza block is reported line by line, readable (got {below[:2]})")
    check(report["lines_not_verses"] >= 1, "the scanner's stanza verses are counted as not verses")
    check(credits(scanned) == ["The Lantern on the Quay", "Scoranger test fixture"],
          f"the misread credit is gone and the title and composer stay (got {credits(scanned)})")

    print("\n3. no PDF: the scanner's positions alone")
    bare = converter.parse(str(SCAN), forceSource=True)
    report = pdftext.correct(bare, SCAN, None)
    words, _ = table(bare)
    check(report["pages_lined_up"] == 0 and not report["text_layer"], "no text layer is used")
    check(not any(k[2] > 2 for k in words), "the stanza lines are on no note")
    check(any("lantern" in line.lower() for line in report["text_below_music"]),
          "and are reported as text below the music")
    check(credits(bare) == ["The Lantern on the Quay", "Scoranger test fixture"],
          "the misread credit is gone on a scan too")

    print("\n3b. chords and no words: lined up by the chord names")
    chart_truth = converter.parse(str(FIXTURE / "lantern-chords.musicxml"), forceSource=True)
    _, chart_chords = table(chart_truth)
    chart = converter.parse(str(FIXTURE / "lantern-chords.mxl"), forceSource=True)
    _, chart_read = table(chart)
    report = pdftext.correct(chart, FIXTURE / "lantern-chords.mxl", FIXTURE / "lantern-chords.pdf")
    words, chords = table(chart)
    check(report["pages_lined_up"] == 1,
          f"the page lines up with no words on it ({report['pages_not_lined_up']})")
    check(chords == chart_chords,
          f"every chord name on its note: {sum(chords.get(k) == v for k, v in chart_chords.items())}"
          f"/{len(chart_chords)}, against the scanner's "
          f"{sum(chart_read.get(k) == v for k, v in chart_chords.items())}")
    check(not words and not report["chords_unplaced"],
          f"and nothing else is taken for a word or a chord ({report['chords_unplaced']})")

    print("\n4. a PDF that is not this one")
    # another engraving with words of its own, made here: a vector PDF the
    # scanner's reading cannot be lined up with
    import fixtures
    from music21 import note
    from scoranger_engine import ops, render

    other_tune = fixtures.jig(bars=8)
    for i, n in enumerate(ops._sung(other_tune.parts[0])):
        n.lyrics.append(note.Lyric(text=f"other{i}", number=1, applyRaw=True))
    other_dir = Path(tempfile.mkdtemp(prefix="scoranger-other-pdf-"))
    other_tune.write("musicxml", fp=str(other_dir / "other.musicxml"))
    other_pdf = other_dir / "other.pdf"
    render.render_pdf(str(other_dir / "other.musicxml"), str(other_pdf))
    other = converter.parse(str(SCAN), forceSource=True)
    before, _ = table(other)
    report = pdftext.correct(other, SCAN, other_pdf)
    after, _ = table(other)
    check(report["pages_lined_up"] == 0 and report["pages_not_lined_up"],
          f"it does not line up, and says so ({report['pages_not_lined_up'][:1]})")
    check({k: v for k, v in after.items()} == {k: v for k, v in before.items() if k[2] <= 2},
          "the scanner's words stay as read, less the lines that are not verses")

    print("\n4b. a PDF whose only text is a header, and one whose words are scattered")
    # The Cat's Meow (0.23.2): a tunebook page whose text layer holds its
    # header and nothing under the music. There are no printed words to line
    # up, so the reader is not told that they did not line up.
    import random

    import fitz

    def made_pdf(name: str, texts: list[tuple[str, float, float]]) -> Path:
        doc = fitz.open()
        page = doc.new_page(width=595, height=842)
        for text, x, y in texts:
            page.insert_text((x, y), text, fontsize=10)
        path = other_dir / name
        doc.save(str(path))
        return path

    header = made_pdf("header.pdf", [("Click any tune title to play the tune", 40, 40),
                                     ("TheCat'sMeow", 40, 52), ("Jig", 40, 64)])
    report = pdftext.correct(converter.parse(str(SCAN), forceSource=True), SCAN, header)
    check(report["text_layer"] and report["pages_lined_up"] == 0
          and report["pages_misaligned"] == 0,
          f"a header is not printed words: nothing to tell ({report['pages_not_lined_up'][:1]})")
    # the same syllables the page prints, put anywhere: they are there and do
    # not line up, which the reader IS told
    rng = random.Random(7)
    scattered = made_pdf("scattered.pdf", [(text, rng.uniform(30, 540), rng.uniform(60, 800))
                                           for text in truth_words.values()])
    report = pdftext.correct(converter.parse(str(SCAN), forceSource=True), SCAN, scattered)
    check(report["pages_lined_up"] == 0 and report["pages_misaligned"] == 1,
          f"printed words that do not line up are counted ({report['pages_not_lined_up'][:1]})")

    with tempfile.TemporaryDirectory(prefix="scoranger-pdf-text-") as tmp:
        tmp = Path(tmp)
        os.environ["SCORANGER_WORKSPACE"] = str(tmp / "ws")
        sys.path.insert(0, str(ROOT / "ios" / "PythonApp" / "app"))
        import bridge  # noqa: E402 -- the bridge the app ships

        def call(op: str, args: dict) -> dict:
            out = json.loads(bridge.handle(json.dumps({"op": op, "args": args})))
            if not out.get("ok"):
                raise AssertionError(f"{op}: {out.get('error')}")
            return out["result"]

        def written(slug: str):
            from scoranger_engine import workspace

            return converter.parse(str(workspace.resolve_notation_path(slug)), forceSource=True)

        print("\n5a. the app: a transcription becomes the scan's next version")
        scan = call("import-pdf", {"path": str(PDF), "name": "Lantern, scanned"})
        slug = scan["score"]
        result = call("add-version-from-file", {"score": slug, "path": str(SCAN), "op": "omr"})
        check(result.get("text_pass", {}).get("chords") == len(truth_chords),
              f"the reply carries the report ({result.get('text_pass', {}).get('chords')} chords)")
        words, chords = table(written(slug))
        check(words == truth_words and chords == truth_chords,
              "the version ON DISK has the printed words and chords")
        from scoranger_engine import workspace
        history = workspace.list_versions(slug)
        kept = history[-1].get("args", {}).get("text_pass", {})
        check(kept.get("syllables") == len(truth_words) and "text_below_music" not in kept,
              f"the version's history keeps the counts, not the text ({sorted(kept)[:4]})")

        print("\n5b. the app: a transcription imported with its PDF beside it")
        result = call("import", {"path": str(SCAN), "name": "Lantern, read", "pdf": str(PDF)})
        words, chords = table(written(result["score"]))
        check(words == truth_words and chords == truth_chords and result.get("text_pass"),
              "the import is corrected and says so")

        print("\n6. the desktop: scor import --pdf")
        env = dict(os.environ, SCORANGER_WORKSPACE=str(tmp / "ws-cli"),
                   PYTHONPATH=str(ROOT / "engine"))
        proc = subprocess.run([str(SCOR), "import", str(SCAN), "--pdf", str(PDF)],
                              capture_output=True, text=True, env=env)
        check(proc.returncode == 0, f"the binary accepts --pdf {proc.stderr[-200:]}")
        out = json.loads(proc.stdout or "{}")
        check(out.get("text_pass", {}).get("syllables") == len(truth_words),
              "and reports what the text layer corrected")

    if FAILURES:
        print(f"\nPDF text: {len(FAILURES)} failed")
        return 1
    print("\nPDF text: the words and chords are the ones the page prints")
    return 0


if __name__ == "__main__":
    sys.exit(main())
