"""Every op the bridge dispatches on is CALLED, not merely spelled the same.

`check_bridge_ops.py` compares two literal sets -- the op names Swift sends and
the op names `bridge.py` answers -- and that is a string comparison. It cannot
see an op that is wired up and raises, which is the other half of the same
family of bugs: `adjust-element` was absent, `delete-piece` was unknown, and
`scor whistle-fingerings` was present and threw NameError on every call.

So this check RUNS them. Each op is invoked through `bridge.handle`, the same
JSON-in/JSON-out entry point Swift calls, and a non-`ok` answer fails the
check.

It runs them on the DEVICE's sys.path, the way `check_books.py` does: the
embedded interpreter sees only the stdlib, PythonApp/app and
PythonApp/app_packages (PythonBridge.c), so a dependency that is merely
installed on this Mac does not count as shipped. That is what caught pypdf
missing from the vendored packages while every host-side check was green.

THE LEDGER. An op is either exercised below or named in NOT_EXERCISED with a
reason. An op in neither fails the check -- which is what stops this coverage
from rotting the next time someone adds a branch to the dispatch.

Fixtures are synthetic: the repository is public, so no committed fixture may
carry copyrighted music.

Run: engine/.venv/bin/python engine/scripts/check_bridge_coverage.py
"""

import json
import re
import subprocess
import sys
import tempfile
import textwrap
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "engine"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import fixtures  # noqa: E402

BRIDGE = ROOT / "ios" / "PythonApp" / "app" / "bridge.py"
APP = ROOT / "ios" / "PythonApp" / "app"
APP_PACKAGES = ROOT / "ios" / "PythonApp" / "app_packages"

FAILURES: list[str] = []

# Ops that are deliberately not called here, each with the reason. Anything not
# in this map and not exercised by the script below fails the check.
NOT_EXERCISED: dict[str, str] = {
    # `configure` is what makes every other call possible, so the child calls
    # it first and the ledger would be circular if it also claimed it.
    "configure": "the child's first call; asserted separately, not as a step",
}


def check(condition: bool, message: str) -> None:
    if condition:
        print(f"  ok   {message}")
    else:
        print(f"  FAIL {message}")
        FAILURES.append(message)


def bridge_ops() -> set[str]:
    """Every op name the bridge dispatches on -- the same read check_bridge_ops
    makes, kept identical on purpose so the two checks cannot disagree about
    what the bridge answers."""
    return set(re.findall(r'op == "([a-z0-9-]+)"', BRIDGE.read_text(encoding="utf-8")))


# The child program. It is the app's own entry point driven in order, because
# the ops chain: a score has to exist before it can be transposed, a piece
# before an arrangement is filed under it, a book before pages come out of it.
CHILD = r'''
import json, os, sys
sys.path = [p for p in sys.path
            if p and "site-packages" not in p and "dist-packages" not in p]
sys.path += [APP, PACKAGES]
os.environ["SCORANGER_WORKSPACE"] = WORKSPACE

import bridge

STEPS = []


def do(_name, **args):
    """One bridge call, recorded. Returns its result, or {} if it failed, so a
    single failure does not cascade into a hundred misleading ones.

    The op name is `_name` because two ops take an argument called `op`."""
    answer = json.loads(bridge.handle(json.dumps({"op": _name, "args": args})))
    result = answer.get("result")
    blob = json.dumps(result, default=str)
    STEPS.append({"op": _name, "ok": bool(answer.get("ok")),
                  "error": answer.get("error"),
                  "result": result if len(blob) <= 4000
                  else {"_truncated": sorted(result) if isinstance(result, dict) else "list"}})
    return result if isinstance(result, dict) else {}


configured = json.loads(bridge.handle(json.dumps(
    {"op": "configure", "args": {"workspace": WORKSPACE}})))

do("selftest")
do("manifest")

# -- one melody, and every mark that can sit on it ---------------------------
jig = do("import", path=JIG, name="Bridge Jig")["score"]
do("info", score=jig)
do("versions", score=jig)
do("version-file", score=jig)
do("analyze", score=jig)
do("check-range", score=jig, part="#0", instrument="Flute")
do("tags")

do("set-chords", score=jig, part="#0",
   chords=[{"measure": 1, "symbol": "Em"}, {"measure": 3, "symbol": "G"}])
do("chart-style", score=jig, part="#0")
# while the symbols are still there: the part ops below rebuild measures, and
# a diagram is drawn over a chord symbol or not at all
do("chord-diagrams", score=jig, part="#0")
# the op that makes the four below reachable from the app at all: nothing
# could ADD a dynamic or a fermata before this build. Bar 5 is the tied one --
# notes start at 0 and at 1.5, which is what a note-attached mark needs.
do("add-element", score=jig, part="#0", kind="dynamic", measure=5, value="p")
do("add-element", score=jig, part="#0", kind="text", measure=5,
   value="poco rit.", offset=1.5)
do("add-element", score=jig, part="#0", kind="fermata", measure=5, offset=0)
do("add-element", score=jig, part="#0", kind="articulation", measure=5,
   value="tenuto", offset=0)
do("adjust-element", score=jig, part="#0", kind="harm", measure=1, scale=1.5)
do("adjust-element", score=jig, part="#0", kind="dynamic", measure=1, scale=1.5)
do("adjust-element", score=jig, part="#0", kind="text", measure=1, offset_y=-6)
do("adjust-element", score=jig, part="#0", kind="fermata", measure=1, offset_y=-9)
do("adjust-element", score=jig, part="#0", kind="articulation", measure=1, scale=2)
do("move-element", score=jig, part="#0", kind="dynamic", measure=1,
   to_measure=3, to_offset=1.5)
do("duplicate-element", score=jig, part="#0", kind="fermata", measure=1,
   to_measure=4, to_offset=0)
do("remove-element", score=jig, part="#0", kind="articulation", measure=1,
   ordinal=0)

do("transpose", score=jig, interval="M2")
do("transpose-diatonic", score=jig, degrees=1)
do("transpose-elements", score=jig, interval="m2", elements=["s1/m1/l1/note#0"])
do("transpose-diatonic-elements", score=jig, degrees=1, elements=["s1/m1/l1/note#0"])
do("respell", score=jig, prefer="sharps")
do("clean-accidentals", score=jig)
do("set-accidental", score=jig, elements=["s1/m1/l1/note#0"], show=True)
do("set-rehearsal", score=jig, measure=3, mark="A")
do("set-structure", score=jig, kind="repeat-end", measure=4)
do("paginate", score=jig, measures_per_line=4)
do("staff-spacing", score=jig, staff=16, fingering_rows=4)
do("change-clef", score=jig, part="#0", clef="treble")
do("rename-part", score=jig, part="#0", name="Whistle", abbreviation="Whs")
do("octave-shift", score=jig, part="Whistle", octaves=-1, from_measure=1, to_measure=2)
do("limit-part", score=jig, part="Whistle", max_pitch="C6")
do("consolidate-ties", score=jig, parts=["Whistle"])
do("simplify-repeats", score=jig, part="Whistle")
# thin only, for the reason check_chat.py gives: augmenting halves the
# meter's denominator for the whole score and every op below would then
# be running on music in a different meter. Both modes: check_rhythm_simplify.py.
do("simplify-rhythm", score=jig, mode="thin", part="Whistle", unit="eighth")
do("flatten-voices", score=jig, part="Whistle")
do("whistle-fingerings", score=jig, part="Whistle", whistle="D")
do("guitar-tab", score=jig, part="Whistle")
do("change-instrument", score=jig, part="Whistle", to="Flute")
do("add-version-from-file", score=jig, path=OMR, op="omr", args={})

do("export", score=jig, format="musicxml")
do("export", score=jig, format="midi")
do("playback", score=jig)
do("set-metadata", score=jig, title="Bridge Jig", composer="Trad.")
do("rename-score", score=jig, name="Bridge Jig")
do("repair-titles")
do("begin-turn", score=jig, prompt="make it bigger")
do("end-turn")

# -- four staves, for everything that needs more than one --------------------
quartet = do("import", path=QUARTET, name="Bridge Quartet")["score"]
do("add-source", score=quartet, path=JIG, name="the jig")
do("source-file", score=quartet, source="s01")
do("pull-part", score=quartet, part="Pennywhistle", **{"from": "src:s01"})
do("absorb-part", score=quartet, source="Violin II", target="Violin I")
do("merge-parts", score=quartet, parts=["Viola", "Violoncello"],
   name="Accordion L.H.", clef="bass")
do("split-bass", score=quartet, part="Accordion L.H.",
   bass_name="Acc. Bass", chords_name="Acc. Chords")
do("keep-parts", score=quartet, parts=["Violin I", "Acc. Bass", "Acc. Chords"])
do("remove-parts", score=quartet, parts=["Acc. Chords"])
# the names-only staff. The engine and the CLI have had this op since before
# the bridge existed and the bridge had no route to it, so the app could not
# ask -- found while building a fixture that wanted one.
do("strip-notes", score=quartet, part="Acc. Bass")

# -- pieces and set lists ----------------------------------------------------
piece = do("create-piece", name="Reels")["slug"]
do("assign-piece", score=jig, piece=piece)
do("reorder-piece", piece=piece, order=[jig])
do("rename-piece", piece=piece, name="Jigs")
do("set-piece-metadata", piece=piece, composer="Trad.", tags="session,jig",
   arranger="Ali")
do("unassign-piece", score=jig)
do("assign-piece", score=jig, piece=piece)

# combining is the curation step that makes "every import mints a piece" safe:
# two pieces for one tune become one, and the arrangements come across.
spare = do("create-piece", name="Spare Reels")["slug"]
do("create-arrangement", name="Stray", piece=spare)
do("combine-pieces", pieces=[piece, spare])

setlist = do("create-setlist", name="Friday")["slug"]
do("assign-setlist", setlist=setlist, score=jig)
do("reorder-setlist", setlist=setlist, order=[jig])
do("rename-setlist", setlist=setlist, name="Saturday")
do("bind-setlist-share", setlist=setlist, shareId="share-1", ownerUid="uid-1")
do("share-payload", score=jig)
do("unassign-setlist", setlist=setlist, score=jig)
do("delete-setlist", setlist=setlist)

# -- bundles: the no-account, no-network hand-off ----------------------------
do("bundle-export", target=jig, out=BUNDLE)
do("bundle-inspect", path=BUNDLE)
do("bundle-import", path=BUNDLE, into_piece="Imported")

# -- scans, books, and the bulk path ----------------------------------------
scan = do("import-pdf", path=PDF, name="A Scan", piece="Scans")["score"]
book = do("import-book", path=PDF, name="Teh Rael Bok")["book"]
do("book-file", book=book)
do("rename-book", book=book, name="The Real Book")
do("book-extract", book=book, from_page=1, to_page=2, name="Misty", piece="Misty")
do("book-detect", book=book, ocr={"1": [{"text": "Misty", "top": 0.06, "height": 0.03}]})
do("book-contents", book=book, entries=[{"title": "Misty", "from": 1, "to": 2}])
do("book-split", book=book, entries=[{"title": "Nardis", "from": 2, "to": 2}])
do("delete-book", book=book)
do("bulk-import", folder=BULK, files=["Nature Boy/trio.musicxml"])

# -- the test-only shapes, and the tidying ops -------------------------------
do("debug-orphan-arrangement", slug="broken-arrangement", name="Morrison's jig")
do("debug-poison-title", score=jig, title="v001.mxl")
do("duplicate", score=jig, name="Bridge Jig copy")
do("create-arrangement", name="Blank", piece=piece)
do("rename-slug", score=scan, to="a-scan-renamed")
do("delete-score", score="a-scan-renamed")
do("restore-score", score="a-scan-renamed")
do("sweep")
do("delete-piece", piece="Misty", with_arrangements=True)
do("tidy-pieces")

# -- the account's library on every device (librarysync) ---------------------
do("library-sync-status")
do("library-sync-bind", account="u-coverage")
box = do("library-sync-outbox", limit=500)
do("library-sync-ack", acks=[a for r in box.get("records", []) for a in r["acks"]])
do("library-sync-apply", records=[])

print("RESULT" + json.dumps({"configured": configured, "steps": STEPS},
                            default=str))
'''


def write_fixtures(root: Path) -> dict[str, str]:
    """Everything the child needs to exist before it starts.

    Written here rather than in the child because `fixtures.py` lives in this
    repo's engine tree, which is exactly the path the child is denied.
    """
    from music21 import articulations, dynamics, expressions, harmony
    from pypdf import PdfWriter

    from scoranger_engine import ops

    jig = fixtures.jig(bars=8)
    bar = jig.parts[0].measure(1)
    bar.insert(0.0, dynamics.Dynamic("mf"))
    bar.insert(1.0, expressions.TextExpression("dolce"))
    # a chord SYMBOL is a Chord to music21 and sorts first at offset 0; a mark
    # hung there is on something that is not on the staff at all
    ops.set_chord_symbols(jig, "#0", [{"measure": 1, "symbol": "Em"}])
    note = next(n for n in bar.notes if not isinstance(n, harmony.Harmony))
    note.expressions.append(expressions.Fermata())
    note.articulations.append(articulations.Accent())

    paths = {}
    paths["JIG"] = str(root / "jig.musicxml")
    jig.write("musicxml", fp=paths["JIG"])
    # what OMR hands back: a transcription that becomes a new VERSION
    paths["OMR"] = str(root / "omr.musicxml")
    fixtures.jig(bars=8).write("musicxml", fp=paths["OMR"])
    paths["QUARTET"] = str(root / "quartet.musicxml")
    fixtures.quartet(bars=8).write("musicxml", fp=paths["QUARTET"])

    paths["PDF"] = str(root / "scan.pdf")
    writer = PdfWriter()
    for _ in range(4):
        writer.add_blank_page(width=612, height=792)
    with open(paths["PDF"], "wb") as f:
        writer.write(f)

    bulk = root / "bulk" / "Nature Boy"
    bulk.mkdir(parents=True)
    fixtures.jig(bars=4).write("musicxml", fp=str(bulk / "trio.musicxml"))
    paths["BULK"] = str(bulk.parent)
    paths["BUNDLE"] = str(root / "jig.scorbundle")
    return paths


def run_child(root: Path) -> dict:
    paths = write_fixtures(root)
    header = "\n".join(
        f"{name} = {value!r}" for name, value in
        ({"APP": str(APP), "PACKAGES": str(APP_PACKAGES),
          "WORKSPACE": str(root / "device-workspace")} | paths).items())
    program = header + "\n" + textwrap.dedent(CHILD)
    proc = subprocess.run([sys.executable, "-I", "-c", program],
                          capture_output=True, text=True)
    line = next((l for l in proc.stdout.splitlines() if l.startswith("RESULT")), None)
    if line is None:
        raise AssertionError(
            "the app's bridge never answered: "
            + (proc.stderr or proc.stdout).strip()[-800:])
    return json.loads(line[len("RESULT"):])


def main() -> int:
    if not APP_PACKAGES.exists():
        print(f"  FAIL {APP_PACKAGES} is missing -- run ios/scripts/vendor_engine.sh")
        return 1

    root = Path(tempfile.mkdtemp())
    answer = run_child(root)
    steps = answer["steps"]
    exercised = {s["op"] for s in steps}

    print("the app's bridge comes up on the sys.path it actually ships with")
    check(bool(answer["configured"].get("ok")),
          f"configure answered: {answer['configured'].get('error') or 'ok'}")
    check(bool(answer["configured"].get("music21")),
          f"music21 is vendored: {answer['configured'].get('music21')}")

    print(f"\nevery op it was asked for answered ({len(steps)} calls)")
    broken = [s for s in steps if not s["ok"]]
    for s in broken:
        check(False, f"'{s['op']}' failed: {str(s['error'])[:200]}")
    if not broken:
        check(True, "no op raised on the way through")

    print("\nthe ops this build added, asserted on their answers and not just "
          "on not raising")
    by_op: dict[str, list] = {}
    for s in steps:
        by_op.setdefault(s["op"], []).append(s["result"])

    renamed = (by_op.get("rename-book") or [{}])[0] or {}
    check(renamed.get("name") == "The Real Book",
          f"rename-book returned the new name: {renamed.get('name')}")
    check("slug" in renamed and renamed.get("slug") == "teh-rael-bok",
          f"and the slug it was created under: {renamed.get('slug')}")

    added = [(r or {}).get("details", {}) for r in by_op.get("add-element") or []]
    for kind in ("dynamic", "text", "fermata", "articulation"):
        check(any(d.get("kind") == kind and d.get("ordinal") is not None
                  for d in added),
              f"add-element routed --kind {kind} and said where it landed")
    check(all((r or {}).get("version") for r in by_op.get("add-element") or []),
          "'add-element' made a version, like every other mutation")

    kinds = [(r or {}).get("details", {}).get("kind")
             for r in by_op.get("adjust-element") or []]
    for kind in ("harm", "dynamic", "text", "fermata", "articulation"):
        check(kind in kinds, f"adjust-element routed --kind {kind}")
    scaled = [(r or {}).get("details", {}) for r in by_op.get("adjust-element") or []]
    check(any(d.get("scale") == 1.5 and d.get("size") == 18.0 for d in scaled),
          "the bridge passes `scale` through, so the app can drive size "
          "relatively: 1.5 arrived as 18.0pt of the 12.0 default")

    stripped = ((by_op.get("strip-notes") or [{}])[0] or {}).get("details", {})
    check((stripped.get("notes_removed") or 0) > 0
          and stripped.get("part") == "Acc. Bass",
          "strip-notes emptied the staff the app asked for: "
          f"{stripped.get('notes_removed')} notes off {stripped.get('part')}")
    check(bool(((by_op.get("strip-notes") or [{}])[0] or {}).get("new_version")),
          "'strip-notes' made a version, like every other mutation")

    moved = ((by_op.get("move-element") or [{}])[0] or {}).get("details", {})
    check(moved.get("op") == "move" and moved.get("to") == {"measure": 3, "offset": 1.5},
          f"move-element placed it at the tapped bar and offset: {moved.get('to')}")
    copied = ((by_op.get("duplicate-element") or [{}])[0] or {}).get("details", {})
    check(copied.get("op") == "duplicate" and copied.get("anchor") == "note",
          f"duplicate-element copied a note-attached mark: {copied.get('anchor')}")
    gone = ((by_op.get("remove-element") or [{}])[0] or {}).get("details", {})
    check(gone.get("op") == "remove" and gone.get("removed") == 1,
          f"remove-element took one mark off on device: {gone.get('removed')}")
    for op in ("move-element", "duplicate-element", "remove-element"):
        versions = [(r or {}).get("version") for r in by_op.get(op) or []]
        check(all(versions), f"'{op}' made a version, like every other mutation")

    print("\nthe ledger: every op is either called above or excused by name")
    known = bridge_ops()
    check(len(known) > 50, f"the bridge dispatches on {len(known)} ops")
    unaccounted = sorted(known - exercised - set(NOT_EXERCISED))
    for op in unaccounted:
        check(False, f"'{op}' is dispatched but never called and has no reason "
                     "in NOT_EXERCISED")
    if not unaccounted:
        check(True, f"all {len(known)} accounted for: {len(exercised & known)} "
                    f"called, {len(NOT_EXERCISED)} excused")
    stale = sorted(set(NOT_EXERCISED) - known)
    for op in stale:
        check(False, f"NOT_EXERCISED names '{op}', which the bridge no longer "
                     "dispatches -- drop it")
    if not stale:
        check(True, "and no excuse outlives the op it was written for")

    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILED")
        for f in FAILURES:
            print(f"  - {f}")
        return 1
    print("OK: every op the bridge answers was CALLED on the device's own "
          "sys.path -- the gap a string comparison of op names cannot see")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
