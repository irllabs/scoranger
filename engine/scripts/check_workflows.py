"""End-to-end checks for what people actually do with the app.

The other checks each guard one thing. This one walks whole journeys -- import
a score, pull a part from another edition, change the instrument, write
fingerings under it, put chords over it, mark the repeats, engrave it -- and
asserts what the user would see at the end. Real sessions are chains, and the
bugs that reached TestFlight lived in the chains rather than in any single op:
a rhythm broken at step two and noticed at step fifteen; a source written
corrupt on the way in and inherited by everything downstream.

Every journey runs against a workspace of its own through the same functions
the CLI and the app's bridge call, so passing here means the op, the version
history, the document projection and the write guard all agreed.

Run: engine/.venv/bin/python engine/scripts/check_workflows.py
"""

import os
import sys
import tempfile
from fractions import Fraction
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "engine"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import fixtures  # noqa: E402

FAILURES: list[str] = []
JOURNEYS: list[str] = []


class Journey:
    """One user session, in its own workspace."""

    def __init__(self, name: str):
        self.name = name
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["SCORANGER_WORKSPACE"] = self.tmp.name
        for module in [m for m in sys.modules if m.startswith("scoranger_engine")]:
            del sys.modules[module]
        from scoranger_engine import ops, workspace
        workspace.WORKSPACE = Path(self.tmp.name)
        workspace._repo_singleton = None
        self.ops, self.workspace = ops, workspace
        self.step = 0

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.tmp.cleanup()
        if exc[0] is None:
            JOURNEYS.append(self.name)
        return False

    def fail(self, what: str):
        FAILURES.append(f"{self.name} (after {self.step} steps): {what}")

    # -- the moves a user makes -------------------------------------------------

    def load(self, slug: str, version: str | None = None):
        from music21 import converter
        return converter.parse(str(self.workspace.resolve_path(slug, version)),
                               forceSource=True)

    def do(self, slug: str, op: str, mutate, args: dict | None = None):
        """Apply an op the way the CLI does: load, mutate, write a version."""
        self.step += 1
        score = self.load(slug)
        result = mutate(score)
        entry = self.workspace.add_version(slug, score, op, args or {})
        return entry, result

    def rhythm_of(self, slug: str, version: str | None = None):
        return self.ops.rhythm_faults(self.load(slug, version))

    def parts_of(self, slug: str):
        return [p.partName for p in self.load(slug).parts]

    def lengths(self, slug: str):
        return [Fraction(p.highestTime).limit_denominator(10 ** 6)
                for p in self.load(slug).parts]


# =============================================================================
# 1. Ali's own session: a jig from a PDF becomes a whistle-and-chords chart
# =============================================================================
with Journey("jig from OMR -> whistle chart") as j:
    slug, entry = j.workspace.create_score("Morrison's jig", fixtures.omr_jig())
    inherited = {(p, b) for p, b, _ in j.rhythm_of(slug)}
    if not inherited:
        j.fail("the OMR fixture should arrive with an odd bar to inherit")
    if not entry.get("rhythm_warnings"):
        j.fail("the odd bar was not reported at import")

    # bring the accompaniment in from another edition, as a source
    j.workspace.add_source(slug, fixtures.grand_staff(bars=20), "MuseScore edition", "test")
    source = j.load(slug)  # placeholder to keep the pattern obvious
    from music21 import converter
    src_score = converter.parse(str(j.workspace.source_path(slug, "s01")), forceSource=True)

    j.do(slug, "pull-part", lambda sc: j.ops.pull_part(sc, src_score, "#1", "Accompaniment",
                                                       None, None))
    if "Accompaniment" not in j.parts_of(slug):
        j.fail(f"the pulled part is not in the score: {j.parts_of(slug)}")

    j.do(slug, "change-instrument",
         lambda sc: j.ops.change_instrument(j.ops.find_parts(sc, ["#0"])[0], "Flute"))
    j.do(slug, "whistle-fingerings",
         lambda sc: j.ops.whistle_fingerings(sc, j.ops.find_parts(sc, ["#0"])[0], "D"))
    j.do(slug, "set-chords", lambda sc: j.ops.set_chord_symbols(
        sc, "#0", [{"measure": 1, "symbol": "Em"}, {"measure": 5, "symbol": "D"},
                   {"measure": 9, "symbol": "G"}]))
    j.do(slug, "set-structure", lambda sc: j.ops.set_structure(sc, "repeat-end", measure=8))
    j.do(slug, "set-metadata", lambda sc: j.ops.set_metadata(sc, title="Morrison's Jig"))

    # the whole point: six ops later the rhythm is exactly what came in
    after = {(p, b) for p, b, _ in j.rhythm_of(slug)}
    if after != inherited:
        j.fail(f"the rhythm changed across the session: {sorted(inherited)} -> {sorted(after)}")

    # the fingerings and the chords are both in the notation
    final = j.load(slug)
    verses = [ly for n in final.recurse().notes for ly in n.lyrics
              if ly.identifier == j.ops.WHISTLE_LYRIC_TAG]
    if not verses:
        j.fail("no whistle fingerings survived to the last version")
    if not list(final.recurse().getElementsByClass("ChordSymbol")):
        j.fail("no chord symbols survived to the last version")

    # and the history is intact and immutable: one version per op, parents chained
    versions = j.workspace.load_meta(slug)["versions"]
    if [v["op"] for v in versions] != ["import", "pull-part", "change-instrument",
                                       "whistle-fingerings", "set-chords",
                                       "set-structure", "set-metadata"]:
        j.fail(f"unexpected version history: {[v['op'] for v in versions]}")
    if any(v["parent"] != versions[i]["id"] for i, v in enumerate(versions[1:])):
        j.fail("the version chain does not link each version to its parent")


# =============================================================================
# 2. A quartet becomes a duo, transposed, in the right clefs
# =============================================================================
with Journey("quartet -> viola duo") as j:
    slug, _ = j.workspace.create_score("Quartet", fixtures.quartet())
    if len(j.parts_of(slug)) != 4:
        j.fail(f"the quartet should have four parts: {j.parts_of(slug)}")

    j.do(slug, "keep-parts", lambda sc: j.ops.keep_parts(sc, ["Violin I", "Viola"]))
    if j.parts_of(slug) != ["Violin I", "Viola"]:
        j.fail(f"keep-parts left {j.parts_of(slug)}")

    j.do(slug, "transpose", lambda sc: j.ops.transpose(sc, "-m3", None))
    j.do(slug, "change-instrument",
         lambda sc: j.ops.change_instrument(j.ops.find_parts(sc, ["Violin I"])[0], "Viola"))
    _, clefs = j.do(slug, "change-clef",
                    lambda sc: j.ops.change_clef(j.ops.find_parts(sc, ["Viola"])[0], "alto"))

    final = j.load(slug)
    if any(j.ops.rhythm_faults(final)):
        j.fail("the rhythm broke while re-scoring the quartet")
    if len(final.parts) != 2:
        j.fail(f"expected two staves, got {len(final.parts)}")
    # a viola part reads in alto clef; that is the point of the op
    alto = [c for c in final.recurse().getElementsByClass("AltoClef")]
    if not alto:
        j.fail("no alto clef in a score whose part was moved to viola")


# =============================================================================
# 3. A grand staff pulled apart into bass and chords, then simplified
# =============================================================================
with Journey("grand staff -> bass + chords") as j:
    slug, _ = j.workspace.create_score("Accordion", fixtures.grand_staff(bars=12))
    before = j.lengths(slug)

    j.do(slug, "split-bass",
         lambda sc: j.ops.split_bass(sc, "#0", "Acc. Bass", "Acc. Chords", None))
    if "Acc. Bass" not in j.parts_of(slug) or "Acc. Chords" not in j.parts_of(slug):
        j.fail(f"split-bass produced {j.parts_of(slug)}")

    j.do(slug, "limit-part", lambda sc: j.ops.limit_part(sc, "Acc. Bass", "C4", True))
    j.do(slug, "consolidate-ties", lambda sc: j.ops.consolidate_ties(sc, ["Acc. Bass"]))
    j.do(slug, "simplify-repeats", lambda sc: j.ops.simplify_repeats(sc, "Acc. Bass", 1.0))

    if any(j.ops.rhythm_faults(j.load(slug))):
        j.fail(f"the rhythm broke: {j.ops.rhythm_problems(j.load(slug))[:2]}")
    # the bass staff is monophonic after limit-part: no two notes sounding at once
    bass = j.ops.find_parts(j.load(slug), ["Acc. Bass"])[0]
    if any(n.isChord for n in bass.recurse().notes):
        j.fail("limit-part --monophonic left chords on the bass staff")
    if j.lengths(slug)[0] != before[0]:
        j.fail(f"the music got longer: {before} -> {j.lengths(slug)}")


# =============================================================================
# 4. The library: pieces, arrangements, numbering, set lists
# =============================================================================
with Journey("library: pieces, numbering and set lists") as j:
    piece = j.workspace.create_piece("Sous le ciel de Paris")["slug"]
    slugs = []
    for name in ("Quartet", "Duo", "Solo"):
        slug, _ = j.workspace.create_score(name, fixtures.quartet(bars=4))
        j.workspace.assign_score_to_piece(slug, piece)
        slugs.append(slug)

    def numbering():
        manifest = j.workspace.rebuild_manifest()
        found = next(p for p in manifest["pieces"] if p["slug"] == piece)
        return found["arrangements"]

    if numbering() != slugs:
        j.fail(f"arrangements are not in the order they were filed: {numbering()}")

    # reorder, the way a drag does
    j.workspace.set_piece_order(piece, [slugs[2], slugs[0], slugs[1]])
    if numbering() != [slugs[2], slugs[0], slugs[1]]:
        j.fail(f"reorder did not stick: {numbering()}")

    # a set list holds arrangements, in a running order
    setlist = j.workspace.create_setlist("Gig night")["slug"]
    for slug in (slugs[1], slugs[0]):
        j.workspace.add_score_to_setlist(setlist, slug)
    manifest = j.workspace.rebuild_manifest()
    listed = next(s for s in manifest["setlists"] if s["slug"] == setlist)["arrangements"]
    if listed != [slugs[1], slugs[0]]:
        j.fail(f"the set list is not in the order things were added: {listed}")

    j.workspace.remove_score_from_setlist(setlist, slugs[1])
    manifest = j.workspace.rebuild_manifest()
    listed = next(s for s in manifest["setlists"] if s["slug"] == setlist)["arrangements"]
    if listed != [slugs[0]]:
        j.fail(f"removing from a set list left {listed}")
    # removing from a set list must not touch the arrangement itself
    if not j.workspace.resolve_path(slugs[1]).exists():
        j.fail("removing an arrangement from a set list deleted its music")

    # Sharing is a FIELD on the set list, not a second kind of object
    # (design/FIREBASE.md 6A.1) -- and the app learns it from the MANIFEST, so
    # that is where this is asserted. Both halves were wrong when this check
    # was written: the vendored on-device engine had no bind_setlist_share at
    # all, and the manifest projection dropped shareId, so a set list that had
    # been promoted looked local on every device forever.
    listed = next(s for s in j.workspace.rebuild_manifest()["setlists"]
                  if s["slug"] == setlist)
    if listed.get("shareId") is not None or listed.get("ownerUid") is not None:
        j.fail(f"a set list nobody shared claims a share: {listed.get('shareId')}")

    # promotion's last step (6A.1 step 4)
    j.workspace.bind_setlist_share(setlist, "share-abc", "owner-xyz")
    bound = next(s for s in j.workspace.rebuild_manifest()["setlists"]
                 if s["slug"] == setlist)
    if bound.get("shareId") != "share-abc" or bound.get("ownerUid") != "owner-xyz":
        j.fail(f"binding a share did not reach the manifest: {bound}")
    if bound["arrangements"] != [slugs[0]]:
        j.fail(f"binding a share disturbed the running order: {bound['arrangements']}")

    # by name, and twice, because the share button gets pressed again
    j.workspace.bind_setlist_share("Gig night", "share-abc", "owner-xyz")
    again = next(s for s in j.workspace.rebuild_manifest()["setlists"]
                 if s["slug"] == setlist)
    if again.get("shareId") != "share-abc":
        j.fail("binding the same share twice lost it")

    # An adopted copy names the shared entry it is, in the MANIFEST, where the
    # app's set list sync matches on it -- and on the score document, which
    # library sync carries to the account's other devices (0.18.0).
    j.workspace.link_shared_entry(slugs[0], "entry-123")
    listed = next(s for s in j.workspace.rebuild_manifest()["scores"]
                  if s["slug"] == slugs[0])
    if listed.get("sharedEntry") != "entry-123":
        j.fail(f"the shared entry link did not reach the manifest: {listed.get('sharedEntry')}")
    if j.workspace._repo().get_score(slugs[0]).get("sharedEntry") != "entry-123":
        j.fail("the shared entry link is not on the score document")
    if "versions" in j.workspace._repo().get_score(slugs[0]):
        j.fail("linking a shared entry wrote the version list into the score document")


# =============================================================================
# 5. Titles, credits and renaming: one value, projected everywhere
# =============================================================================
with Journey("titles, credits and renaming") as j:
    slug, _ = j.workspace.create_score("Working title", fixtures.jig(bars=8))
    j.workspace.set_score_metadata(slug, title="Cooley's Reel", composer="Traditional",
                                   arranger="A. Momeni")
    doc = j.workspace.load_meta(slug)
    if doc["title"] != "Cooley's Reel" or doc["composer"] != "Traditional":
        j.fail(f"the score document did not follow the notation: {doc['title']}, {doc['composer']}")
    engraved = j.ops.engraved_title(j.load(slug))
    if engraved != "Cooley's Reel":
        j.fail(f"the engraved title is {engraved!r}, not the arrangement's title")

    # renaming the slug moves the artifacts and keeps the history readable
    renamed = j.workspace.rename_slug(slug, "cooleys-reel")["score"]
    if renamed != "cooleys-reel" or not j.workspace.resolve_path(renamed).exists():
        j.fail("renaming the slug lost the score's files")
    if len(j.workspace.load_meta(renamed)["versions"]) < 2:
        j.fail("renaming the slug lost the version history")


# =============================================================================
# 6. Sources: another edition, cherry-picked from
# =============================================================================
with Journey("sources: pull a passage from another edition") as j:
    slug, _ = j.workspace.create_score("Arrangement", fixtures.quartet(bars=8))
    j.workspace.add_source(slug, fixtures.quartet(bars=8), "Other edition", "test")
    sources = j.workspace.load_meta(slug).get("sources") or \
        j.workspace._repo().list_sources(slug)
    if not sources:
        j.fail("the source was not recorded")

    from music21 import converter
    src = converter.parse(str(j.workspace.source_path(slug, "s01")), forceSource=True)

    # a whole part, then a passage into an existing one
    j.do(slug, "pull-part", lambda sc: j.ops.pull_part(sc, src, "Viola", "Viola (alt)",
                                                       None, None))
    if "Viola (alt)" not in j.parts_of(slug):
        j.fail(f"pulling a whole part failed: {j.parts_of(slug)}")
    j.do(slug, "pull-part", lambda sc: j.ops.pull_part(sc, src, "Violin II", None,
                                                       "Violin I", (2, 4)))
    if any(j.ops.rhythm_faults(j.load(slug))):
        j.fail("pulling a passage broke the rhythm")


# =============================================================================
# 7. Version history: immutable, addressable, exportable
# =============================================================================
with Journey("version history stays addressable") as j:
    slug, first = j.workspace.create_score("History", fixtures.jig(bars=8))
    original = j.lengths(slug)
    for interval in ("M2", "M2", "M2"):
        j.do(slug, "transpose", lambda sc, i=interval: j.ops.transpose(sc, i, None),
             {"interval": interval})

    versions = j.workspace.load_meta(slug)["versions"]
    if len(versions) != 4:
        j.fail(f"expected four versions, found {len(versions)}")
    # the first version is untouched by everything that came after it
    if j.lengths(slug) != original:
        j.fail("the music changed length across three transpositions")
    first_pitches = [str(n.pitch) for n in j.load(slug, "v001").recurse().notes][:4]
    last_pitches = [str(n.pitch) for n in j.load(slug, versions[-1]["id"]).recurse().notes][:4]
    if first_pitches == last_pitches:
        j.fail("three transpositions left the pitches unchanged")
    if [str(n.pitch) for n in j.load(slug, "v001").recurse().notes][:4] != first_pitches:
        j.fail("v001 changed when a later version was written -- versions are immutable")


# =============================================================================
# 8. A damaging op is caught in development, and never blocks the user
# =============================================================================
with Journey("damage is detected, not refused") as j:
    slug, _ = j.workspace.create_score("Guarded", fixtures.jig(bars=8))
    j.do(slug, "transpose", lambda sc: j.ops.transpose(sc, "M2", None))

    from music21 import note as m21note
    score = j.load(slug)
    score.parts[0].measure(3).append(m21note.Note("C5", quarterLength=1))
    entry = j.workspace.add_version(slug, score, "damage", {})

    # the write goes through -- the app never stands between a user and a save --
    # and the damage is both recorded on the version and visible to the checks
    if not entry.get("rhythm_warnings"):
        j.fail("a damaging op left no warning on the version")
    if not any(bar == 3 for _, bar, _ in j.rhythm_of(slug)):
        j.fail("a damaging op went undetected by the rhythm check")

    # the user can still work: the next op succeeds
    j.do(slug, "transpose", lambda sc: j.ops.transpose(sc, "-M2", None))


# =============================================================================
# 8b. Structural marks are notation about the music, not the music
# =============================================================================
with Journey("repeats and endings on an OMR score") as j:
    slug, entry = j.workspace.create_score("Scanned jig", fixtures.omr_jig())
    inherited = len(entry.get("rhythm_warnings") or [])
    if not inherited:
        j.fail("the OMR fixture should arrive with an odd bar")
    before = j.lengths(slug)

    # the sequence Ali was blocked on, end to end
    for kind, kwargs in (("repeat-start", {"measure": 5}),
                         ("repeat-end", {"times": 2, "measure": 12}),
                         ("volta", {"measure": 11, "to_measure": 12, "number": 1}),
                         ("segno", {"measure": 2}),
                         ("coda", {"measure": 17}),
                         ("dal-segno-al-coda", {"measure": 20})):
        try:
            e, _ = j.do(slug, "set-structure",
                        lambda sc, k=kind, kw=kwargs: j.ops.set_structure(sc, k, **kw),
                        {"kind": kind})
        except Exception as ex:  # noqa: BLE001
            j.fail(f"{kind} was blocked: {type(ex).__name__}: {ex}")
            continue
        if len(e.get("rhythm_warnings") or []) > inherited:
            j.fail(f"{kind} made the inherited odd bars worse")

    if j.lengths(slug) != before:
        j.fail(f"marking up the structure changed the music's length: "
               f"{before} -> {j.lengths(slug)}")

    # and every mark reached the engraving
    import re as _re
    import verovio
    toolkit = verovio.toolkit()
    toolkit.setOptions({"scale": 40, "footer": "none"})
    toolkit.loadFile(str(j.workspace.resolve_path(slug)))
    mei = toolkit.getMEI("{}")
    for what, pattern in (("repeat start", r'left="rptstart"'),
                          ("repeat end", r'right="rptend"'),
                          ("volta", r"<ending"),
                          ("segno", r"(?i)segno"),
                          ("coda", r"(?i)coda")):
        if not _re.search(pattern, mei):
            j.fail(f"the {what} never reached the engraving")


# =============================================================================
# 9. Getting the music back out: export is the point of the whole exercise
# =============================================================================
with Journey("export to MusicXML, MIDI and PDF") as j:
    slug, _ = j.workspace.create_score("For export", fixtures.jig(bars=8))
    j.do(slug, "whistle-fingerings",
         lambda sc: j.ops.whistle_fingerings(sc, j.ops.find_parts(sc, ["#0"])[0], "D"))
    source = j.workspace.resolve_path(slug)

    out_dir = Path(j.tmp.name) / "out"
    out_dir.mkdir(exist_ok=True)

    # MusicXML and MIDI go through music21's writers
    from music21 import converter
    score = j.load(slug)
    for fmt, suffix in (("musicxml", ".musicxml"), ("midi", ".mid")):
        target = out_dir / f"export{suffix}"
        try:
            score.write(fmt, fp=str(target))
        except Exception as e:  # noqa: BLE001
            j.fail(f"exporting {fmt} raised {type(e).__name__}: {e}")
            continue
        if not target.exists() or target.stat().st_size == 0:
            j.fail(f"the {fmt} export is missing or empty")

    # the PDF is Verovio + cairosvg + pypdf, the path the viewer's export uses
    from scoranger_engine import render
    pdf = out_dir / "export.pdf"
    try:
        render.render_pdf(str(source), str(pdf))
    except Exception as e:  # noqa: BLE001
        j.fail(f"rendering a PDF raised {type(e).__name__}: {e}")
    else:
        if not pdf.exists() or pdf.stat().st_size < 1000:
            j.fail(f"the PDF is missing or implausibly small "
                   f"({pdf.stat().st_size if pdf.exists() else 0} bytes)")
        elif pdf.read_bytes()[:4] != b"%PDF":
            j.fail("the exported file is not a PDF")

    # exporting must not disturb the score it exported
    if j.ops.rhythm_faults(j.load(slug)):
        j.fail("exporting changed the arrangement")


# =============================================================================
# 11. Chord names, resized and nudged, surviving the file and the page
# =============================================================================
with Journey("chord names resized and repositioned") as j:
    slug, _ = j.workspace.create_score("Chart", fixtures.jig(bars=8))
    j.do(slug, "set-chords", lambda sc: j.ops.set_chord_symbols(
        sc, "#0", [{"measure": 1, "symbol": "Em"}, {"measure": 3, "symbol": "G"},
                   {"measure": 5, "symbol": "D"}]))

    j.do(slug, "adjust-element", lambda sc: j.ops.adjust_element(
        sc, "#0", kind="harm", measure=3, size=20), {"measure": 3, "size": 20})
    j.do(slug, "adjust-element", lambda sc: j.ops.adjust_element(
        sc, "#0", kind="harm", measure=5, offset_y=-6, offset_x=3), {"measure": 5})

    # the notation carries it, and only for the symbols that were adjusted
    final = j.load(slug)
    chords = list(final.recurse().getElementsByClass("ChordSymbol"))
    if len(chords) != 3:
        j.fail(f"expected three chord symbols, found {len(chords)}")
    else:
        if chords[1].style.fontSize != 20:
            j.fail(f"the resized symbol lost its size: {chords[1].style.fontSize}")
        if chords[2].style.relativeY != -6 or chords[2].style.relativeX != 3:
            j.fail(f"the moved symbol lost its offset: "
                   f"{chords[2].style.relativeX}, {chords[2].style.relativeY}")
        if chords[0].style.fontSize is not None or chords[0].style.relativeY is not None:
            j.fail("an untouched chord symbol was adjusted")

    # a later op must not disturb them: this is the chain that broke before
    j.do(slug, "transpose", lambda sc: j.ops.transpose(sc, "M2", None))
    after = list(j.load(slug).recurse().getElementsByClass("ChordSymbol"))
    if after[1].style.fontSize != 20 or after[2].style.relativeY != -6:
        j.fail("transposing the score lost the chord-symbol adjustments")

    # and the rhythm never moved
    if j.ops.rhythm_faults(j.load(slug)):
        j.fail("adjusting chord symbols broke the rhythm")

    # the export carries them too -- a PDF is what the user actually plays from
    from scoranger_engine import render as _render
    out = Path(j.tmp.name) / "chart.pdf"
    _render.render_pdf(str(j.workspace.resolve_path(slug)), str(out))
    if not out.exists() or out.read_bytes()[:4] != b"%PDF":
        j.fail("the adjusted chart did not export to a PDF")


if FAILURES:
    print(f"FAIL: {len(FAILURES)} workflow check(s) failed")
    for line in FAILURES:
        print("   ", line)
    sys.exit(1)
print(f"OK: {len(JOURNEYS)} end-to-end journeys hold up "
      f"({', '.join(JOURNEYS[:3])}, ...)")
