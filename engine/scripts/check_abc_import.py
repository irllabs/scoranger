"""ABC import, driven as the PROCESS a reader drives, plus what it costs.

Ali gets tunes from thesession.org, which publishes Irish traditional music as
ABC. This check starts the `scor` BINARY -- argparse wiring, the subcommand
name, the flag mapping, what `_emit` prints -- because an op that works when a
check calls its function and dies when a person runs it has not shipped.
`scor whistle-fingerings` was dead for months behind a check that called
`ops.whistle_fingerings` directly.

THE ENGINE IT RUNS. `engine/.venv` is a symlink in every worktree, so the
binary's own `scoranger_engine` resolves to the MAIN checkout unless PYTHONPATH
says otherwise. The first section proves the process is running the source in
THIS tree; without it a worktree could pass against code it does not contain.

WHY THE FIXTURES ARE ABC TEXT, which nothing else in this repo is. The golden
rule is that notation is never written as text, and every other fixture is a
music21 stream built in `fixtures.py`. It cannot be one here: ABC *is* text,
music21 has no ABC WRITER (`ConverterABC.registerOutputExtensions` is empty),
and a check that fed this reader anything but ABC would be testing nothing.
The tunes below are short, synthetic and written for this file -- no setting
is copied from anybody's transcription, because the repository is public.

WHAT IS ASSERTED

  1. A modal key. `K: Edor` must come back E dorian with two sharps. Irish
     repertoire is full of Dorian and Mixolydian and silently reading them as
     major would make the whole feature useless rather than merely lossy.
  2. The two rules that decide what a multi-tune file becomes, TOGETHER, in
     one fixture: several tunes import as several arrangements, and an
     arrangement with no piece gets one named after itself. Two tunes sharing
     a title land in ONE piece; the third, named differently, gets its own.
     Neither rule mentions ABC.
  3. A set written as ONE `X:` block -- several tunes joined by a mid-body
     `T:`/`K:`, which is how thesession.org publishes a set -- stays ONE
     arrangement with a key change, because that is what a set is.
  4. What survives to the FILE, read back off disk after an export rather
     than inspected in a stream: repeats, first and second endings, the
     pickup bar, triplets, grace notes, slurs, staccato, chord symbols and
     the `Q:` tempo.
  5. Decorations are CARRIED and counted -- `~` rolls and `!...!` marks
     reach the written file through `enrich.read_abc`, and the report says
     how many did. Only the `R:` tune type is still reported rather than
     stored: it has nowhere to live in MusicXML. check_abc_decorations.py
     proves the marks one at a time; this proves the report on a download.
  6. `piece-combine`, the curation step that makes rule 2 safe: the survivor
     keeps its slug, its own arrangements keep their numbers, the absorbed
     ones append, and the emptied piece is gone.

Run: engine/.venv/bin/python engine/scripts/check_abc_import.py
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

SCOR = ROOT / "engine" / ".venv" / "bin" / "scor"
PYTHON = ROOT / "engine" / ".venv" / "bin" / "python"

FAILURES: list[str] = []


def check(condition: bool, message: str) -> None:
    if condition:
        print(f"  ok   {message}")
    else:
        print(f"  FAIL {message}")
        FAILURES.append(message)


def run(env: dict, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run([str(SCOR), *args], capture_output=True, text=True,
                          env=env)


def scor(env: dict, *args: str) -> dict:
    """One `scor` command that is expected to succeed, as parsed JSON."""
    proc = run(env, *args)
    if proc.returncode != 0:
        raise AssertionError(
            f"scor {' '.join(args)} exited {proc.returncode}: "
            f"{(proc.stderr or proc.stdout).strip()[-400:]}")
    return json.loads(proc.stdout)


def refusal(env: dict, *args: str) -> str:
    """One `scor` command that is expected to be refused. Returns the message."""
    proc = run(env, *args)
    if proc.returncode == 0:
        raise AssertionError(f"scor {' '.join(args)} was accepted: {proc.stdout[:300]}")
    return str(json.loads(proc.stderr)["error"])


def written(env: dict, slug: str, out: Path):
    """The latest version, exported through the binary and read back off disk.

    Read back, never inspected in memory: an import can be perfectly correct
    in a stream and still leave a file that has lost the repeats.
    """
    from music21 import converter

    scor(env, "export", slug, "--format", "musicxml", "--out", str(out))
    return converter.parse(str(out), forceSource=True)


# -- the fixtures -------------------------------------------------------------
# thesession.org's header order and spelling, which is what a downloaded file
# looks like: X, T, R, M, L, K, then the tune.

MODAL = """X: 1
T: The Dorian Test
R: reel
M: 4/4
L: 1/8
K: Edor
|:E2BE dEBE|E2BE AFDF|E2BE dEBE|BABc dAFD:|
"""

# Three tunes. Two carry the SAME `T:` -- which is what a tune's page
# downloads, every setting of one tune -- and the third is a different tune.
# One piece of two arrangements, and one piece of one.
COLLECTION = """X: 1
T: Two Settings
R: jig
M: 6/8
L: 1/8
K: Gmaj
|:GAG GAB|ABA ABd|edd gdd|BAF G3:|

X: 2
T: Two Settings
R: jig
M: 6/8
L: 1/8
K: Gmaj
|:G2G GAB|A2A ABd|e2d gdd|BAF G3:|

X: 3
T: A Different Tune
R: slip jig
M: 9/8
L: 1/8
K: Emin
|:B2E G2E F3|B2d d2B AFD:|
"""

# A set as thesession.org publishes one: ONE `X:` block, two tunes joined by a
# second `T:`/`K:` part-way down. Played as one continuous thing, so it is one
# arrangement with a key change -- not two.
SET_IN_ONE_BLOCK = """X: 1
T: First Of The Set, Second Of The Set.
R: reel
M: 4/4
L: 1/8
K: Dmaj
|:FAAB AFED|FAAB dAFA:|
T: Second Of The Set
R: reel
M: 4/4
L: 1/8
K: Gmaj
|:GBBA BGED|GBBA dBGB:|
"""

# Everything a real download throws at the reader at once, and a unicode title.
# `~`, `!trill!` and `.` are here to be CARRIED and counted.
FEATURES = """X: 1
T: Sí Beag Féatúr
C: Trad.
R: hornpipe
M: 4/4
L: 1/8
Q: 1/4=180
K: Ador
"Am"A>B|:"Am"c2 ~e2 (3efg a2|"G"{d}B2 d2 !trill!g2 b2|\
"Am"(c2 e2) a2 .g2|1 "G"e4 d2 AB:|2 "G"e4 d4|]
"""


def write(root: Path, name: str, text: str) -> Path:
    path = root / name
    path.write_text(text, encoding="utf-8")
    return path


def main() -> int:  # noqa: C901 -- a checklist reads better whole
    from music21 import stream as m21stream

    root = Path(tempfile.mkdtemp(prefix="abc-import-"))
    env = dict(os.environ)
    env["SCORANGER_WORKSPACE"] = str(root / "workspace")
    env["PYTHONPATH"] = str(ROOT / "engine")

    print("the binary runs the engine in this checkout")
    probe = subprocess.run(
        [str(PYTHON), "-c",
         "import scoranger_engine; print(scoranger_engine.__file__)"],
        capture_output=True, text=True, env=env)
    where = Path(probe.stdout.strip()) if probe.stdout.strip() else None
    check(SCOR.exists(), f"the scor binary is at {SCOR}")
    check(where is not None and ROOT in where.parents,
          f"scoranger_engine resolves inside this tree: {where}")

    # ------------------------------------------------------------- modal ---
    print("\na modal key, which this repertoire is full of")
    out = scor(env, "import", str(write(root, "modal.abc", MODAL)))
    check(out["name"] == "The Dorian Test",
          f"the `T:` header is the title: {out['name']!r}")
    info = scor(env, "info", out["score"])
    check(info["key_signatures"] == ["E dorian"],
          f"`K: Edor` read as E dorian, not major: {info['key_signatures']}")
    check(info["time_signatures"] == ["4/4"],
          f"the meter survives: {info['time_signatures']}")
    score = written(env, out["score"], root / "modal.musicxml")
    sig = list(score.flatten().getElementsByClass("KeySignature"))[0]
    check(sig.sharps == 2, f"and it keeps two sharps through the file: {sig.sharps}")
    check(getattr(sig, "mode", None) == "dorian",
          f"the MODE reaches the written file too, not just the sharp count: "
          f"{getattr(sig, 'mode', None)!r}")
    # 0.18.2: an ABC melody carries no part name, and the mixer showed "Part"
    # beside its fader level -- "Part 7" in the App Store screenshots.
    check([p["name"] for p in info["parts"]] == ["Melody"],
          f"the one unnamed part is named Melody: {[p['name'] for p in info['parts']]}")
    check(score.parts[0].partName == "Melody",
          f"...in the written file, so it travels: {score.parts[0].partName!r}")

    # ------------------------------------------ several tunes, two rules ---
    print("\nseveral tunes in one file, and the piece each one lands in")
    out = scor(env, "import", str(write(root, "collection.abc", COLLECTION)))
    check(out["tunes_found"] == 3, f"three tunes found: {out['tunes_found']}")
    check(len(out["arrangements"]) == 3,
          f"imported as three arrangements: {len(out['arrangements'])}")
    pieces = {row["piece"] for row in out["arrangements"]}
    check(len(pieces) == 2,
          f"into TWO pieces, because two of them share a title: {sorted(pieces)}")
    check(out["summary"] == "3 tunes found, imported as 3 arrangements of 2 pieces",
          f"and it SAYS so: {out['summary']!r}")
    names = [row["name"] for row in out["arrangements"]]
    check(names[:2] == ["Two Settings", "Two Settings"]
          and names[2] == "A Different Tune",
          f"each tune keeps its own name: {names}")

    listing = scor(env, "list")
    by_name = {p["name"]: p for p in listing["pieces"]}
    check(len(by_name.get("Two Settings", {}).get("arrangements", [])) == 2,
          "the shared-title piece holds both settings")
    check(len(by_name.get("A Different Tune", {}).get("arrangements", [])) == 1,
          "the other piece holds one")
    check(all(s.get("piece") for s in listing["scores"]),
          "no arrangement was left unfiled by the import")

    # ---------------------------------------------- a set is one thing ---
    print("\na set written as one X: block stays one arrangement")
    out = scor(env, "import", str(write(root, "set.abc", SET_IN_ONE_BLOCK)))
    check(out["tunes_found"] == 1,
          f"a mid-body T:/K: is not a second tune: {out['tunes_found']}")
    score = written(env, out["score"], root / "set.musicxml")
    keys = [k.sharps for k in score.flatten().getElementsByClass("KeySignature")]
    check(keys == [2, 1],
          f"it is one continuous score that changes key part-way: {keys}")

    # ------------------------------------------- what reaches the FILE ---
    print("\nwhat an ABC download carries, read back out of the written file")
    features = write(root, "features.abc", FEATURES)
    out = scor(env, "import", str(features))
    check(out["name"] == "Sí Beag Féatúr",
          f"a unicode title survives intact: {out['name']!r}")
    score = written(env, out["score"], root / "features.musicxml")
    part = score.parts[0]
    measures = list(part.getElementsByClass(m21stream.Measure))

    repeats = [b for m in measures for b in (m.leftBarline, m.rightBarline)
               if type(b).__name__ == "Repeat"]
    check(len(repeats) == 2,
          f"|: and :| survive as repeats: {len(repeats)}")
    brackets = sorted(x.number for x in
                      score.recurse().getElementsByClass("RepeatBracket"))
    check(brackets == ["1", "2"],
          f"|1 and |2 survive as first and second endings: {brackets}")
    check(measures[0].paddingLeft == 3.0,
          f"the pickup bar is a pickup, not a short bar: {measures[0].paddingLeft}")
    check(any(n.duration.tuplets and n.duration.tuplets[0].tupletActual
              for n in score.flatten().notes), "(3 survives as a triplet")
    check(any(n.duration.isGrace for n in score.flatten().notes),
          "{d} survives as a grace note")
    check(len(list(score.recurse().getElementsByClass("Slur"))) == 1,
          "( ) survives as a slur")
    check(any(type(a).__name__ == "Staccato"
              for n in score.flatten().notes for a in n.articulations),
          ". survives as a staccato")
    figures = [c.figure for c in score.recurse().getElementsByClass("ChordSymbol")]
    check(figures.count("Am") >= 3 and "G" in figures,
          f'"Am" and "G" survive as chord symbols: {sorted(set(figures))}')
    check([m.number for m in score.flatten().getElementsByClass("MetronomeMark")]
          is not None
          and any(m.number == 180 for m in
                  score.flatten().getElementsByClass("MetronomeMark")),
          "Q: 1/4=180 survives as a tempo mark")

    # --------------------------------------- what is carried, and said ---
    #
    # The decorations used to be LOST here and counted on the way out. They
    # are carried now -- `enrich.read_abc` strips them before music21 sees
    # them and attaches the music21 objects afterwards -- so the count in the
    # report is of marks that ARRIVED. What check_abc_decorations.py proves
    # mark by mark, this proves is reported on a real-shaped download.
    print("\nand the decorations are carried, and counted")
    said = out.get("abc") or {}
    check(said.get("decorations_carried") == 3,
          f"the ~ roll, the !trill! and the . staccato are all carried: "
          f"{said.get('decorations_carried')}")
    check(not said.get("decorations_misplaced"),
          f"none of them was declined: {said.get('decorations_misplaced')}")
    check(said.get("tune_types") == ["hornpipe"],
          f"`R:` is reported rather than stored: {said.get('tune_types')}")
    marks = sorted(type(e).__name__
                   for n in score.flatten().notes for e in n.expressions)
    check(marks == ["Trill", "Turn"],
          f"and they are really in the written file, not just counted: {marks}")

    # ---------------------------------------------------- combine-pieces ---
    print("\ncombining two pieces that are really one tune")
    before = {p["name"]: list(p["arrangements"]) for p in scor(env, "list")["pieces"]}
    kept = before["Two Settings"]
    out = scor(env, "piece-combine",
               "--pieces", "Two Settings,A Different Tune")
    check(out["piece"] == "two-settings",
          f"the first named survives, slug and all: {out['piece']}")
    check([a["name"] for a in out["absorbed"]] == ["A Different Tune"],
          f"and says what it absorbed: {out['absorbed']}")
    check(out["order"][:len(kept)] == kept,
          "the survivor's own arrangements keep the numbers they had")
    check(len(out["order"]) == len(kept) + 1
          and out["order"][-1] == before["A Different Tune"][0],
          f"the absorbed one appends: {out['order']}")
    after = {p["name"] for p in scor(env, "list")["pieces"]}
    check("A Different Tune" not in after,
          f"the emptied piece is gone: {sorted(after)}")
    check(all(s.get("piece") for s in scor(env, "list")["scores"]),
          "and nothing was orphaned on the way")

    message = refusal(env, "piece-combine", "--pieces", "Two Settings")
    check("two different pieces" in message,
          f"combining one piece is refused by name: {message!r}")

    # ------------------------------------------- the app can be offered it ---
    #
    # Asserted against the generated Info.plist, because the place it belongs
    # -- a unit test -- cannot do it: ScorangerTests has no host app, so
    # whether `com.scoranger.abc` resolves there depends on whether the UI
    # bundle happened to install the app first. This file is deterministic.
    print("\nthe app declares what it needs to be handed a tune")
    import plistlib

    plist_path = ROOT / "ios" / "Scoranger" / "Info.plist"
    check(plist_path.exists(), f"Info.plist is at {plist_path}")
    if plist_path.exists():
        plist = plistlib.loads(plist_path.read_bytes())
        imported = {d.get("UTTypeIdentifier"): d
                    for d in plist.get("UTImportedTypeDeclarations", [])}
        ours = imported.get("com.scoranger.abc")
        check(ours is not None, "com.scoranger.abc is declared")
        if ours:
            check("public.plain-text" in (ours.get("UTTypeConformsTo") or []),
                  f"it conforms to plain-text -- a tune is text, which is "
                  f"exactly what Alembic is not: {ours.get('UTTypeConformsTo')}")
            exts = (ours.get("UTTypeTagSpecification")
                    or {}).get("public.filename-extension") or []
            check("abc" in exts, f"and it claims the .abc extension: {exts}")
        # `.abc` is NOT a free extension: the system declares it as Alembic,
        # Pixar's 3D scene cache, and that is what a downloaded tune is
        # TAGGED as. Claiming only our own type greys every real tune out in
        # Files, so public.alembic has to be on the document type. This is
        # the assertion that stops someone tidying away a wrong-looking entry.
        types = [d for d in plist.get("CFBundleDocumentTypes", [])
                 if "com.scoranger.abc" in (d.get("LSItemContentTypes") or [])]
        check(bool(types), "a document type accepts com.scoranger.abc")
        if types:
            accepted = types[0].get("LSItemContentTypes") or []
            check("public.alembic" in accepted,
                  f"and public.alembic beside it, which is what the system "
                  f"actually tags a .abc file as: {accepted}")
            check(types[0].get("LSHandlerRank") == "Alternate",
                  f"at Alternate rank, because this app does not own an "
                  f"extension it shares with Alembic: "
                  f"{types[0].get('LSHandlerRank')}")

    if FAILURES:
        print(f"\nFAIL: {len(FAILURES)} ABC import check(s) failed")
        for f in FAILURES:
            print(f"    {f}")
        return 1
    print("\nOK: ABC imports through the binary -- modal keys, several tunes as "
          "several arrangements each with a piece, a set as one thing, and a "
          "report of what was lost")
    return 0


if __name__ == "__main__":
    sys.exit(main())
