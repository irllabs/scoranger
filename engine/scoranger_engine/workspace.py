"""Versioned score library.

Source of truth: a local document database (db.SqliteRepository).
Artifacts:       workspace/<slug>/<version-id>.musicxml (or .pdf)
Serving layer:   workspace/manifest.json, a denormalized projection of the DB
                 that the app and the viewer poll.

Every mutation appends an immutable version document carrying the operation
that produced it and a snapshot of the resulting parts.

Two names per thing, and they do different jobs:

  slug   the local handle. The directory on disk, what the CLI takes, what
         chat means by `arr:<slug>`. Derived from the title, so it MOVES when
         the title does (`rename_slug`), and it is local to this device.
  uid    the identity. Opaque, assigned once, never rewritten, unique without
         coordination. What a share points at and what sync mirrors.

A version has no slug: its key IS its opaque id, and `label` (`v012`) is the
name a person reads. See `ids.py` and design/FIREBASE.md §3.
"""

import json
import os
import re
import tempfile
import uuid
from collections.abc import Callable
from datetime import datetime
from pathlib import Path

from . import ids
from .db import Repository, SqliteRepository

REPO_ROOT = Path(__file__).resolve().parents[2]
WORKSPACE = Path(os.environ.get("SCORANGER_WORKSPACE", REPO_ROOT / "workspace"))

_repo_singleton: Repository | None = None

#: How a repository gets built, given the database path. The sync layer
#: replaces this with a factory returning a decorator that wraps
#: SqliteRepository and journals every write; nothing else in the engine has to
#: know. Set it before the first call to `_repo()`.
repository_factory: Callable[[Path], Repository] = SqliteRepository

# The chat turn in progress, if any: versions created while it's open are
# stamped with it so the UI can group one prompt's operations together.
_current_turn: dict | None = None


def begin_turn(slug: str, prompt: str) -> dict:
    """Open a chat turn: subsequent versions of `slug` carry a shared turn id."""
    global _current_turn
    _current_turn = {"id": uuid.uuid4().hex[:8], "prompt": prompt[:200], "slug": slug}
    return {"turn": _current_turn["id"]}


def end_turn() -> dict:
    """Close the current chat turn (safe to call when none is open)."""
    global _current_turn
    _current_turn = None
    return {"ended": True}


def _now() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def _repo() -> Repository:
    global _repo_singleton
    if _repo_singleton is None:
        WORKSPACE.mkdir(parents=True, exist_ok=True)
        _repo_singleton = repository_factory(WORKSPACE / "scoranger.db")
        if _repo_singleton.count_scores() == 0:
            _migrate_legacy(_repo_singleton)
        _migrate_ids(_repo_singleton)
    return _repo_singleton


def _reset_repo_for_testing() -> None:
    """Drop the cached repository so a test can point WORKSPACE somewhere else."""
    global _repo_singleton
    _repo_singleton = None


def _migrate_legacy(repo: SqliteRepository) -> None:
    """One-time import of the old meta.json filesystem layout into the DB."""
    for d in sorted(WORKSPACE.iterdir()):
        meta_path = d / "meta.json"
        if not meta_path.is_file():
            continue
        meta = json.loads(meta_path.read_text())
        slug = meta["slug"]
        versions = meta.get("versions", [])
        for i, v in enumerate(versions):
            doc = {"id": v["id"], "seq": i + 1, "file": v["file"], "op": v["op"],
                   "args": v.get("args", {}), "parent": v.get("parent"),
                   "time": v.get("time"), "parts": None}
            if i == len(versions) - 1:
                doc["parts"] = _parts_snapshot(d / v["file"])
            repo.add_version(slug, v["id"], i + 1, doc)
        repo.set_score(slug, {
            "id": slug, "slug": slug, "name": meta["name"],
            "title": meta.get("name"), "composer": None,
            "created": meta.get("created"), "latest": versions[-1]["id"] if versions else None,
        })
        meta_path.rename(d / "meta.legacy.json")


def _migrate_ids(repo: Repository) -> None:
    """Give every document a stable identifier, once, in place.

    What changes: a score, piece, setlist, book and source gains `uid`, and a
    version's KEY becomes an opaque id with its old `vNNN` kept as `label`.
    Why: design/FIREBASE.md §3. Both old keys were derived from something that
    moves -- the title, or the number of siblings -- so neither could survive a
    rename or two devices allocating at once.

    What deliberately does NOT change: **the filesystem**. A version document
    already carries its artifact's name in `file`, independently of its id, so
    every existing `v001.musicxml` keeps its name and stays exactly where it
    is. A migration of 44 arrangements that renames nothing cannot half-rename
    anything, and the worst case if it is interrupted is that it runs again.

    Idempotent, and cheap once done: an arrangement that is already migrated is
    skipped without its versions being read at all, so `_repo()` can call this
    on every launch.
    """
    # The library itself, before any account exists. Signing in later writes an
    # owner onto this document rather than migrating anything, because the
    # library already had an identity (design/FIREBASE.md §9.2). Assigned here
    # and never rewritten -- a second call finds it and leaves it alone.
    if not (repo.get_library() or {}).get("uid"):
        library = dict(repo.get_library() or {})
        library["uid"] = ids.new_id()
        library.setdefault("created", _now())
        repo.set_library(library)

    for score in repo.list_scores(include_deleted=True):
        slug = score["slug"]
        # Two conditions, and the second one is not redundant.
        #
        # The uid is written LAST, after this score's versions are done, so its
        # presence means the arrangement was migrated. That is what keeps
        # launch cheap: a migrated library costs one score row per arrangement
        # here, not every version's parts snapshot deserialized from JSON.
        # Interrupted halfway, the score has no uid and the next run redoes it,
        # skipping the versions that already have ids.
        #
        # `latest` is checked too because a DOWNGRADE can put a `vNNN` version
        # into an already-migrated arrangement: roll the build back, run an op,
        # and the old engine appends a version keyed by counting. The uid alone
        # would skip that score for ever, leaving one version that can never
        # sync safely -- and if the old build wrote a second one it would
        # compute the same `vNNN` and overwrite the first. Any version an old
        # engine writes becomes `latest`, so this catches it, and it costs a
        # field we are already holding.
        if score.get("uid") and (score.get("latest") is None
                                 or ids.is_id(score.get("latest"))):
            continue
        versions = repo.list_versions(slug)
        needs_versions = any(not ids.is_id(v.get("id")) for v in versions)

        remap: dict[str, str] = {}
        if needs_versions:
            for seq, v in enumerate(versions, start=1):
                old = v.get("id")
                if ids.is_id(old):
                    continue
                v = dict(v)
                v["id"] = ids.new_id()
                v["seq"] = v.get("seq") or seq
                # the old key becomes the label, so a version that has always
                # been called v007 in the history, in the CLI and in the app
                # is still called v007 afterwards
                v["label"] = old or f"v{v['seq']:03d}"
                remap[old] = v["id"]
                repo.delete_version(slug, old)
                repo.add_version(slug, v["id"], v["seq"], v)

            # parents second: a child may be migrated before its parent, so the
            # remap has to be complete before any pointer is rewritten
            for v in repo.list_versions(slug):
                parent = v.get("parent")
                if parent in remap:
                    v = dict(v)
                    v["parent"] = remap[parent]
                    repo.add_version(slug, v["id"], v["seq"], v)
                elif parent is not None and not ids.is_id(parent):
                    # points at a version that no longer exists: a broken link
                    # is worse than no link, and the chain is display only
                    v = dict(v)
                    v["parent"] = None
                    repo.add_version(slug, v["id"], v["seq"], v)

        score = dict(score)
        score.setdefault("uid", ids.new_id())
        if score.get("latest") in remap:
            score["latest"] = remap[score["latest"]]
        repo.set_score(slug, score)

        for src in repo.list_sources(slug):
            if not src.get("uid"):
                src = dict(src)
                src["uid"] = ids.new_id()
                repo.add_source(slug, src["id"], src)

    for listing, setter in ((repo.list_pieces, repo.set_piece),
                            (repo.list_setlists, repo.set_setlist),
                            (repo.list_books, repo.set_book)):
        for doc in listing():
            if not doc.get("uid"):
                doc = dict(doc)
                doc["uid"] = ids.new_id()
                setter(doc["slug"], doc)


def _parts_snapshot(path_or_score) -> list | None:
    from music21 import converter, stream

    from . import ops
    try:
        if isinstance(path_or_score, (str, Path)):
            m21_score = converter.parse(str(path_or_score), forceSource=True)
        else:
            m21_score = path_or_score
        return ops.info(m21_score)["parts"]
    except Exception:
        return None


def slugify(name: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    return slug or "score"


def score_dir(slug: str) -> Path:
    return WORKSPACE / slug


def load_meta(slug: str) -> dict:
    """Score document + its version documents (kept for CLI compatibility)."""
    repo = _repo()
    doc = repo.get_score(slug)
    if doc is None:
        available = [s["slug"] for s in repo.list_scores()]
        raise FileNotFoundError(f"No score '{slug}'. Available: {available}")
    doc = dict(doc)
    doc["versions"] = repo.list_versions(slug)
    return doc


#: What a MODEL is told about a version, and the whole of it.
#:
#: A version document carries more than this: `file` (the artifact's filename),
#: `uid`, `parent`, `time`, a full `parts` snapshot, `rhythm_warnings`, and
#: `turn`, whose `prompt` is the FIRST 200 CHARACTERS OF AN EARLIER USER
#: PROMPT. The desktop agent had always projected the document down to these
#: three; the iOS bridge returned `load_meta` whole, so the same tool call sent
#: a model provider a transcript of what the user had asked for earlier in the
#: day, along with the filenames of their scores. The two paths disagreed, and
#: the iOS one was the wider.
#:
#: They now share this list rather than each keeping their own copy, because
#: two copies is how they came to disagree.
#:
#: `op` and `args` are what the history is FOR -- the model reasons about what
#: was done to the score, and args are op arguments (part names, intervals,
#: measure numbers), not prose. `id` is what addresses a version in a
#: subsequent call.
VERSION_FIELDS = ("id", "op", "args")

#: And of a source. `parts` is what a pull_part decision is made on; `name` is
#: what a person called the edition. `file`, `origin` and `uid` are a filename,
#: a device path and an identifier -- nothing a model can act on.
SOURCE_FIELDS = ("id", "name", "parts")


def version_history(slug: str) -> dict:
    """The score's history and its sources, as the list_versions tool sees it.

    THE ONE implementation. `chat.list_versions` (desktop) and `bridge.py`'s
    `versions` op (iOS) both call this, so the two surfaces cannot drift into
    sending different amounts of a user's data to the same model provider
    again.

    Not the same thing as `load_meta`, which is the FULL documents and is what
    the CLI, the manifest and the app's own UI read. Everything dropped here is
    dropped because it goes to a third party, not because it is unimportant.
    """
    meta = load_meta(slug)
    return {
        "versions": [{k: v[k] for k in VERSION_FIELDS if k in v}
                     for v in meta["versions"]],
        "sources": [{k: src[k] for k in SOURCE_FIELDS if k in src}
                    for src in _repo().list_sources(slug)],
    }


def version_label(v: dict) -> str:
    """What a person calls this version. `v012`, derived, never its identity.

    Held on the document rather than recomputed from `seq` so that a version
    that has always been called v007 keeps that name after the id migration,
    and keeps it if its siblings are ever renumbered.
    """
    return v.get("label") or f"v{v.get('seq') or 0:03d}"


def resolve_version(slug: str, ref: str | None = None) -> dict:
    """The version document named by `ref`: an id, a `vNNN` label, or latest.

    Both forms are accepted on purpose. The id is the identity and is what the
    app and the manifest pass around; the label is what a person types and what
    `CLAUDE.md` documents (`--version v012`), so the CLI and chat keep working
    unchanged. `ids.is_id` is not consulted: an exact id match is tried first
    and the label second, so a label that somehow looked like an id would still
    resolve to the right document.
    """
    versions = _repo().list_versions(slug)
    if not versions:
        raise FileNotFoundError(f"Score '{slug}' has no versions")
    if ref is None:
        return versions[-1]
    for v in versions:
        if v["id"] == ref:
            return v
    want = str(ref).lower()
    for v in versions:
        if version_label(v).lower() == want:
            return v
    have = [version_label(v) for v in versions]
    raise FileNotFoundError(f"No version '{ref}' of '{slug}'. Have: {have}")


def version_path(slug: str, version_id: str) -> Path:
    return score_dir(slug) / resolve_version(slug, version_id)["file"]


def latest_version(slug: str) -> dict:
    load_meta(slug)  # raises with available slugs when the score is missing
    return resolve_version(slug)


def resolve_path(slug: str, version_id: str | None = None) -> Path:
    return score_dir(slug) / resolve_version(slug, version_id)["file"]


# music21 writes itself in as the composer on every export when the score has
# none, and there is no way to suppress it from the metadata object -- so it is
# removed from the file after the write. Left in, it shows up as the composer of
# every arrangement the moment any op runs.
_M21_COMPOSER_STAMP = re.compile(
    r'[ \t]*<creator type="composer">Music21</creator>\r?\n?')


class NotNotationError(Exception):
    """Notation was asked of an arrangement whose artifact is not notation."""


#: ABC: the text notation Irish traditional music is published in, and what
#: thesession.org hands you when you download a tune. One file can hold SEVERAL
#: tunes, each opened by its own `X:` header -- see `read_notation`, which is
#: why nothing may call `converter.parse` on an import path directly any more.
ABC_SUFFIXES = {".abc"}

#: Artifact suffixes the engine can actually operate on. Everything else is
#: something a reader can look at but no op can touch.
NOTATION_SUFFIXES = {".musicxml", ".xml", ".mxl", ".mid", ".midi"} | ABC_SUFFIXES

#: Pictures of music. The SAME kind of thing as a PDF -- readable,
#: annotatable, OMR-able, editable by nothing until OMR has read it -- so they
#: take the PDF's path rather than a parallel one.
#:
#: HEIC is here because an iPhone photograph of a page is one, and a reader
#: who photographs a chart should not have to convert it first. Nothing in
#: this module decodes any of them: the artifact is stored as it arrived and
#: the DEVICE turns it into something to look at (see ScanImage on the Swift
#: side), which is why no image library is a dependency of the engine.
IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png", ".heic"}

#: Everything that is a scan rather than notation.
SCAN_SUFFIXES = {".pdf"} | IMAGE_SUFFIXES


def read_notation(path) -> list:
    """Every piece of music a notation file holds, in the order it holds them.

    A MusicXML or MIDI file is one score, so this is a list of one and every
    caller that used to say `converter.parse` reads the same thing. ABC is not:
    one `.abc` file may open several tunes, each with its own `X:` header, and
    music21 hands back an **Opus** for those -- a container with no `.parts`,
    on which anything written for a Score raises `AttributeError`. That is the
    whole reason this function exists rather than a suffix check at each call
    site; an Opus reaching `create_score` is a crash, not a bad import.

    thesession.org produces both shapes routinely and they mean DIFFERENT
    things, which the import rule (see `cli.cmd_import`) turns out to handle
    without ever having to tell them apart:

    - a tune's page (`/tunes/27/abc`) downloads every SETTING of one tune --
      38 of "Drowsy Maggie" -- as 38 `X:` blocks that all carry the same `T:`.
    - a set downloads as ONE `X:` block holding several tunes joined by a
      second `T:`/`K:` mid-body. music21 reads that as a single continuous
      score with a key change, which is what a set IS and what it sounds like,
      so it stays one arrangement and nothing here has to special-case it.

    ABC IS NOT HANDED STRAIGHT TO music21 either. Its reader drops decorations
    -- and for `H`, the fermata, drops the NOTE the decoration was on -- so an
    ABC path goes through `enrich.read_abc`, which strips the marks before the
    parse and attaches them afterwards. `abc_report` is where what it managed
    is kept for the import to relay.
    """
    from music21 import converter, stream

    source = Path(path)
    if source.suffix.lower() in ABC_SUFFIXES:
        from . import enrich

        scores, report = enrich.read_abc(source)
        for score in scores:
            score.scoranger_abc = report
        return scores

    parsed = converter.parse(str(source), forceSource=True)
    if isinstance(parsed, stream.Opus):
        return list(parsed.scores)
    return [parsed]


def abc_report(path, scores: list) -> dict:
    """What an ABC file said, and how much of it the notation now carries.

    music21 reads ABC well -- pitches, meter, modal keys, repeats, first and
    second endings, triplets, grace notes, slurs, chord symbols, the `Q:`
    tempo and a pickup bar all survive its reader. Its DECORATIONS do not, and
    `enrich.read_abc` is what puts them back; this reports what that managed,
    because a reader whose 120 roll marks vanished is owed the number and a
    reader whose 120 roll marks arrived should be told that too.

      `decorations_carried`   marks that reached the notation
      `decorations_misplaced` marks the enrichment declined to place because
                              it could not prove which note they belonged to
                              (see `enrich.restore`), with `abc_notes` naming
                              the tune and why
      `decorations_unknown`   `!...!` spellings there is no music21 object
                              for. Still dropped, now by name rather than as
                              a count.
      `chords_repaired`       chord brackets `enrich.repair_chords` closed or
                              dropped in tunes music21 refused as written
                              (thesession's "[Ee[[Ee]"); only ever counted
                              for a tune that would otherwise not import
      `tunes_skipped`         tunes in the file that could not be read even
                              repaired, each {title, reason}: the rest of the
                              file imports, and these are NAMED (0.19.0)
      `tune_types`            `R:`, which names the tune type -- reel, jig,
                              hornpipe. It is not notation and has nowhere to
                              live in MusicXML, so it is REPORTED and not
                              stored. A reader who wants it in the title can
                              put it there.
    """
    out: dict = {}
    report = next((getattr(s, "scoranger_abc", None) for s in scores
                   if getattr(s, "scoranger_abc", None)), None) or {}
    if report.get("carried"):
        out["decorations_carried"] = report["carried"]
    if report.get("misplaced"):
        out["decorations_misplaced"] = report["misplaced"]
    if report.get("reasons"):
        out["abc_notes"] = report["reasons"]
    if report.get("unknown"):
        out["decorations_unknown"] = report["unknown"]
    if report.get("chords_repaired"):
        out["chords_repaired"] = report["chords_repaired"]
    if report.get("tunes_skipped"):
        out["tunes_skipped"] = report["tunes_skipped"]

    # `R:` is read off the TEXT: it never reaches a stream at all.
    try:
        text = Path(path).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return out
    kinds = [m.strip() for m in re.findall(r"(?m)^R:\s*(.+?)\s*$", text)]
    if kinds:
        out["tune_types"] = sorted(set(kinds))
    return out


def list_versions(slug: str) -> list:
    return _repo().list_versions(slug)


def version_kind(slug: str, version_id: str | None = None) -> str:
    """"musicxml", "pdf" or "image", from the artifact the version points at.

    DERIVED from the filename rather than stored on the document, so every
    version written before PDFs existed reports correctly with no migration
    and no backfill.
    """
    return artifact_kind(resolve_path(slug, version_id))


def artifact_kind(path) -> str:
    """Three kinds, and it used to be two.

    Anything not notation was called "pdf", which was true while a PDF was the
    only scan there was. An image imported under that rule would have been
    treated correctly -- as a scan -- and LABELLED a PDF in the library, which
    is a lie in the one place a reader looks to see what they brought in.
    """
    suffix = Path(path).suffix.lower()
    if suffix in NOTATION_SUFFIXES:
        return "musicxml"
    return "image" if suffix in IMAGE_SUFFIXES else "pdf"


def resolve_notation_path(slug: str, version_id: str | None = None) -> Path:
    """The artifact, when it is notation. Raises clearly when it is not.

    Both `cli._load` and the on-device `bridge._load` hand their path straight
    to music21, which would fail on a PDF several frames deep in a parser with
    nothing useful to say. A reader who imported a scan needs to be told that
    it is a scan and that OMR is what makes it editable.
    """
    path = resolve_path(slug, version_id)
    kind = artifact_kind(path)
    if kind != "musicxml":
        what = "an image" if kind == "image" else "a PDF"
        raise NotNotationError(
            f"'{slug}' {version_id or 'latest'} is {what} -- a scan, not "
            f"notation, so it cannot be edited: run OMR on it to turn it into "
            f"an editable arrangement first.")
    return path


def _allocate_version(slug: str, parent: str | None) -> tuple[str, int]:
    """An id and a display position for a new version.

    The id is opaque and needs no coordination, which is the whole point: two
    devices appending offline to the same parent mint different ids and both
    survive. The old scheme counted existing rows to make `vNNN`, so both would
    have chosen v031 and one would have had to lose.

    `seq` is one past the PARENT, not one past the row count. On a straight
    chain those are the same number. On a fork they differ, and this is the
    definition that tells the truth: two children of v030 are both v031, which
    is what a branch IS, rather than one of them silently being called v032 and
    looking like it came after the other.
    """
    seq = 1
    if parent is not None:
        try:
            seq = int(resolve_version(slug, parent).get("seq") or 0) + 1
        except FileNotFoundError:
            seq = len(_repo().list_versions(slug)) + 1
    return ids.new_id(), seq


def _write_scan_version(slug: str, scan_path: Path, op: str, args: dict,
                        parent: str | None) -> dict:
    """A version whose artifact is the scan itself, copied in unchanged.

    Nothing re-encodes it: what a reader looks at is the file they gave us.
    That is why the SUFFIX is carried across rather than assumed -- it was
    hard-coded `.pdf`, which for an image would have written a JPEG to a file
    called v001.pdf and left every later reader of that name wrong about it.
    """
    import shutil

    repo = _repo()
    vid, seq = _allocate_version(slug, parent)
    fname = f"{vid}{scan_path.suffix.lower()}"
    score_dir(slug).mkdir(parents=True, exist_ok=True)
    shutil.copyfile(scan_path, score_dir(slug) / fname)
    # `parts` is [] and not a guess: a scan has no parts until OMR reads it, and
    # inventing one would put a lie in the library.
    doc = {"id": vid, "seq": seq, "label": f"v{seq:03d}", "file": fname,
           "op": op, "args": args,
           "parent": parent, "time": _now(), "parts": []}
    if _current_turn is not None and _current_turn["slug"] == slug:
        doc["turn"] = {"id": _current_turn["id"], "prompt": _current_turn["prompt"]}
    repo.add_version(slug, vid, seq, doc)
    score_doc = repo.get_score(slug)
    score_doc["latest"] = vid
    repo.set_score(slug, score_doc)
    rebuild_manifest()
    return doc


def books_dir() -> Path:
    return WORKSPACE / "books"


def book_path(slug: str) -> Path:
    return books_dir() / f"{slug}.pdf"


def list_books() -> list:
    return _repo().list_books()


def resolve_book(slug: str) -> dict:
    """The book document for a slug, or a FileNotFoundError that names the
    books there are. Books are addressed by slug alone -- unlike pieces and
    setlists, whose names are also accepted -- because a fake book's name is
    long and a library holds few of them."""
    doc = _repo().get_book(slug)
    if doc is None:
        have = [b["slug"] for b in _repo().list_books()]
        raise FileNotFoundError(f"No book '{slug}'. Have: {have}")
    return doc


def create_book(name: str, pdf_path) -> tuple[str, dict]:
    """Store a PDF as a BOOK: a collection arrangements are taken out of.

    A book is not a piece and not an arrangement. A fake book is one file
    holding hundreds of tunes; filing it as an arrangement would put all of
    them under one title, and filing it as a piece would claim it is one
    composition. It is neither -- it is a place to take pieces FROM.
    """
    import shutil

    from pypdf import PdfReader

    source = Path(pdf_path)
    if not source.exists():
        raise FileNotFoundError(f"No such file: {source}")
    if artifact_kind(source) != "pdf":
        raise ValueError(f"{source.name} is not a PDF")

    repo = _repo()
    base = slugify(name)
    slug, n = base, 2
    while repo.get_book(slug) is not None:
        slug = f"{base}-{n}"
        n += 1
    books_dir().mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, book_path(slug))
    doc = {"id": slug, "slug": slug, "uid": ids.new_id(), "name": name,
           "pages": len(PdfReader(str(book_path(slug))).pages),
           "created": _now()}
    repo.set_book(slug, doc)
    rebuild_manifest()
    return slug, doc


def rename_book(slug: str, new_name: str) -> dict:
    """Rename a book. The slug is immutable, as for pieces, setlists and scores.

    The slug names the stored file (books/<slug>.pdf) and every extraction ever
    made from this book recorded it in its version args, so changing it to
    follow a label would move bytes and orphan that history. A book has no
    engraved title to keep in step either -- it is a PDF nobody re-encodes --
    so unlike `rename_score` this touches the library name and nothing else.
    """
    doc = resolve_book(slug)
    new_name = (new_name or "").strip()
    if not new_name:
        raise ValueError("A name is required")
    doc["name"] = new_name
    _repo().set_book(slug, doc)
    rebuild_manifest()
    return doc


def save_book(slug: str, doc: dict) -> None:
    """Write a book document the caller has changed, and re-project."""
    _repo().set_book(slug, doc)
    rebuild_manifest()


def list_pieces() -> list:
    return _repo().list_pieces()


def delete_book(slug: str) -> None:
    _repo().delete_book(slug)
    book_path(slug).unlink(missing_ok=True)
    rebuild_manifest()


def extract_from_book(slug: str, from_page: int, to_page: int, name: str,
                      piece: str | None = None) -> tuple[str, dict]:
    """Take pages out of a book as a new PDF arrangement.

    Page numbers are 1-based and inclusive, as printed. The pages are COPIED:
    a book is a reference and taking a tune out of it must not cut it up.

    The result is an ordinary PDF arrangement, so everything that already works
    for a scan works for it -- it reads, it takes Pencil markup, and OMR can
    turn it into notation.
    """
    from pypdf import PdfReader, PdfWriter

    doc = resolve_book(slug)
    total = int(doc.get("pages") or 0)
    if from_page < 1 or to_page > total or from_page > to_page:
        raise ValueError(
            f"pages {from_page}-{to_page} are not in '{doc['name']}', "
            f"which has pages 1-{total}")

    reader = PdfReader(str(book_path(slug)))
    writer = PdfWriter()
    for index in range(from_page - 1, to_page):
        writer.add_page(_standalone_page(reader.pages[index]))
    staging = Path(tempfile.mkdtemp()) / f"{slugify(name)}.pdf"
    with open(staging, "wb") as f:
        writer.write(f)

    score_slug, entry = create_pdf_score(
        name, staging, op="book-extract",
        args={"book": slug, "pages": f"{from_page}-{to_page}"})
    if piece:
        assign_score_to_piece(score_slug, piece, create_if_missing=True)
    rebuild_manifest()
    return score_slug, entry


def _standalone_page(page):
    """The page as it will stand alone: holding only the images its content
    stream draws, and no links to pages of the book it no longer has.

    A PDF may hang one resource dictionary off every page -- jsPDF does, and
    the Comhaltas San Diego tunebook's pages each list all 689 of its images
    while drawing four -- and copying a page copies everything its resources
    name. Taking one tune out of that book wrote 28 MB.

    The page's resources are REPLACED on this page object, never edited: they
    are shared, and pruning them in place would take the next page's images
    away. A name the content stream draws that this cannot find (an escaped
    name, say) leaves the page exactly as it was, because a missing image is
    worse than a large file.
    """
    import re

    from pypdf.generic import ArrayObject, DictionaryObject, NameObject

    # A link to ANOTHER PAGE of the book goes too. It has nowhere to land in
    # the extract, and copying it copies the page it names -- and that page's
    # links, and so on through the book: the tunebook's "<<" and ">>" marks
    # brought all 134 pages along with every tune. A web link (the tunebook's
    # "play the tune") names no page and stays.
    annots = page.get("/Annots")
    if annots is not None:
        def internal(annot) -> bool:
            annot = annot.get_object()
            action = annot.get("/A")
            action = action.get_object() if action is not None else {}
            return "/Dest" in annot or action.get("/S") in ("/GoTo", "/GoToR")
        kept_annots = [a for a in annots.get_object() if not internal(a)]
        if kept_annots:
            page[NameObject("/Annots")] = ArrayObject(kept_annots)
        else:
            del page["/Annots"]

    resources = page.get("/Resources")
    if resources is None:
        return page
    resources = resources.get_object()
    xobjects = resources.get("/XObject")
    if xobjects is None:
        return page
    xobjects = xobjects.get_object()
    contents = page.get_contents()
    data = contents.get_data() if contents is not None else b""
    drawn = {m.decode("latin-1")
             for m in re.findall(rb"/([^\s/\[\]()<>{}%]+)\s*Do\b", data)}
    names = {str(k)[1:] for k in xobjects.keys()}
    if not drawn <= names:
        return page
    kept = DictionaryObject({NameObject(k): v for k, v in xobjects.items()
                             if str(k)[1:] in drawn})
    replaced = DictionaryObject(resources)
    replaced[NameObject("/XObject")] = kept
    page[NameObject("/Resources")] = replaced
    return page


def _ops_humanised(name: str) -> str:
    from . import ops

    return ops.humanise_title(name) or name


def create_scan_score(name: str, pdf_path, op: str = "import-pdf",
                      args: dict | None = None) -> tuple[str, dict]:
    """Create an arrangement whose artifact is a scan -- a PDF or an image.

    Returns (slug, version doc).

    It reads, it takes Pencil markup and it sits in the library like anything
    else; what it cannot do is be edited, because selection, addresses and
    every op come from the engraved MEI that only notation has.
    """
    source = Path(pdf_path)
    if not source.exists():
        raise FileNotFoundError(f"No such file: {source}")
    if artifact_kind(source) == "musicxml":
        raise ValueError(f"{source.name} is notation, not a scan")
    if source.suffix.lower() not in SCAN_SUFFIXES:
        raise ValueError(
            f"{source.name} is not a scan the app can show: "
            f"{sorted(SCAN_SUFFIXES)}")

    repo = _repo()
    base = slugify(name)
    slug, n = base, 2
    while repo.get_score(slug) is not None:
        slug = f"{base}-{n}"
        n += 1
    repo.set_score(slug, {
        "id": slug, "slug": slug, "uid": ids.new_id(), "name": name,
        # the file carries no metadata we can read, so the title is the name
        # the caller gave -- never a slug, never the file name. The app hands
        # us a file stem for a scan, so it is spelled out the same way an
        # import spells one: "sous-le-ciel-quartet" -> "Sous le ciel quartet".
        "title": _ops_humanised(name), "composer": None, "arranger": None,
        "created": _now(), "latest": None,
    })
    # same rule as create_score: an arrangement holding no version must not
    # exist, so the row goes if the artifact does not land
    try:
        entry = _write_scan_version(slug, source, op, args or {}, parent=None)
    except BaseException:
        import shutil
        repo.delete_score(slug)
        if score_dir(slug).exists():
            shutil.rmtree(score_dir(slug), ignore_errors=True)
        rebuild_manifest()
        raise
    return slug, entry


def _write_musicxml(m21_score, path: Path) -> list[str]:
    """The one place a score becomes a file.

    `makeTies` first: it splits any note running past its barline and ties it.
    Some ops leave such notes behind (`stripTies` produces them by design), and
    music21's MusicXML writer emits an over-long note AND the bars it swallows,
    duplicating that time and shifting everything after it. Splitting here is
    the fix that makes the write correct rather than merely checked.

    The file is then written to one side, read back, and moved into place. The
    read-back reports whatever odd bars the music has -- as WARNINGS, returned
    to the caller and recorded on the version. It never refuses.

    There was a refusal here once, and it was the wrong mechanism twice over:
    it blocked importing a scanned score whose bars were imperfect, and then
    blocked adding a repeat to a score that had inherited such a bar -- a bar
    the repeat never touched. Detecting damage after the fact and refusing to
    save is a band-aid over a transformation that should not damage anything.
    Correctness belongs in the ops, and the proof that they are correct belongs
    in engine/scripts/check_rhythm.py, which runs before a release rather than
    standing between a user and their own music.

    Returns the odd bars the written file has, phrased for a person.
    """
    from music21 import converter, stream as m21stream

    for part in (m21_score.parts or []):
        if part.getElementsByClass(m21stream.Measure):
            part.makeTies(inPlace=True)

    # keep the .musicxml suffix: music21 picks its parser from the extension
    staging = path.with_name(path.stem + ".writing" + path.suffix)
    m21_score.write("musicxml", fp=str(staging))
    text = staging.read_text(encoding="utf-8")
    cleaned = _M21_COMPOSER_STAMP.sub("", text)
    if cleaned != text:
        staging.write_text(cleaned, encoding="utf-8")

    from . import ops
    faults = ops.rhythm_faults(converter.parse(str(staging), forceSource=True))
    staging.replace(path)
    return [f"part {p} bar {b}: {w}" for p, b, w in faults]


def _write_version(slug: str, m21_score, op: str, args: dict, parent: str | None) -> dict:
    from . import ops

    repo = _repo()
    vid, seq = _allocate_version(slug, parent)
    fname = f"{vid}.musicxml"
    score_dir(slug).mkdir(parents=True, exist_ok=True)
    warnings = _write_musicxml(m21_score, score_dir(slug) / fname)
    doc = {"id": vid, "seq": seq, "label": f"v{seq:03d}", "file": fname,
           "op": op, "args": args,
           "parent": parent, "time": _now(), "parts": _parts_snapshot(m21_score)}
    if warnings:
        # kept on the version so the app can say "this came in with 3 odd bars"
        # rather than the user discovering it while playing
        doc["rhythm_warnings"] = warnings
    if _current_turn is not None and _current_turn["slug"] == slug:
        doc["turn"] = {"id": _current_turn["id"], "prompt": _current_turn["prompt"]}
    repo.add_version(slug, vid, seq, doc)
    score_doc = repo.get_score(slug)
    score_doc["latest"] = vid
    # the doc's metadata is a projection of the latest version's notation, never
    # an independent value -- that divergence is what gave the app one title in
    # the library and a different one engraved on the page
    meta = ops.score_metadata(m21_score)
    score_doc["title"] = meta["title"]
    score_doc["composer"] = meta["composer"]
    score_doc["arranger"] = meta["arranger"]
    repo.set_score(slug, score_doc)
    rebuild_manifest()
    return doc


def create_score(name: str, m21_score, op: str = "import", args: dict | None = None) -> tuple[str, dict]:
    """Create a new score with its first version. Returns (slug, version doc)."""
    repo = _repo()
    base = slugify(name)
    slug, n = base, 2
    while repo.get_score(slug) is not None:
        slug = f"{base}-{n}"
        n += 1
    from . import ops
    # The first full bar is bar 1, whatever the reader of the file thought
    # (ops.number_bars_from_one: ABC numbers a tune with no pickup from 0).
    ops.number_bars_from_one(m21_score)
    # A part with no name is named, or the mixer shows "Part" (ops.name_unnamed_parts).
    ops.name_unnamed_parts(m21_score)
    meta = ops.score_metadata(m21_score)
    repo.set_score(slug, {
        "id": slug, "slug": slug, "uid": ids.new_id(), "name": name,
        "title": meta["title"], "composer": meta["composer"],
        "arranger": meta["arranger"],
        "created": _now(), "latest": None,
    })
    # An arrangement that holds no music must not exist. The row has to be
    # written first -- _write_version updates it -- so if the version does not
    # land, the row goes with it. Without this, anything that interrupted the
    # write (a disk error, a parse failure building the parts snapshot, the app
    # being killed) left an arrangement of zero versions in the library, which
    # has no version to display and so sat on "Opening…" for ever.
    try:
        entry = _write_version(slug, m21_score, op, args or {}, parent=None)
    except BaseException:
        import shutil
        repo.delete_score(slug)
        if score_dir(slug).exists():
            shutil.rmtree(score_dir(slug), ignore_errors=True)
        rebuild_manifest()
        raise
    return slug, entry


def add_version(slug: str, m21_score, op: str, args: dict) -> dict:
    """Append a new immutable version derived from the current latest."""
    parent = latest_version(slug)["id"]
    return _write_version(slug, m21_score, op, args, parent=parent)


def add_version_from_file(slug: str, path, op: str, args: dict) -> dict:
    """Append a version parsed from a NOTATION FILE (what OMR on demand does).

    Separate from `add_version` because a file brings a title with it, and
    music21 invents one from the file's name when the file carries none. Every
    caller that reads notation off disk has to go through here, or the next one
    engraves "v001.mxl" at the top of someone's music again.
    """
    from music21 import converter

    from . import ops

    source = Path(path)
    m21_score = converter.parse(str(source), forceSource=True)
    doc = _repo().get_score(slug) or {}
    ops.carry_title_into_version(m21_score, doc.get("title") or doc.get("name"),
                                 source_stem=source.stem)
    return add_version(slug, m21_score, op, args)


def add_source(slug: str, m21_score, name: str, origin: str) -> dict:
    """Attach another found edition/tab of the piece as a reference source."""
    repo = _repo()
    load_meta(slug)  # validates the score exists
    sid = f"s{len(repo.list_sources(slug)) + 1:02d}"
    src_dir = score_dir(slug) / "sources"
    src_dir.mkdir(parents=True, exist_ok=True)
    fname = f"{sid}.musicxml"
    # through the guarded write, not a bare one: a source is pulled from later,
    # so a source written with a corrupted rhythm hands that corruption to
    # every arrangement that pulls a part out of it
    _write_musicxml(m21_score, src_dir / fname)
    doc = {"id": sid, "uid": ids.new_id(), "name": name, "origin": origin,
           "file": f"sources/{fname}",
           "time": _now(), "parts": _parts_snapshot(m21_score)}
    repo.add_source(slug, sid, doc)
    rebuild_manifest()
    return doc


def source_path(slug: str, source_id: str) -> Path:
    doc = _repo().get_source(slug, source_id)
    if doc is None:
        have = [s["id"] for s in _repo().list_sources(slug)]
        raise FileNotFoundError(f"No source '{source_id}' of '{slug}'. Have: {have}")
    return score_dir(slug) / doc["file"]


def create_piece(name: str) -> dict:
    """Create a piece document (a work that groups arrangements). Returns the doc."""
    repo = _repo()
    base = slugify(name)
    slug, n = base, 2
    while repo.get_piece(slug) is not None:
        slug = f"{base}-{n}"
        n += 1
    doc = {"id": slug, "slug": slug, "uid": ids.new_id(), "name": name,
           "created": _now()}
    repo.set_piece(slug, doc)
    rebuild_manifest()
    return doc


def resolve_piece(name_or_slug: str, create_if_missing: bool = False) -> dict:
    """Find a piece by slug, then by case-insensitive name; optionally create it."""
    repo = _repo()
    doc = repo.get_piece(name_or_slug)
    if doc is not None:
        return doc
    for p in repo.list_pieces():
        if p["name"].lower() == name_or_slug.lower():
            return p
    if create_if_missing:
        return create_piece(name_or_slug)
    available = [p["slug"] for p in repo.list_pieces()]
    raise FileNotFoundError(f"No piece '{name_or_slug}'. Available: {available}")


def assign_score_to_piece(slug: str, piece: str | None,
                          create_if_missing: bool = True) -> dict:
    """File an arrangement under a piece (None = unfile). The link lives on the score doc."""
    repo = _repo()
    doc = repo.get_score(slug)
    if doc is None:
        available = [s["slug"] for s in repo.list_scores()]
        raise FileNotFoundError(f"No score '{slug}'. Available: {available}")
    if piece is None:
        doc.pop("piece", None)
        piece_slug = None
    else:
        piece_slug = resolve_piece(piece, create_if_missing=create_if_missing)["slug"]
        doc["piece"] = piece_slug
    repo.set_score(slug, doc)
    # the piece this arrangement just left may now hold nothing
    _drop_empty_pieces(keep=piece_slug)
    # Maintain each piece's explicit arrangement order: drop the slug from
    # every other piece's order, append it to the target's.
    for p in repo.list_pieces():
        order = p.get("order") or []
        if p["slug"] == piece_slug:
            if slug not in order:
                order.append(slug)
                p["order"] = order
                repo.set_piece(p["slug"], p)
        elif slug in order:
            order.remove(slug)
            p["order"] = order
            repo.set_piece(p["slug"], p)
    rebuild_manifest()
    return {"score": slug, "piece": piece_slug}


def ensure_own_piece(slug: str) -> dict:
    """Give an arrangement a piece if it has none, named after the arrangement.

    **Every arrangement belongs to a piece.** An import that landed without one
    left a row the library could only tag UNFILED, which is a hole in the model
    rather than a state anybody chose: the app's own idea of itself is pieces
    holding arrangements, and a thing outside that has no shelf to sit on.

    Named from the arrangement's TITLE, which is a projection of the notation,
    so the piece is called what the music is called. `resolve_piece` matches an
    existing name case-insensitively BEFORE creating, and that one line is what
    makes the rule behave correctly on real material instead of littering:

        thesession.org/tunes/27/abc downloads 38 SETTINGS of "Drowsy Maggie".
        Each is its own arrangement -- they are genuinely different music --
        and all 38 carry the same `T:`, so the first mints the piece and the
        other 37 find it. One piece, 38 arrangements, numbered in file order.

        A set file holds three DIFFERENT tunes, so it makes three pieces of one
        arrangement each. Same rule, no branch, no knowledge of ABC.

    Idempotent, and never moves an arrangement that is already filed -- an
    import into a piece the reader chose has already said where it goes.
    """
    doc = _repo().get_score(slug)
    if doc is None:
        raise FileNotFoundError(f"No score '{slug}'")
    if doc.get("piece"):
        return {"score": slug, "piece": doc["piece"], "created": False}
    name = doc.get("title") or doc.get("name") or slug
    existed = any(p["name"].lower() == name.lower() for p in _repo().list_pieces())
    assign_score_to_piece(slug, name, create_if_missing=True)
    return {"score": slug, "piece": (_repo().get_score(slug) or {}).get("piece"),
            "created": not existed}


def set_piece_order(name_or_slug: str, order: list) -> dict:
    """Set a piece's arrangement order. Every slug must belong to the piece."""
    repo = _repo()
    doc = resolve_piece(name_or_slug)
    members = {s["slug"] for s in repo.list_scores() if s.get("piece") == doc["slug"]}
    bad = [s for s in order if s not in members]
    if bad:
        raise ValueError(f"Not arrangements of '{doc['slug']}': {bad}. Members: {sorted(members)}")
    doc["order"] = list(order)
    repo.set_piece(doc["slug"], doc)
    rebuild_manifest()
    return doc


def set_score_metadata(slug: str, title: str | None = None,
                       composer: str | None = None,
                       arranger: str | None = None) -> dict:
    """Edit an arrangement's metadata, notation included.

    The title is one value, not two: it is the arrangement's name in the library
    AND the title engraved at the top of the page. Because the engraved title
    lives in the notation, this appends a version like any other mutating op --
    the edit is versioned and reversible, and no file is ever hand-edited.

    The slug never moves: it is the identity every version artifact, piece order
    and chat 'arr:' reference is keyed on.
    """
    from music21 import converter

    from . import ops

    repo = _repo()
    doc = repo.get_score(slug)
    if doc is None:
        available = [s["slug"] for s in repo.list_scores()]
        raise FileNotFoundError(f"No score '{slug}'. Available: {available}")
    if title is not None and not title.strip():
        raise ValueError("A title is required")
    if title is None and composer is None and arranger is None:
        raise ValueError("Nothing to change: pass a title, composer or arranger")

    # A scan -- a PDF or a picture -- has no notation to carry a title, so its
    # details live on the document until OMR gives it notation (which reads
    # the document's name as its title). Parsing the artifact was the bug:
    # music21 has no reader for a JPEG and died inside its converter with
    # "cannot find format from file extensions" (Ali, 0.8.0 build 193).
    if version_kind(slug) != "musicxml":
        if title is not None:
            doc["name"] = title.strip()
            doc["title"] = title.strip()
        for role, value in (("composer", composer), ("arranger", arranger)):
            if value is not None:
                doc[role] = value.strip() or None
        repo.set_score(slug, doc)
        rebuild_manifest()
        return {"score": slug, "version": None, "name": doc["name"],
                "title": doc.get("title"), "composer": doc.get("composer"),
                "arranger": doc.get("arranger"), "scan": True}

    score = converter.parse(str(resolve_path(slug)), forceSource=True)
    applied = ops.set_metadata(score, title=title, composer=composer,
                              arranger=arranger)
    entry = add_version(slug, score, "set-metadata",
                        {k: v for k, v in (("title", title), ("composer", composer),
                                           ("arranger", arranger)) if v is not None})
    if title is not None:
        doc = repo.get_score(slug)          # add_version refreshed the projection
        doc["name"] = title.strip()
        repo.set_score(slug, doc)
        rebuild_manifest()
    return {"score": slug, "version": entry["id"], "name": repo.get_score(slug)["name"],
            **applied}


_BAR_CHECK_FILE = ".bars-numbered-from-one.json"


def number_bars_from_one_everywhere() -> dict:
    """Give every arrangement whose LATEST version numbers its first full bar 0
    a new version numbered from 1. Run at launch; idempotent.

    A NEW VERSION rather than a change on load, because the page and the ops
    must agree: a lasso on the page names bars by the numbers drawn, and an op
    that renumbered as it loaded would act one bar off. Once the latest
    version is renumbered, what is shown is what is operated on.

    Checking means parsing, so what has been checked is remembered by version
    id in the workspace (a pickup tune is checked once, not every launch).
    """
    import json
    from music21 import converter

    from . import ops

    repo = _repo()
    path = WORKSPACE / _BAR_CHECK_FILE
    try:
        checked = set(json.loads(path.read_text()))
    except (OSError, ValueError):
        checked = set()
    renumbered = []
    for doc in repo.list_scores():
        latest = doc.get("latest")
        if not latest or latest in checked:
            continue
        checked.add(latest)
        try:
            notation = resolve_notation_path(doc["slug"])
        except (FileNotFoundError, NotNotationError):
            continue          # a scan, or nothing to read: no bars to number
        head = notation.read_text(encoding="utf-8", errors="replace")[:20000]
        if not re.search(r'<measure\b[^>]*\bnumber="0"', head):
            continue
        score = converter.parse(str(notation), forceSource=True)
        if ops.number_bars_from_one(score):
            entry = add_version(doc["slug"], score, "number-bars-from-one", {})
            checked.add(entry["id"])
            renumbered.append(doc["slug"])
    try:
        path.write_text(json.dumps(sorted(checked)))
    except OSError:
        pass
    return {"renumbered": renumbered}


def title_repairs() -> list[dict]:
    """Arrangements engraving an internal file name instead of a title.

    A read. It looks at the score DOCUMENT rather than parsing forty scores,
    which it is entitled to do: `_write_version` writes the document's title as
    a projection of the notation's, so what the document says is what the page
    shows.

    Each entry carries `title` (what is engraved now), `proposed` (what a
    repair would engrave) and `kind` -- "artifact-name" for the `v001.mxl` this
    was reported for, "file-name" for the slug an earlier import left behind.
    An arrangement whose PDF is still its latest version has no notation to
    version and is left out: its title never came from a file in the first
    place, and writing the document directly is the divergence the one-title
    rule exists to prevent.
    """
    from . import ops

    repo = _repo()
    pieces = {p["slug"]: p["name"] for p in repo.list_pieces()}
    out = []
    for doc in repo.list_scores():
        title = doc.get("title")
        proposed = ops.title_repair(title, doc.get("name"),
                                    pieces.get(doc.get("piece")))
        if proposed is None:
            continue
        if not doc.get("latest") or version_kind(doc["slug"]) != "musicxml":
            continue
        out.append({
            "slug": doc["slug"], "name": doc.get("name"),
            "title": title, "proposed": proposed,
            "kind": ("artifact-name" if ops.is_internal_artifact_name(title)
                     else "file-name"),
        })
    return out


def repair_titles(dry_run: bool = True) -> dict:
    """Give every arrangement engraving a file name a corrected NEW version.

    Deliberately not automatic, and deliberately not a flag. Silently appending
    a version to forty arrangements the first time an app launches is a large
    edit nobody asked for, and a per-device UserDefaults flag would run it
    again on the reader's next iPad. This is derived from the library itself:
    the offer appears while there is something to repair and stops existing
    once there is not, on every device, with no state to keep.

    The repair is `set-metadata` and nothing else -- a new immutable version,
    reversible like any other, with history left exactly as it was written.
    """
    found = title_repairs()
    if dry_run:
        return {"dry_run": True, "affected": len(found), "repairs": found}
    repaired, failed = [], []
    for row in found:
        try:
            result = set_score_metadata(row["slug"], title=row["proposed"])
            repaired.append({**row, "version": result["version"]})
        except Exception as exc:                          # noqa: BLE001
            # one unreadable arrangement may not abandon the other thirty-nine
            failed.append({**row, "error": f"{type(exc).__name__}: {exc}"})
    rebuild_manifest()
    return {"dry_run": False, "affected": len(repaired),
            "repairs": repaired, "failed": failed}


def rename_slug(slug: str, new_slug: str) -> dict:
    """Change a score's slug -- the identity it is filed under.

    The slug is not a title: it is the key the artifact directory, the version
    and source rows, and each piece's ordering are all filed under, and the
    handle chat uses to refer to a sibling arrangement ('arr:<slug>'). So this
    is a move, not an edit: the directory is renamed and every reference is
    rewritten in the same call. Nothing outside the workspace holds a slug
    except the app's own pencil annotations, which it migrates itself.

    Slugs stay slugs: the requested name is normalized the same way an import
    would normalize it, and a collision is refused rather than suffixed --
    the caller asked for a specific handle, so silently getting another one
    would be worse than an error.
    """
    repo = _repo()
    doc = repo.get_score(slug)
    if doc is None:
        available = [s["slug"] for s in repo.list_scores()]
        raise FileNotFoundError(f"No score '{slug}'. Available: {available}")
    # slugify falls back to "score" for input with nothing usable in it, which
    # would quietly file the arrangement under a name nobody asked for
    if not re.search(r"[a-z0-9]", (new_slug or "").lower()):
        raise ValueError("A slug needs at least one letter or number")
    target = slugify(new_slug)
    if target == slug:
        return {"score": slug, "previous": slug, "renamed": False}
    if repo.get_score(target) is not None:
        raise ValueError(f"The slug '{target}' is already taken by another arrangement")

    src, dst = score_dir(slug), score_dir(target)
    if dst.exists():
        raise ValueError(f"{dst} already exists on disk; not overwriting it")
    if src.exists():
        src.rename(dst)

    versions = repo.list_versions(slug)
    sources = repo.list_sources(slug)
    doc = dict(doc)
    doc["id"] = doc["slug"] = target
    repo.set_score(target, doc)
    for v in versions:
        repo.add_version(target, v["id"], v["seq"], v)
    for src_doc in sources:
        repo.add_source(target, src_doc["id"], src_doc)
    repo.delete_score(slug)

    # a piece's ordering is a list of score slugs
    for piece in repo.list_pieces():
        order = piece.get("order") or []
        if slug in order:
            piece["order"] = [target if x == slug else x for x in order]
            repo.set_piece(piece["slug"], piece)

    rebuild_manifest()
    return {"score": target, "previous": slug, "renamed": True,
            "versions": len(versions), "sources": len(sources)}


def rename_score(slug: str, new_name: str) -> dict:
    """Rename an arrangement: its library name and its engraved title together.

    Kept as the name every caller already uses; the work is set_score_metadata's,
    so a rename can never leave the page saying something else.
    """
    return set_score_metadata(slug, title=new_name or "")


def rename_piece(name_or_slug: str, new_name: str) -> dict:
    """Rename a piece (the slug is immutable; only the display name changes)."""
    repo = _repo()
    doc = resolve_piece(name_or_slug)
    doc["name"] = new_name
    repo.set_piece(doc["slug"], doc)
    rebuild_manifest()
    return doc


def combine_pieces(names: list, into: str | None = None,
                   name: str | None = None) -> dict:
    """Fold several pieces into one. The curation step `ensure_own_piece` needs.

    Every import now mints a piece, which is right -- an arrangement with no
    shelf to sit on is a hole in the model -- but it means a reader who brings
    the same tune in twice under two spellings ends up with two pieces for one
    piece of music. This is how they fix it, and the two features only make
    sense together.

    WHAT SURVIVES, all four decided here rather than left to the caller:

    - THE PIECE. The first one named, unless `into` names another of them. Its
      slug AND its uid survive, so every setlist, share and sync record that
      already points at it still resolves. The others are gone afterwards and
      the engine cannot bring them back -- there is no undo for this, which is
      why the app asks twice.
    - THE NAME. The survivor's, unless `name` gives a new one. Combining is not
      a rename and must not silently perform one.
    - THE METADATA. The survivor's own values win. A field the survivor leaves
      EMPTY is filled from the first absorbed piece that has one, and tags are
      unioned in the order they were first seen. Combining two records of one
      tune usually means one of them was credited and the other was not;
      dropping that credit is the wrong default, and overwriting a value
      somebody deliberately typed is a worse one.
    - THE NUMBERING, which is what a reader notices first. Arrangements are
      numbered from the piece's `order`, so the survivor's own keep the numbers
      they had -- #1 stays #1 -- and the absorbed arrangements APPEND, piece by
      piece in the order named and keeping each piece's internal order. Nothing
      a reader had already learned to call #2 becomes #5.

    Returns what it did, including the resulting order, because that is the
    part worth showing back.
    """
    repo = _repo()
    docs, seen = [], set()
    for n in names:
        doc = resolve_piece(str(n))
        if doc["slug"] not in seen:
            seen.add(doc["slug"])
            docs.append(doc)
    if len(docs) < 2:
        raise ValueError(
            f"combine needs at least two different pieces, got {len(docs)}")

    survivor = resolve_piece(into) if into else docs[0]
    if survivor["slug"] not in seen:
        raise ValueError(
            f"'{survivor['slug']}' is not one of the pieces being combined: "
            f"{[d['slug'] for d in docs]}")
    absorbed = [d for d in docs if d["slug"] != survivor["slug"]]

    def members(doc):
        held = [s["slug"] for s in repo.list_scores() if s.get("piece") == doc["slug"]]
        order = [s for s in (doc.get("order") or []) if s in held]
        return order + [s for s in held if s not in order]

    moved = []
    for doc in absorbed:
        for slug in members(doc):
            assign_score_to_piece(slug, survivor["slug"], create_if_missing=False)
            moved.append(slug)

    doc = repo.get_piece(survivor["slug"])
    filled = {}
    for field in ("composer", "arranger"):
        if not doc.get(field):
            for other in absorbed:
                if other.get(field):
                    doc[field] = other[field]
                    filled[field] = other[field]
                    break
    tags, lower = list(doc.get("tags") or []), {str(x).lower() for x in (doc.get("tags") or [])}
    for other in absorbed:
        for tag in other.get("tags") or []:
            if str(tag).lower() not in lower:
                lower.add(str(tag).lower())
                tags.append(tag)
    if tags:
        doc["tags"] = tags
    if name:
        doc["name"] = name
    repo.set_piece(doc["slug"], doc)
    # the absorbed pieces hold nothing now, and a piece holding nothing is not
    # allowed to exist
    _drop_empty_pieces(keep=doc["slug"])
    rebuild_manifest()

    final = repo.get_piece(doc["slug"]) or doc
    return {"piece": doc["slug"], "name": doc["name"],
            "absorbed": [{"slug": d["slug"], "name": d["name"]} for d in absorbed],
            "arrangements_moved": moved,
            "order": members(final),
            "metadata_filled": filled,
            "tags": final.get("tags") or []}


def tidy_pieces() -> list[str]:
    """Drop pieces left holding nothing by an older build. Returns their names."""
    repo = _repo()
    held = {d.get("piece") for d in repo.list_scores() if d.get("piece")}
    gone = [p["name"] for p in repo.list_pieces() if p["slug"] not in held]
    _drop_empty_pieces()
    if gone:
        rebuild_manifest()
    return gone


def delete_piece(name_or_slug: str, with_arrangements: bool = False) -> None:
    """Delete a piece.

    With `with_arrangements`, its arrangements go too -- which is what deleting
    a folder means to the person doing it. Without, they are unfiled, and the
    piece goes because a piece holding nothing is not allowed to exist.
    """
    doc = resolve_piece(name_or_slug)
    members = [d["slug"] for d in _repo().list_scores() if d.get("piece") == doc["slug"]]
    if with_arrangements:
        for slug in members:
            delete_score(slug)
    else:
        for slug in members:
            assign_score_to_piece(slug, None)
    _repo().delete_piece(doc["slug"])
    _drop_empty_pieces()
    rebuild_manifest()


def create_setlist(name: str) -> dict:
    """Create a setlist document (an ordered group of arrangements)."""
    repo = _repo()
    base = slugify(name)
    slug, n = base, 2
    while repo.get_setlist(slug) is not None:
        slug = f"{base}-{n}"
        n += 1
    # shareId / ownerUid are NULLABLE and absent until a set list is shared
    # (design/FIREBASE.md §6A.1). There is one kind of set list; sharing is a
    # field on it, so `shareId is None` means no Firestore involvement at all.
    doc = {"id": slug, "slug": slug, "uid": ids.new_id(), "name": name,
           "scores": [], "created": _now(),
           "shareId": None, "ownerUid": None}
    repo.set_setlist(slug, doc)
    rebuild_manifest()
    return doc


def bind_setlist_share(name_or_slug: str, share_id: str,
                       owner_uid: str) -> dict:
    """Record that this set list is now the shared document `share_id`.

    The last step of promotion (§6A.1 step 4). Written AFTER the Firestore
    document and its entries exist, so a set list is never marked shared
    before it is: a `shareId` pointing at nothing would make the row claim a
    collaboration it has not got, and the recovery from that is worse than
    retrying a share.

    Idempotent, and deliberately not fussy about being called twice -- the
    share button will be pressed again.
    """
    repo = _repo()
    doc = resolve_setlist(name_or_slug)
    doc["shareId"] = share_id
    doc["ownerUid"] = owner_uid
    repo.set_setlist(doc["slug"], doc)
    rebuild_manifest()
    return doc


def link_shared_entry(name_or_slug: str, entry_id: str) -> dict:
    """Record that this arrangement is this device's copy of a shared entry.

    A copy adopted from a shared set list is imported with a uid of its own
    (it arrived from outside), so nothing in the arrangement said which entry
    it was, and the only record was a per-device cache in the app. A second
    device of the same account then received the copy through library sync
    and could not tell it already had the entry, and imported it again. Kept
    on the arrangement, the link travels with it: library sync carries every
    field of a score document.
    """
    repo = _repo()
    found = repo.get_score(name_or_slug)
    if found is None:
        available = [s["slug"] for s in repo.list_scores()]
        raise FileNotFoundError(f"No score '{name_or_slug}'. Available: {available}")
    doc = dict(found)
    if doc.get("sharedEntry") != entry_id:
        doc["sharedEntry"] = entry_id
        repo.set_score(doc["slug"], doc)
        rebuild_manifest()
    return {"score": doc["slug"], "sharedEntry": entry_id}


def resolve_setlist(name_or_slug: str, create_if_missing: bool = False) -> dict:
    """Find a setlist by slug, then by case-insensitive name; optionally create it."""
    repo = _repo()
    doc = repo.get_setlist(name_or_slug)
    if doc is not None:
        return doc
    for s in repo.list_setlists():
        if s["name"].lower() == name_or_slug.lower():
            return s
    if create_if_missing:
        return create_setlist(name_or_slug)
    available = [s["slug"] for s in repo.list_setlists()]
    raise FileNotFoundError(f"No setlist '{name_or_slug}'. Available: {available}")


def add_score_to_setlist(setlist: str, score: str,
                         create_if_missing: bool = True) -> dict:
    """Append an arrangement to a setlist (no-op if already in it).

    A setlist is a running order, and what gets played is an arrangement, not a
    piece: "the quartet version, then the accordion one" is a set; "Sous le
    ciel de Paris" is not.
    """
    repo = _repo()
    doc = resolve_setlist(setlist, create_if_missing=create_if_missing)
    if repo.get_score(score) is None:
        available = [s["slug"] for s in repo.list_scores()]
        raise FileNotFoundError(f"No arrangement '{score}'. Available: {available}")
    scores = doc.get("scores") or []
    if score not in scores:
        scores.append(score)
        doc["scores"] = scores
        repo.set_setlist(doc["slug"], doc)
        rebuild_manifest()
    return doc


def remove_score_from_setlist(setlist: str, score: str) -> dict:
    """Drop an arrangement from a setlist. The arrangement itself is untouched."""
    repo = _repo()
    doc = resolve_setlist(setlist)
    doc["scores"] = [s for s in (doc.get("scores") or []) if s != score]
    repo.set_setlist(doc["slug"], doc)
    rebuild_manifest()
    return doc


def set_setlist_order(name_or_slug: str, order: list) -> dict:
    """Set a set list's running order. Every slug must already be in it.

    One reorder rather than a remove and a re-add: the latter would drop the
    arrangement to the end and lose the position of everything after it, which
    is the opposite of what "move up" means.
    """
    doc = resolve_setlist(name_or_slug)
    members = set(doc.get("scores") or [])
    bad = [s for s in order if s not in members]
    if bad:
        raise ValueError(f"Not in '{doc['slug']}': {bad}. Members: {sorted(members)}")
    doc["scores"] = list(order)
    _repo().set_setlist(doc["slug"], doc)
    rebuild_manifest()
    return doc


def rename_setlist(name_or_slug: str, new_name: str) -> dict:
    """Rename a setlist (slug is immutable, like pieces and scores)."""
    repo = _repo()
    doc = resolve_setlist(name_or_slug)
    new_name = (new_name or "").strip()
    if not new_name:
        raise ValueError("A name is required")
    doc["name"] = new_name
    repo.set_setlist(doc["slug"], doc)
    rebuild_manifest()
    return doc


def delete_setlist(name_or_slug: str) -> dict:
    """Delete a setlist document. Pieces and arrangements are untouched: a
    setlist is only an ordered grouping."""
    doc = resolve_setlist(name_or_slug)
    _repo().delete_setlist(doc["slug"])
    rebuild_manifest()
    return {"deleted": doc["slug"]}


# How long a deleted thing stays recoverable. The UI offers an undo bar for
# ~10s; the engine keeps it a little longer so a slow tap still lands.
UNDO_WINDOW_SECONDS = 30


def delete_score(slug: str, immediate: bool = False) -> None:
    """Delete an arrangement, and the piece with it if it was the last one.

    A piece does not exist without at least one arrangement. It is a folder for
    arrangements, not a thing in its own right: an empty one can be neither
    opened (opening a piece means opening one of its arrangements) nor deleted
    through the UI, because the UI deletes a piece BY deleting its contents --
    and an empty piece has none. Ali hit exactly that: a piece showing "0
    arrangements" that would not go away.

    Deleting is TWO PHASES. The row is marked and disappears from the library
    at once, but its artifacts stay on disk for `UNDO_WINDOW_SECONDS` so the
    undo bar can put it back exactly as it was -- versions, sources, annotations
    and all. `sweep()` is what actually reclaims. `immediate=True` skips the
    window, for callers that mean it (a test, or a sweep of something already
    marked).

    Marking rather than copying: an arrangement is a directory of MusicXML and
    a row of history, and duplicating that to hold it in reserve would be both
    slow and a second source of truth.
    """
    import shutil
    load_meta(slug)  # raises with available slugs if missing
    if immediate:
        _repo().delete_score(slug)
        if score_dir(slug).exists():
            shutil.rmtree(score_dir(slug))
        _drop_empty_pieces()
        rebuild_manifest()
        return
    doc = _repo().get_score(slug) or {}
    doc["deleted_at"] = _now()
    _repo().set_score(slug, doc)
    _drop_empty_pieces()
    rebuild_manifest()


def restore_score(slug: str) -> dict:
    """Put a marked arrangement back, with everything it had."""
    repo = _repo()
    doc = repo.get_score(slug)
    if doc is None:
        raise FileNotFoundError(f"No score '{slug}' to restore.")
    if not doc.pop("deleted_at", None):
        return doc          # never deleted; restoring is a no-op, not an error
    repo.set_score(slug, doc)
    rebuild_manifest()
    return doc


def sweep(now: str | None = None) -> list[str]:
    """Reclaim anything whose undo window has passed. Returns what went.

    Called on launch and after each delete. Until this runs the artifacts are
    still on disk, which is exactly what makes undo possible.
    """
    from datetime import datetime, timedelta
    repo = _repo()
    cutoff = datetime.fromisoformat(now or _now()) - timedelta(seconds=UNDO_WINDOW_SECONDS)
    gone = []
    for doc in list(repo.list_scores(include_deleted=True)):
        stamp = doc.get("deleted_at")
        if not stamp:
            continue
        try:
            when = datetime.fromisoformat(stamp)
        except ValueError:
            when = cutoff       # unparseable: treat as expired rather than immortal
        if when <= cutoff:
            delete_score(doc["slug"], immediate=True)
            gone.append(doc["slug"])
    if gone:
        rebuild_manifest()
    return gone


def _drop_empty_pieces(keep: str | None = None) -> None:
    """Remove any piece left holding nothing.

    Called where an arrangement LEAVES a piece -- deleted, or re-filed -- and
    never on a plain rebuild: a piece is legitimately empty for the instant
    between being created and its first arrangement arriving, which is exactly
    what "new piece, then import into it" does. `keep` protects that piece.
    """
    repo = _repo()
    held = {d.get("piece") for d in repo.list_scores() if d.get("piece")}
    for piece in repo.list_pieces():
        if piece["slug"] not in held and piece["slug"] != keep:
            repo.delete_piece(piece["slug"])


def _setlist_with_scores(doc: dict, pieces: list[dict]) -> dict:
    """Bring a setlist written before setlists held arrangements up to date.

    Setlists used to be ordered lists of *pieces*. A piece is not a thing you
    play — its arrangements are — so a stored piece is expanded, in place and
    once, into that piece's arrangements in their existing order. Nothing is
    dropped and nothing is guessed: a piece with three arrangements becomes
    those three, and the user reorders or removes from there.
    """
    if doc.get("scores") is not None or not doc.get("pieces"):
        doc.setdefault("scores", [])
        return doc
    by_piece = {p["slug"]: p.get("arrangements") or [] for p in pieces}
    expanded: list[str] = []
    for piece_slug in doc.get("pieces") or []:
        for score in by_piece.get(piece_slug, []):
            if score not in expanded:
                expanded.append(score)
    doc["scores"] = expanded
    doc.pop("pieces", None)
    _repo().set_setlist(doc["slug"], doc)
    return doc


def set_piece_metadata(slug: str, composer: str | None = None,
                       tags: list[str] | None = None,
                       arranger: str | None = None) -> dict:
    """Write a piece's own metadata. Only the fields passed are touched.

    Composer lives HERE as well as in the notation, and for most of this
    library it can only live here: an arrangement imported as a PDF has no
    notation to write a composer into, so a score brought in as a scan could
    never be credited at all. The piece is the thing a person credits anyway --
    the tune has a composer; a particular chart of it does not have a different
    one.

    Tags are a flat set on the piece: origin and tradition, in practice
    ("Serbia", "Bulgaria", "Macedonia"). They are deduplicated and their order
    is kept, because the first one a person types is the one they think of
    first. An empty list clears them; None leaves them alone.
    """
    repo = _repo()
    doc = repo.get_piece(slug)
    if doc is None:
        raise KeyError(f"no piece {slug!r}")
    if composer is not None:
        doc["composer"] = composer.strip() or None
    if arranger is not None:
        # Where a credit that is not a composer belongs: "interpretare: X
        # transcript: Y" is a performer and a transcriber, and putting that in
        # the composer field says the tune was written by them.
        doc["arranger"] = arranger.strip() or None
    if tags is not None:
        seen, kept = set(), []
        for t in tags:
            t = str(t).strip()
            if t and t.lower() not in seen:
                seen.add(t.lower())
                kept.append(t)
        doc["tags"] = kept
    repo.set_piece(slug, doc)
    rebuild_manifest()
    return doc


def all_tags() -> list[str]:
    """Every tag in use, by falling frequency then alphabetically.

    What the library's filter is built from: a tag exists because a piece
    carries it, so there is no separate vocabulary to keep in step.
    """
    counts: dict[str, tuple[int, str]] = {}
    for p in _repo().list_pieces():
        for t in p.get("tags") or []:
            n, spelling = counts.get(t.lower(), (0, t))
            counts[t.lower()] = (n + 1, spelling)
    return [spelling for _, (n, spelling) in
            sorted(counts.items(), key=lambda kv: (-kv[1][0], kv[1][1].lower()))]


def rebuild_manifest() -> dict:
    """Project the DB into workspace/manifest.json for the viewer."""
    repo = _repo()
    scores = []
    score_docs = repo.list_scores()
    for doc in score_docs:
        versions = repo.list_versions(doc["slug"])
        for v in versions:
            # derived from the artifact, so versions written before PDFs
            # existed report correctly without a backfill
            v["kind"] = artifact_kind(v.get("file") or "")
            # every version carries a label, including any written before
            # labels existed, so no client ever has to render a raw id
            v["label"] = version_label(v)
        scores.append({
            "slug": doc["slug"], "uid": doc.get("uid"), "name": doc["name"],
            "title": doc.get("title"), "composer": doc.get("composer"),
            "arranger": doc.get("arranger"),
            "latest": doc.get("latest"), "versions": versions,
            "sources": repo.list_sources(doc["slug"]),
            "piece": doc.get("piece"),
            # Which shared set list entry this arrangement is a copy of, if
            # any (`link_shared_entry`): the app's set list sync matches on it.
            "sharedEntry": doc.get("sharedEntry"),
        })
    pieces = []
    for p in sorted(repo.list_pieces(), key=lambda x: x["name"].lower()):
        members = {d["slug"] for d in score_docs if d.get("piece") == p["slug"]}
        # explicit order first (only slugs that still exist and point back),
        # then any stragglers by creation time
        ordered = [s for s in (p.get("order") or []) if s in members]
        stragglers = sorted(members - set(ordered),
                            key=lambda s: next(d.get("created") or ""
                                               for d in score_docs if d["slug"] == s))
        pieces.append({"slug": p["slug"], "uid": p.get("uid"),
                       "name": p["name"],
                       "composer": p.get("composer"),
                       "arranger": p.get("arranger"),
                       "tags": p.get("tags") or [],
                       "arrangements": ordered + stragglers})
    known = {d["slug"] for d in score_docs}
    setlists = []
    for doc in sorted(repo.list_setlists(), key=lambda x: x["name"].lower()):
        doc = _setlist_with_scores(doc, pieces)
        setlists.append({"slug": doc["slug"], "uid": doc.get("uid"),
                         "name": doc["name"],
                         # Sharing is a field on the set list, so it has to be
                         # in the projection the app reads: LibraryView shows a
                         # row as shared because `shareId` is in the manifest
                         # (Models.SetlistDoc.isShared). Left out, the binding
                         # written by promotion's last step reaches the
                         # database and nothing else, and a shared set list
                         # looks local forever.
                         "shareId": doc.get("shareId"),
                         "ownerUid": doc.get("ownerUid"),
                         "arrangements": [s for s in doc.get("scores") or []
                                          if s in known]})
    # `contents` is the book read tune by tune (booksplit.set_contents): the
    # app lists it the way it lists a set list, so it has to be projected.
    books = [{"slug": b["slug"], "uid": b.get("uid"), "name": b["name"],
              "pages": b.get("pages"), "contents": b.get("contents") or []}
             for b in sorted(repo.list_books(), key=lambda x: x["name"].lower())]
    # The library's own identity, so the app can address this device without
    # reading the database (design/FIREBASE.md §9.2). Named fields, not the
    # whole document, like every other projection here: a journaling repository
    # puts `rev` and `synced_rev` on what it writes, and §4.1 says neither is
    # ever exposed to the user, the CLI or chat. Passed through wholesale, the
    # manifest would differ with sync on and off -- which is exactly what
    # check_sync.py's transparency assertion caught.
    library_doc = repo.get_library() or {}
    library = {"uid": library_doc.get("uid"), "created": library_doc.get("created")}
    manifest = {"generated": _now(), "scores": scores, "pieces": pieces,
                "setlists": setlists, "books": books, "library": library}
    WORKSPACE.mkdir(parents=True, exist_ok=True)
    (WORKSPACE / "manifest.json").write_text(json.dumps(manifest, indent=2))
    return manifest


#: The names these had while a PDF was the only scan there was. Kept because
#: the bridge, the CLI and the checks all call them, and a rename that breaks
#: three callers to say the same thing is churn.
create_pdf_score = create_scan_score
_write_pdf_version = _write_scan_version


def import_scan(path, name: str, op: str = "import-pdf",
                args: dict | None = None) -> dict:
    """Import a PDF or an image as an arrangement, and report it like an op."""
    slug, entry = create_scan_score(name, path, op=op, args=args)
    rebuild_manifest()
    return {"score": slug, "op": op, "new_version": entry["id"],
            "kind": artifact_kind(resolve_path(slug)), "file": entry["file"]}
