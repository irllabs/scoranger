"""Words, from chat and from the page: the 0.21.0 lyric ops and what draws them.

ABC words arriving on import are check_abc_lyrics.py; words read off a PDF
are check_pdf_text.py. This is what a reader then DOES with words.

WHAT IS ASSERTED

  1. The ops, through the `scor` BINARY and read back off disk: `set-lyrics`
     writes a verse from one line with hyphens, `~`, `_` and `|`; a second
     verse goes under the same notes; `edit-lyric` changes one word and keeps
     its note, verse and size; `adjust-element --style` sets italic and bold
     beside a size; `lyrics` lists them with the ordinals the ops take;
     `clear-lyrics` takes a verse off. A note with no syllable left is a
     refusal that names the bar's onsets.
  2. A WHISTLE COLUMN AND A TAB KEEP THE WORDS. Both took verses 1-7 and 1-6
     outright and a sung word there was deleted. Now the words move above
     the column, "verse 1" still means the first verse of words, and clearing
     the column brings them back down.
  3. The words stay under the staff when the column goes above it, on the
     first lines below the staff, on every note of that staff -- including a
     note out of the whistle's range, which has no column (render).
  4. A word's size and style reach the PDF export's page.
  5. THE APP'S ADDRESS FOR A WORD IS THE ENGINE'S. The app numbers a bar's
     words note by note across layers and verse by verse, skipping fingering
     and tab verses (MEISemanticsParser.swift); this mirrors that rule over
     the MEI the real Verovio writes and asserts every address resolves,
     through `ops._elements_in_measure`, to the word the MEI says it is --
     on a bar of two verses written out of order, beside a whistle column.

Run: engine/.venv/bin/python engine/scripts/check_lyrics.py
"""

import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "engine"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
SCOR = ROOT / "engine" / ".venv" / "bin" / "scor"

FAILURES: list[str] = []


def check(condition: bool, message: str) -> None:
    print(f"  {'ok  ' if condition else 'FAIL'} {message}")
    if not condition:
        FAILURES.append(message)


def words(score, part=0) -> list[tuple[int, int, str, str, str]]:
    """(bar, verse, text, syllabic, name) of every WORD, in note order."""
    from scoranger_engine import ops

    out = []
    p = score.parts[part]
    base = ops.word_base(p)
    for n in ops._sung(p):
        for lyric in sorted(ops.word_verses(n), key=lambda l: int(l.number or 0)):
            out.append((n.measureNumber, int(lyric.number) - base, lyric.text,
                        lyric.syllabic, str(lyric.identifier)))
    return out


def mirror_app_addresses(mei: str) -> dict[str, tuple[int, int, int]]:
    """MEISemanticsParser's rule for WORDS: verse xml:id -> (staff, measure, ordinal)."""
    import xml.etree.ElementTree as ET

    root = ET.fromstring(mei)
    ns = {"m": "http://www.music-encoding.org/ns/mei"}
    xmlid = "{http://www.w3.org/XML/1998/namespace}id"
    out = {}
    for measure in root.iter("{http://www.music-encoding.org/ns/mei}measure"):
        number = int(measure.get("n"))
        for staff in measure.findall("m:staff", ns):
            found = []
            note_index = 0
            for layer in staff.findall("m:layer", ns):
                for event in layer.iter():
                    tag = event.tag.split("}")[-1]
                    inside_chord = tag == "note" and any(
                        event in list(c.iter()) for c in layer.iter("{http://www.music-encoding.org/ns/mei}chord"))
                    if tag == "chord" or (tag == "note" and not inside_chord):
                        for verse in event.iter("{http://www.music-encoding.org/ns/mei}verse"):
                            label = verse.get("label") or ""
                            if label.startswith(("wf", "gt")):
                                continue
                            found.append((note_index, int(verse.get("n")), verse.get(xmlid)))
                        note_index += 1
            for ordinal, (_, _, vid) in enumerate(sorted(found)):
                out[vid] = (int(staff.get("n")), number, ordinal)
    return out


def main() -> int:  # noqa: C901 -- a checklist reads better whole
    import fixtures
    from music21 import converter, note

    from scoranger_engine import ops, render

    with tempfile.TemporaryDirectory(prefix="scoranger-lyrics-") as tmp:
        tmp = Path(tmp)
        env = dict(os.environ, SCORANGER_WORKSPACE=str(tmp / "ws"),
                   PYTHONPATH=str(ROOT / "engine"))

        def scor(*args: str) -> dict:
            proc = subprocess.run([str(SCOR), *args], capture_output=True, text=True, env=env)
            if proc.returncode != 0:
                raise AssertionError(f"scor {' '.join(args)}: {proc.stderr[-300:]}")
            return json.loads(proc.stdout)

        def refused(*args: str) -> str:
            proc = subprocess.run([str(SCOR), *args], capture_output=True, text=True, env=env)
            return "" if proc.returncode == 0 else json.loads(proc.stderr)["error"]

        def latest(slug: str):
            out = tmp / f"{slug}.musicxml"
            scor("export", slug, "--format", "musicxml", "--out", str(out))
            return converter.parse(str(out), forceSource=True)

        source = tmp / "jig.musicxml"
        fixtures.jig(bars=4).write("musicxml", fp=str(source))
        slug = scor("import", str(source), "--name", "Words")["score"]

        print("1. the ops, through the binary")
        r = scor("set-lyrics", slug, "--part", "#0", "--measure", "1",
                 "--text", "Ban-bridge town in~the | Coun-ty_ Down")
        check(r["details"]["syllables"] == 7 and r["details"]["to"] == {"bar": "2"},
              f"set-lyrics reports what it wrote and how far it went ({r['details']})")
        got = words(latest(slug))
        check(got[:7] == [(1, 1, "Ban", "begin", "1"), (1, 1, "bridge", "end", "1"),
                          (1, 1, "town", "single", "1"), (1, 1, "in the", "single", "1"),
                          (2, 1, "Coun", "begin", "1"), (2, 1, "ty", "end", "1"),
                          (2, 1, "Down", "single", "1")],
              f"one line of words, laid on the notes by the ABC rules ({got[:3]})")
        scor("set-lyrics", slug, "--part", "#0", "--measure", "1", "--verse", "2",
             "--text", "un deux trois")
        listed = scor("lyrics", slug)["parts"][0]
        bar1 = listed["bars"][0]["words"]
        check(listed["verses"] == [1, 2] and [w["text"] for w in bar1[:4]] == ["Ban", "un", "bridge", "deux"],
              "a second verse goes under the same notes, and lyrics lists note by note, verse by verse")
        scor("adjust-element", slug, "--part", "#0", "--kind", "lyric", "--measure", "1",
             "--ordinal", "0", "--scale", "1.5")
        scor("adjust-element", slug, "--part", "#0", "--kind", "lyric", "--measure", "1",
             "--ordinal", "0", "--style", "bold-italic")
        scor("edit-lyric", slug, "--part", "#0", "--measure", "1", "--ordinal", "0", "--text", "Bann-")
        first = words(latest(slug))[0]
        check(first == (1, 1, "Bann", "begin", "ly@1.5~bi"),
              f"edit-lyric changes the word and keeps its note, verse, size and style ({first})")
        bar1 = scor("lyrics", slug)["parts"][0]["bars"][0]["words"]
        check(bar1[0].get("scale") == 1.5 and bar1[0].get("style") == "bold-italic",
              "lyrics reports the size and the style")
        why = refused("set-lyrics", slug, "--part", "#0", "--measure", "1", "--offset", "0.25",
                      "--text", "nowhere")
        check("starts notes at" in why, f"a word aimed between notes is refused with the onsets ({why[:80]})")
        rested = fixtures.jig(bars=2)
        bar_one = rested.parts[0].getElementsByClass("Measure")[0]
        opening = list(bar_one.notes)[0]
        bar_one.replace(opening, note.Rest(quarterLength=opening.quarterLength))
        from_rest = ops.set_lyrics(rested, "#0", "a b", 1)
        check(from_rest["from"] == {"bar": "1", "offset": opening.quarterLength},
              f"words 'from bar 1' over a bar that opens on a rest start on its first note, "
              f"and say so ({from_rest['from']})")
        scor("clear-lyrics", slug, "--part", "#0", "--verse", "2")
        check({v for _, v, *_ in words(latest(slug))} == {1}, "clear-lyrics takes verse 2 off")

        print("\n2. a whistle column and a tab keep the words")
        scor("whistle-fingerings", slug, "--part", "#0")
        score = latest(slug)
        kept = words(score)
        check(len(kept) == 7 and kept[0][2] == "Bann", f"every word survives the whistle ({len(kept)})")
        check(all(int(l.number) > ops.WHISTLE_VERSES for n in ops._sung(score.parts[0])
                  for l in ops.word_verses(n)),
              "and is numbered above the column's seven verses")
        check(scor("lyrics", slug)["parts"][0]["verses"] == [1], "which a reader still calls verse 1")
        scor("set-lyrics", slug, "--part", "#0", "--measure", "3", "--text", "la la")
        score = latest(slug)
        third = [w for w in words(score) if w[0] == 3]
        check([w[1] for w in third] == [1, 1] and all(
            str(l.identifier) != "wf" for n in ops._sung(score.parts[0]) for l in ops.word_verses(n)),
            "a word written beside the column is verse 1 too, and is no fingering")
        scor("whistle-fingerings", slug, "--part", "#0", "--clear")
        score = latest(slug)
        check(min(int(l.number) for n in ops._sung(score.parts[0]) for l in ops.word_verses(n)) == 1,
              "clearing the column brings the words back to verse 1")
        scor("guitar-tab", slug, "--part", "#0")
        score = latest(slug)
        check(len(words(score)) == 9 and min(
            int(l.number) for n in ops._sung(score.parts[0]) for l in ops.word_verses(n)) == 7,
            "a tab keeps them too, below its six strings")
        scor("guitar-tab", slug, "--part", "#0", "--clear")

        print("\n3-4. what draws them")
        sc = fixtures.jig(bars=4)
        part = sc.parts[0]
        for i, n in enumerate(ops._sung(part)):
            n.lyrics.append(note.Lyric(text=f"w{i}", number=1, applyRaw=True))
        # one note out of the whistle's range: it gets no column, and its word
        # must still sit on the same line as its neighbours'
        ops._sung(part)[-1].transpose(-24, inPlace=True)
        ops.whistle_fingerings(sc, part, "D")
        ops.adjust_element(sc, "#0", kind="lyric", measure=1, ordinal=0, scale=1.5, style="italic")
        xml = tmp / "sung.musicxml"
        sc.write("musicxml", fp=str(xml))
        import verovio
        tk = verovio.toolkit()
        tk.loadFile(str(xml))
        lifted = render.mei_with_fingerings_above(tk.getMEI())
        check(lifted is not None, "the column is lifted though its notes carry words")
        word_verses = [v for v in re.findall(r"<verse\b[^>]*>.*?</verse>", lifted or "", re.S)
                       if 'label="wf' not in v]
        check(word_verses and all('place="above"' not in v for v in word_verses),
              "the words are not lifted with it")
        check(word_verses and all(re.search(r'\bn="1"', v) for v in word_verses),
              f"every word is drawn on the first line under the staff ({len(word_verses)} words)")
        check(render.WORD_VERSES_AFTER_COLUMN == ops.WHISTLE_VERSES,
              "the renderer and the engine agree where a whistle part's words start")
        svg = render.apply_lyric_sizes(tk.renderToSVG(1))
        styled = re.search(r'<text\b[^>]*font-style="italic"[^>]*>\s*<tspan[^>]*>\s*'
                           r'<tspan font-size="607.5px">w0<', svg)
        check(styled is not None, "a word's size and style reach the exported page, on that word")

        print("\n5. the app's address for a word is the engine's")
        sc = fixtures.jig(bars=2)
        part = sc.parts[0]
        notes = ops._sung(part)
        for i, n in enumerate(notes):
            # verse 2 written BEFORE verse 1 on every other note
            if i % 2:
                n.lyrics.append(note.Lyric(text=f"b{i}", number=2, applyRaw=True))
                n.lyrics.append(note.Lyric(text=f"a{i}", number=1, applyRaw=True))
            else:
                n.lyrics.append(note.Lyric(text=f"a{i}", number=1, applyRaw=True))
        ops.whistle_fingerings(sc, part, "D")
        xml = tmp / "join.musicxml"
        sc.write("musicxml", fp=str(xml))
        reread = converter.parse(str(xml), forceSource=True)
        tk = verovio.toolkit()
        tk.loadFile(str(xml))
        mei = render.mei_with_fingerings_above(tk.getMEI()) or tk.getMEI()
        addresses = mirror_app_addresses(mei)
        texts = {}
        for verse in re.finditer(r'<verse\b[^>]*xml:id="([^"]+)"[^>]*>.*?<syl[^>]*>([^<]*)</syl>', mei, re.S):
            texts[verse.group(1)] = verse.group(2)
        measures = {m.number: m for m in reread.parts[0].getElementsByClass("Measure")}
        wrong = []
        for vid, (_staff, number, ordinal) in addresses.items():
            found = ops._elements_in_measure(measures[number], "lyric")
            got = found[ordinal][1].text if ordinal < len(found) else None
            if got != texts.get(vid):
                wrong.append((number, ordinal, texts.get(vid), got))
        check(len(addresses) == sum(len(ops.word_verses(n)) for n in notes) and not wrong,
              f"every word's address resolves to that word ({len(addresses) - len(wrong)}/{len(addresses)}; {wrong[:3]})")

    if FAILURES:
        print(f"\nlyrics: {len(FAILURES)} failed")
        return 1
    print("\nlyrics: words are written, kept, drawn and addressed as the reader means them")
    return 0


def write_fixture() -> int:
    """The page LyricSelectionTests taps words on: a real Verovio engraving.

    Two verses (written out of order on every other note), a whistle column
    lifted above the staff, and the MEI the page was drawn from, so the app's
    geometry and addresses are built exactly as on device.
    Run: engine/.venv/bin/python engine/scripts/check_lyrics.py --write-fixture
    """
    import fixtures
    import verovio
    from music21 import note

    from scoranger_engine import ops, render

    sc = fixtures.jig(bars=2)
    for i, n in enumerate(ops._sung(sc.parts[0])):
        words = [note.Lyric(text=f"a{i}", number=1, applyRaw=True)]
        if i % 2:
            words.insert(0, note.Lyric(text=f"b{i}", number=2, applyRaw=True))
        n.lyrics.extend(words)
    ops.whistle_fingerings(sc, sc.parts[0], "D")
    out = ROOT / "ios" / "ScorangerTests" / "Fixtures"
    with tempfile.TemporaryDirectory() as tmp:
        xml = Path(tmp) / "words.musicxml"
        sc.write("musicxml", fp=str(xml))
        tk = verovio.toolkit()
        tk.setOptions({"breaks": "none"})
        tk.loadFile(str(xml))
        mei = render.mei_with_fingerings_above(tk.getMEI()) or tk.getMEI()
        tk.loadData(mei)
        (out / "words-page.mei").write_text(tk.getMEI(), encoding="utf-8")
        (out / "words-page.svg").write_text(tk.renderToSVG(1), encoding="utf-8")
    print(f"wrote {out}/words-page.mei and words-page.svg")
    return 0


if __name__ == "__main__":
    sys.exit(write_fixture() if "--write-fixture" in sys.argv else main())
