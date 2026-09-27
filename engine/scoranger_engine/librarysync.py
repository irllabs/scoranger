"""A signed-in account's library, the same on every device (0.16.0).

design/FIREBASE.md §2, §4 and §7. The local database stays authoritative for
the device; the Swift sync layer copies what this module hands it up to
Firestore and Cloud Storage, and hands back what other devices wrote. Nothing
here knows Firebase exists: it speaks RECORDS, and a record is one document as
the server keeps it.

**Two names, and this is where they meet.** On the device a document is found
by its slug, and documents point at each other by slug -- an arrangement's
`piece`, a piece's `order`, a set list's `scores`. A slug is local: derived
from a title, moved by a rename, and chosen independently on every device, so
two devices can call different arrangements `reel`. The server knows every
document by its `uid` and nothing else. So on the way out every slug a document
carries becomes the uid of what it names, and on the way in every uid becomes
whatever this device calls that document -- minting a slug for it if it is new
here.

**The outbox is built from the library's STATE, not from the journal's
wording.** The journal (sync.py) says which documents changed, keyed by slug.
A rename writes the new key and deletes the old one, so read literally the
journal would tell the server to delete an arrangement that was only renamed.
Here the question for each changed uid is simply whether a document with that
uid exists now: if it does, the server gets it as it is; if it does not, the
server gets a tombstone. A rename is then a set, and a delete is a delete.

**Applying never fights a local edit.** A document this device still owes the
server keeps its local value and goes up on the next push (the conflict rule
is "the same document edited on two devices while both were offline keeps one
device's whole edit"; design/FIREBASE.md §7 rule 3 wants it field by field,
which this build does not do -- ios/project.yml says so). A tombstone wins from
either side, because a deleted arrangement coming back is the worst thing sync
can do (§7 rule 4). A version never conflicts: it is immutable and named by an
id no other device can mint.

**An arrangement is never applied without its music.** The engine's rule is
that an arrangement holding no version must not exist, and a server can hand
over a score before the versions it names have arrived. Such a score is
DEFERRED: reported back, written nowhere, and offered again on the next pull.
"""

from __future__ import annotations

import shutil
from dataclasses import dataclass
from pathlib import Path

from . import ids, sync, workspace
from .sync import Change, JournalingRepository

#: The collections a record can belong to, as the server names them. Flat under
#: `libraries/{libraryId}/`: a version names its score in a field rather than
#: living under it, so "everything changed since" is one query per collection.
COLLECTIONS = ("pieces", "scores", "versions", "sources", "setlists", "books")

#: Local bookkeeping that means nothing on another device.
_LOCAL_ONLY = {"id", "slug", "rev"}


class SyncNotOn(RuntimeError):
    """Library sync was asked to do something before it was switched on."""


def journal_path() -> Path:
    return workspace.WORKSPACE / "sync.db"


def is_on() -> bool:
    """Whether this device has ever signed in to sync its library.

    The journal file's existence is the switch. A device that never signs in
    never has one and pays nothing (check_signed_out.py, check_sync.py); one
    that signed in and then out keeps journaling, so what it does while signed
    out still reaches the account when it signs back in.
    """
    return journal_path().exists()


def start() -> JournalingRepository:
    """Journal every write from now on. Idempotent."""
    repo = workspace._repo_singleton
    if isinstance(repo, JournalingRepository):
        return repo
    workspace.repository_factory = sync.journaling_factory(journal_path())
    workspace._reset_repo_for_testing()
    repo = workspace._repo()
    assert isinstance(repo, JournalingRepository)
    return repo


def _journal() -> JournalingRepository:
    repo = workspace._repo()
    if not isinstance(repo, JournalingRepository):
        raise SyncNotOn("library sync is not switched on on this device")
    return repo


def bind(account_uid: str) -> dict:
    """Tie this device's journal to an account.

    The same account again changes nothing. A DIFFERENT account -- somebody
    else signed in on this iPad -- owes that account the whole library, so
    everything becomes pending again: the other account's acknowledgements
    say nothing about what this one holds.
    """
    repo = start()
    previous = repo.meta("account")
    if previous != account_uid:
        repo.readopt()
        repo.set_meta("account", account_uid)
    return {"account": account_uid, "rebound": previous not in (None, account_uid),
            "pending": len(repo.pending())}


# -- the two names ----------------------------------------------------------

@dataclass
class _Index:
    """uid <-> slug for every live document, built once per call."""

    piece_slug: dict[str, str]
    piece_uid: dict[str, str]
    score_slug: dict[str, str]
    score_uid: dict[str, str]
    setlist_slug: dict[str, str]
    book_slug: dict[str, str]
    #: version id -> the slug of the score it belongs to
    version_score: dict[str, str]
    #: source uid -> (score slug, local source id)
    source_at: dict[str, tuple[str, str]]


def _index(repo) -> _Index:
    pieces = repo.list_pieces()
    scores = repo.list_scores(include_deleted=True)
    version_score: dict[str, str] = {}
    source_at: dict[str, tuple[str, str]] = {}
    for s in scores:
        for v in repo.list_versions(s["slug"]):
            version_score[v["id"]] = s["slug"]
        for src in repo.list_sources(s["slug"]):
            if src.get("uid"):
                source_at[src["uid"]] = (s["slug"], src["id"])
    return _Index(
        piece_slug={p["uid"]: p["slug"] for p in pieces if p.get("uid")},
        piece_uid={p["slug"]: p["uid"] for p in pieces if p.get("uid")},
        score_slug={s["uid"]: s["slug"] for s in scores if s.get("uid")},
        score_uid={s["slug"]: s["uid"] for s in scores if s.get("uid")},
        setlist_slug={d["uid"]: d["slug"] for d in repo.list_setlists() if d.get("uid")},
        book_slug={b["uid"]: b["slug"] for b in repo.list_books() if b.get("uid")},
        version_score=version_score,
        source_at=source_at,
    )


def _uids(slugs, table: dict[str, str]) -> list[str]:
    return [table[s] for s in slugs or [] if s in table]


def _slugs(uids, table: dict[str, str]) -> list[str]:
    return [table[u] for u in uids or [] if u in table]


# -- out --------------------------------------------------------------------

def _collection_of(key: str) -> str | None:
    parts = key.split("/")
    if parts[0] == "scores" and len(parts) == 4:
        return {"versions": "versions", "sources": "sources"}.get(parts[2])
    if parts[0] in ("scores", "pieces", "setlists", "books") and len(parts) == 2:
        return parts[0]
    return None        # library/self: the server's library document is Swift's


def _uid_of(change: Change, collection: str | None) -> str | None:
    """The server's name for a changed document.

    A version document carries no `uid` field: it is named by its id, which
    is already opaque (stage 0), so the journal's uid is empty and the key's
    last segment is the name.
    """
    if collection == "versions":
        return change.key.split("/")[3]
    return change.uid


def _owed(repo) -> set[tuple[str, str]]:
    return {(c, u) for ch in repo.pending()
            if (c := _collection_of(ch.key)) and (u := _uid_of(ch, c))}


def _file(path: Path, remote: str) -> dict:
    return {"path": str(path), "name": remote, "bytes": path.stat().st_size}


def _record(repo, index: _Index, collection: str, uid: str) -> dict:
    """The server's copy of one document, or a tombstone if it is gone."""
    doc: dict | None = None
    file: dict | None = None
    if collection == "pieces":
        slug = index.piece_slug.get(uid)
        if slug:
            doc = dict(repo.get_piece(slug))
            doc["order"] = _uids(doc.get("order"), index.score_uid)
    elif collection == "scores":
        slug = index.score_slug.get(uid)
        if slug:
            doc = dict(repo.get_score(slug))
            doc["piece"] = index.piece_uid.get(doc.get("piece")) if doc.get("piece") else None
    elif collection == "versions":
        slug = index.version_score.get(uid)
        if slug:
            doc = dict(repo.get_version(slug, uid))
            doc["score"] = index.score_uid[slug]
            path = workspace.score_dir(slug) / doc["file"]
            if path.exists():
                file = _file(path, f"versions/{uid}{path.suffix}")
    elif collection == "sources":
        at = index.source_at.get(uid)
        if at:
            slug, sid = at
            doc = dict(repo.get_source(slug, sid))
            doc["score"] = index.score_uid[slug]
            path = workspace.score_dir(slug) / doc["file"]
            if path.exists():
                file = _file(path, f"sources/{uid}{path.suffix}")
    elif collection == "setlists":
        slug = index.setlist_slug.get(uid)
        if slug:
            doc = dict(repo.get_setlist(slug))
            doc["scores"] = _uids(doc.get("scores"), index.score_uid)
            if "pieces" in doc:            # a set list from before 0.8, not yet expanded
                doc["pieces"] = _uids(doc.get("pieces"), index.piece_uid)
    elif collection == "books":
        slug = index.book_slug.get(uid)
        if slug:
            doc = dict(repo.get_book(slug))
            path = workspace.book_path(slug)
            if path.exists():
                file = _file(path, f"books/{uid}.pdf")
    if doc is None:
        return {"collection": collection, "uid": uid, "deleted": True,
                "fields": {}, "file": None}
    fields = {k: v for k, v in doc.items() if k not in _LOCAL_ONLY}
    if collection in ("versions", "sources"):
        fields["id"] = doc["id"]       # the local id is part of the history's labels
    return {"collection": collection, "uid": uid, "deleted": False,
            "fields": fields, "file": file}


#: Push order. A version goes up before the score that names it as `latest`,
#: so a device pulling mid-push finds the music before the pointer to it.
_PUSH_ORDER = {"versions": 0, "sources": 1, "books": 2, "pieces": 3, "scores": 4,
               "setlists": 5}


def outbox(limit: int = 200) -> dict:
    """What this device owes the server, as records, at most `limit` of them.

    Each record carries the journal entries it answers (`acks`), which go back
    to `acknowledge` once the server has it. `more` says whether anything was
    left for the next call.
    """
    repo = _journal()
    index = _index(repo)
    by_uid: dict[tuple[str, str], list[Change]] = {}
    silent: list[Change] = []          # owed to nobody: acknowledged unsent
    for change in repo.pending():
        collection = _collection_of(change.key)
        uid = _uid_of(change, collection)
        if collection is None or not uid:
            silent.append(change)
            continue
        by_uid.setdefault((collection, uid), []).append(change)
    if silent:
        repo.mark_synced(silent)
    ordered = sorted(by_uid.items(), key=lambda kv: (_PUSH_ORDER[kv[0][0]],
                                                     min(c.seq for c in kv[1])))
    records = []
    for (collection, uid), changes in ordered[:limit]:
        record = _record(repo, index, collection, uid)
        record["acks"] = [{"key": c.key, "seq": c.seq} for c in changes]
        records.append(record)
    return {"records": records, "more": len(ordered) > limit,
            "pending": len(ordered)}


def acknowledge(acks: list[dict]) -> dict:
    """The server holds these. Stop owing them."""
    repo = _journal()
    owed = {(c.key, c.seq): c for c in repo.pending()}
    done = [owed[(a["key"], int(a["seq"]))] for a in acks
            if (a["key"], int(a["seq"])) in owed]
    repo.mark_synced(done)
    repo.prune()
    return {"acknowledged": len(done), "pending": len(repo.pending())}


def status() -> dict:
    if not is_on():
        return {"on": False, "pending": 0, "account": None}
    repo = _journal()
    return {"on": True, "pending": len(_owed(repo)), "account": repo.meta("account")}


# -- in ---------------------------------------------------------------------

def _free_slug(base: str, taken) -> str:
    base = workspace.slugify(base)
    slug, n = base, 2
    while taken(slug):
        slug = f"{base}-{n}"
        n += 1
    return slug


def _local_fields(fields: dict) -> dict:
    return {k: v for k, v in fields.items() if k not in _LOCAL_ONLY}


def apply(records: list[dict]) -> dict:
    """Write what other devices did into this one.

    `records` are server records, each with `file_path` naming a downloaded
    copy of its bytes where it has any. Returns what was applied, what was
    skipped because this device still owes its own version, and what was
    DEFERRED -- a score whose music has not arrived, a version or book whose
    file has not been downloaded -- for the caller to offer again.
    """
    repo = _journal()
    before = max((c.seq for c in repo.pending()), default=0)
    owed = _owed(repo)
    applied = skipped = 0
    deferred: list[dict] = []
    by_collection: dict[str, list[dict]] = {c: [] for c in COLLECTIONS}
    tombstones: list[dict] = []
    for record in records:
        if record["collection"] not in by_collection:
            continue
        (tombstones if record.get("deleted") else by_collection[record["collection"]]).append(record)

    def dirty(record: dict) -> bool:
        return (record["collection"], record["uid"]) in owed

    # Deleted, here or anywhere. Whatever belongs to a deleted arrangement is
    # dropped rather than deferred: its arrangement is never coming.
    gone = repo.gone() | {t["uid"] for t in tombstones}
    repo.mark_gone([t["uid"] for t in tombstones])
    for c in ("versions", "sources"):
        by_collection[c] = [r for r in by_collection[c]
                            if r["uid"] not in gone
                            and r["fields"].get("score") not in gone]
    for c in ("pieces", "scores", "setlists", "books"):
        by_collection[c] = [r for r in by_collection[c] if r["uid"] not in gone]

    # 1. pieces, without their order: an order names arrangements that may not
    #    be here yet.
    index = _index(repo)
    for record in by_collection["pieces"]:
        if dirty(record):
            skipped += 1
            continue
        fields = _local_fields(record["fields"])
        slug = index.piece_slug.get(record["uid"])
        current = repo.get_piece(slug) if slug else None
        if slug is None:
            slug = _free_slug(fields.get("name") or "piece",
                              lambda s: repo.get_piece(s) is not None)
        doc = {**fields, "id": slug, "slug": slug, "uid": record["uid"],
               "order": (current or {}).get("order") or []}
        if current is not None and "rev" in current:
            doc["rev"] = current["rev"]
        repo.set_piece(slug, doc)
        applied += 1

    # 2. arrangements, each with its versions. A new one is written only once
    #    the version it names as `latest` is here or arriving with it.
    index = _index(repo)
    versions_for: dict[str, list[dict]] = {}
    for record in by_collection["versions"]:
        versions_for.setdefault(record["fields"].get("score"), []).append(record)

    def place_version(slug: str, record: dict) -> bool:
        vid = record["uid"]
        if repo.get_version(slug, vid) is not None:
            return True
        source = record.get("file_path")
        if not source or not Path(source).exists():
            return False
        fields = _local_fields(record["fields"])
        name = Path(fields.get("file") or f"{vid}.musicxml").name
        target = workspace.score_dir(slug) / name
        if target.exists():
            # Two devices both wrote a v004.musicxml, for different versions.
            target = workspace.score_dir(slug) / f"{vid}{Path(name).suffix}"
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        doc = {k: v for k, v in fields.items() if k != "score"}
        doc.update({"id": vid, "file": target.name})
        repo.add_version(slug, vid, int(doc.get("seq") or 0), doc)
        return True

    for record in by_collection["scores"]:
        if dirty(record):
            skipped += 1
            continue
        uid = record["uid"]
        fields = _local_fields(record["fields"])
        piece_uid = fields.get("piece")
        fields["piece"] = index.piece_slug.get(piece_uid) if piece_uid else None
        slug = index.score_slug.get(uid)
        mine = versions_for.pop(uid, [])
        if slug is None and fields.get("deleted_at"):
            # Deleted on the other device inside its undo window. Never here,
            # so there is nothing to undo: it is not made only to be swept.
            continue
        if slug is None:
            latest = fields.get("latest")
            if latest and not any(v["uid"] == latest and v.get("file_path") for v in mine):
                deferred.append(record)
                deferred.extend(mine)
                continue
            slug = _free_slug(fields.get("name") or "score",
                              lambda s: repo.get_score(s) is not None
                              or workspace.score_dir(s).exists())
            workspace.score_dir(slug).mkdir(parents=True, exist_ok=True)
        for v in sorted(mine, key=lambda r: int(r["fields"].get("seq") or 0)):
            if not place_version(slug, v):
                deferred.append(v)
        latest = fields.get("latest")
        if latest and repo.get_version(slug, latest) is None:
            # The pointer moved to music that has not arrived: keep the
            # arrangement as it is here and try the pointer again later.
            current = repo.get_score(slug)
            if current is None:
                deferred.append(record)
                continue
            fields["latest"] = current.get("latest")
            deferred.append(record)
        current = repo.get_score(slug) or {}
        doc = {**fields, "id": slug, "slug": slug, "uid": uid}
        if "rev" in current:
            doc["rev"] = current["rev"]
        repo.set_score(slug, doc)
        applied += 1

    # 3. versions of arrangements already here, not in this batch's scores.
    index = _index(repo)
    for score_uid, records_ in versions_for.items():
        slug = index.score_slug.get(score_uid)
        for v in records_:
            if slug is None or not place_version(slug, v):
                deferred.append(v)
            else:
                applied += 1

    # 4. sources. The local id (s01) is per device, so a clash takes the next.
    index = _index(repo)
    for record in by_collection["sources"]:
        if record["uid"] in index.source_at or dirty(record):
            continue
        slug = index.score_slug.get(record["fields"].get("score"))
        source = record.get("file_path")
        if slug is None or not source or not Path(source).exists():
            deferred.append(record)
            continue
        fields = _local_fields(record["fields"])
        sid = fields.get("id") or "s01"
        if repo.get_source(slug, sid) is not None:
            sid = f"s{len(repo.list_sources(slug)) + 1:02d}"
        rel = f"sources/{sid}{Path(fields.get('file') or '.musicxml').suffix}"
        target = workspace.score_dir(slug) / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        doc = {k: v for k, v in fields.items() if k != "score"}
        doc.update({"id": sid, "uid": record["uid"], "file": rel})
        repo.add_source(slug, sid, doc)
        applied += 1

    # 5. books. The bytes are the book: without them there is nothing to write.
    index = _index(repo)
    for record in by_collection["books"]:
        if dirty(record):
            skipped += 1
            continue
        fields = _local_fields(record["fields"])
        slug = index.book_slug.get(record["uid"])
        source = record.get("file_path")
        have_file = bool(source) and Path(source).exists()
        if slug is None:
            if not have_file:
                deferred.append(record)
                continue
            slug = _free_slug(fields.get("name") or "book",
                              lambda s: repo.get_book(s) is not None)
        if have_file:
            workspace.books_dir().mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, workspace.book_path(slug))
        current = repo.get_book(slug) or {}
        doc = {**fields, "id": slug, "slug": slug, "uid": record["uid"]}
        if "rev" in current:
            doc["rev"] = current["rev"]
        repo.set_book(slug, doc)
        applied += 1

    # 6. what points at arrangements, now that they are here.
    index = _index(repo)
    for record in by_collection["pieces"]:
        if dirty(record):
            continue
        slug = index.piece_slug.get(record["uid"])
        doc = repo.get_piece(slug) if slug else None
        if doc is not None:
            repo.set_piece(slug, {**doc, "order": _slugs(record["fields"].get("order"),
                                                         index.score_slug)})
    for record in by_collection["setlists"]:
        if dirty(record):
            skipped += 1
            continue
        fields = _local_fields(record["fields"])
        fields["scores"] = _slugs(fields.get("scores"), index.score_slug)
        fields.pop("pieces", None)     # expanded on the device that had it
        slug = index.setlist_slug.get(record["uid"])
        current = repo.get_setlist(slug) if slug else None
        if slug is None:
            slug = _free_slug(fields.get("name") or "setlist",
                              lambda s: repo.get_setlist(s) is not None)
        doc = {**fields, "id": slug, "slug": slug, "uid": record["uid"]}
        if current is not None and "rev" in current:
            doc["rev"] = current["rev"]
        repo.set_setlist(slug, doc)
        applied += 1

    # 7. deletes, from either side, whatever this device still owes.
    removed = 0
    for record in tombstones:
        index = _index(repo)
        c, uid = record["collection"], record["uid"]
        if c == "scores" and uid in index.score_slug:
            workspace.delete_score(index.score_slug[uid], immediate=True)
            removed += 1
        elif c == "pieces" and uid in index.piece_slug:
            slug = index.piece_slug[uid]
            for s in repo.list_scores(include_deleted=True):
                if s.get("piece") == slug:
                    repo.set_score(s["slug"], {**s, "piece": None})
            repo.delete_piece(slug)
            removed += 1
        elif c == "setlists" and uid in index.setlist_slug:
            repo.delete_setlist(index.setlist_slug[uid])
            removed += 1
        elif c == "books" and uid in index.book_slug:
            workspace.delete_book(index.book_slug[uid])
            removed += 1
        # A tombstoned version or source goes with its arrangement.

    # What was written here came FROM the server. It is not owed back to it.
    repo.mark_synced([c for c in repo.pending() if c.seq > before])
    repo.prune()
    workspace.rebuild_manifest()
    return {"applied": applied, "removed": removed, "skipped": skipped,
            "deferred": [{"collection": d["collection"], "uid": d["uid"]}
                         for d in deferred]}


__all__ = ["COLLECTIONS", "SyncNotOn", "acknowledge", "apply", "bind", "is_on",
           "journal_path", "outbox", "start", "status"]
