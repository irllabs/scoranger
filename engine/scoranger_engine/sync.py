"""What this device still owes a server, for a device that may never have one.

Sign-in is optional and the local database stays authoritative (design/
FIREBASE.md §2). So this module is a DECORATOR, not a second store: it wraps
`SqliteRepository` through the `repository_factory` hook that stage 0 left in
`workspace.py`, and it is installed only when sync is switched on. Nothing in
`workspace.py` or in the ops knows it exists, and a signed-out device never
constructs it -- no journal file, no `rev` on any document, no cost.

It records two things.

**A `rev` on every document it writes.** Bumped when the document actually
changes and left alone when it does not, because the engine re-saves documents
that nothing edited and a rev that moved anyway would push the whole library.
`rev` against the last acknowledged rev is how the app answers "is this row
still waiting", after a crash as well as during a session.

**An append-only journal of what changed**, keyed by document, which the Swift
sync layer walks with a cursor. §4.1 asked for this and stage 0 deliberately
left it out until something consumed it.

The journal earns its place on deletes, and it is worth being precise about
why, because everything else in it could be recomputed by scanning documents.
`delete_score` marks a row and `sweep()` reclaims it thirty seconds later. Once
that row is gone there is nothing left in the library that remembers it existed
-- so a device that was offline when it happened would push the score back up
on reconnect, and a deleted arrangement returning from the dead is the most
alarming sync bug a user can meet (§7 rule 4). The journal is where the
tombstone lives after the row it describes has gone, and it carries the `uid`,
which is the only name a server ever knew that document by.

The journal lives in its OWN sqlite file (`workspace/sync.db`), not in
`scoranger.db`. Sync state is not library state: deleting it re-pushes
everything and loses nothing, and a device that never signs in never grows the
file at all.
"""

import sqlite3
import threading
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from .db import Repository, SqliteRepository


@dataclass(frozen=True)
class Change:
    """One document the server has not seen in its current state.

    `key` is the document's path in the collections of §4.2 --
    `scores/{slug}`, `scores/{slug}/versions/{versionId}` -- which is what the
    sync layer addresses, and `uid` is what the server keys on. Both, because
    the slug is how this device finds the document and the uid is how the
    server finds it, and the whole point of stage 0 is that those differ.
    """

    key: str
    op: str                 # "set" or "delete"
    uid: str | None
    rev: int | None
    at: str
    seq: int


def _now() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def _same_apart_from_rev(a: dict, b: dict) -> bool:
    return {k: v for k, v in a.items() if k != "rev"} == {k: v for k, v in b.items() if k != "rev"}


class JournalingRepository:
    """A `Repository` that also records what changed. Conforms structurally.

    Every read forwards untouched. Every write forwards a document carrying a
    `rev`, and appends a journal row unless the write changed nothing.
    """

    def __init__(self, inner: Repository, journal_path: Path):
        self._inner = inner
        self._lock = threading.Lock()
        journal_path.parent.mkdir(parents=True, exist_ok=True)
        self._conn = sqlite3.connect(str(journal_path), check_same_thread=False)
        with self._lock:
            self._conn.execute(
                "CREATE TABLE IF NOT EXISTS changes ("
                " seq INTEGER PRIMARY KEY AUTOINCREMENT,"
                " key TEXT NOT NULL, op TEXT NOT NULL, uid TEXT, rev INTEGER,"
                " at TEXT NOT NULL)")
            self._conn.execute(
                "CREATE INDEX IF NOT EXISTS changes_key ON changes (key)")
            self._conn.execute(
                "CREATE TABLE IF NOT EXISTS synced ("
                " key TEXT PRIMARY KEY, seq INTEGER NOT NULL, rev INTEGER,"
                " at TEXT NOT NULL)")
            self._conn.execute(
                "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)")
            # Every uid ever deleted here, from either side. The journal row
            # saying so is pruned once the server has it; this is what still
            # answers "is that arrangement gone" when a version of it turns up
            # later (librarysync.apply).
            self._conn.execute("CREATE TABLE IF NOT EXISTS gone (uid TEXT PRIMARY KEY)")
            self._conn.commit()
        self._adopt()

    # -- adoption ----------------------------------------------------------

    def _adopt(self) -> None:
        """Owe the server every document the first time a journal meets a library.

        This is what "signing in does not migrate anything" means in code
        (design/FIREBASE.md §9.2). The library already existed, possibly for
        months, with no journal watching it; the journal cannot know what of it
        the server has, so the honest answer is all of it.

        It is also what makes losing `sync.db` a re-push rather than a data
        loss, and there is no third case to tell apart: a journal that has been
        acknowledged and pruned still holds its `synced` cursor, so "nothing
        recorded, nothing acknowledged" means "never seen this library".
        """
        row = self._conn.execute("SELECT value FROM meta WHERE key = 'adopted'").fetchone()
        if row:
            return
        library = self._inner.get_library()
        if library:
            self._record("library/self", "set", library.get("uid"), library.get("rev"))
        for doc in self._inner.list_scores(include_deleted=True):
            slug = doc["slug"]
            self._record(f"scores/{slug}", "set", doc.get("uid"), doc.get("rev"))
            for v in self._inner.list_versions(slug):
                self._record(f"scores/{slug}/versions/{v['id']}", "set",
                             v.get("uid") or v.get("id"), v.get("rev"))
            for src in self._inner.list_sources(slug):
                self._record(f"scores/{slug}/sources/{src['id']}", "set",
                             src.get("uid"), src.get("rev"))
        for collection, docs in (("pieces", self._inner.list_pieces()),
                                 ("setlists", self._inner.list_setlists()),
                                 ("books", self._inner.list_books())):
            for doc in docs:
                self._record(f"{collection}/{doc['slug']}", "set",
                             doc.get("uid"), doc.get("rev"))
        with self._lock:
            self._conn.execute(
                "INSERT INTO meta (key, value) VALUES ('adopted', ?)", (_now(),))
            self._conn.commit()

    def readopt(self) -> None:
        """Owe everything again, as if this journal had never met the library.

        For a device whose journal was acknowledged by a DIFFERENT account:
        those acknowledgements say nothing about what the new one holds.
        """
        with self._lock:
            self._conn.execute("DELETE FROM changes")
            self._conn.execute("DELETE FROM synced")
            self._conn.execute("DELETE FROM meta WHERE key = 'adopted'")
            self._conn.commit()
        self._adopt()

    def meta(self, key: str) -> str | None:
        row = self._conn.execute("SELECT value FROM meta WHERE key = ?", (key,)).fetchone()
        return row[0] if row else None

    def set_meta(self, key: str, value: str) -> None:
        with self._lock:
            self._conn.execute(
                "INSERT INTO meta (key, value) VALUES (?, ?)"
                " ON CONFLICT(key) DO UPDATE SET value = excluded.value", (key, value))
            self._conn.commit()

    # -- the journal -------------------------------------------------------

    def _record(self, key: str, op: str, uid: str | None, rev: int | None) -> None:
        with self._lock:
            self._conn.execute(
                "INSERT INTO changes (key, op, uid, rev, at) VALUES (?, ?, ?, ?, ?)",
                (key, op, uid, rev, _now()))
            self._conn.commit()

    def pending(self) -> list[Change]:
        """Every document the server has not seen in its current state.

        Collapsed to the LAST thing that happened to each document, which is
        what makes a delete beat the edits before it and an offline morning's
        work one write per document rather than one per keystroke.
        """
        rows = self._conn.execute(
            "SELECT c.seq, c.key, c.op, c.uid, c.rev, c.at FROM changes c"
            " JOIN (SELECT key, MAX(seq) AS top FROM changes GROUP BY key) last"
            "   ON last.key = c.key AND last.top = c.seq"
            " LEFT JOIN synced s ON s.key = c.key"
            " WHERE s.seq IS NULL OR c.seq > s.seq"
            " ORDER BY c.seq").fetchall()
        return [Change(key=r[1], op=r[2], uid=r[3], rev=r[4], at=r[5], seq=r[0]) for r in rows]

    def mark_synced(self, changes: list[Change]) -> None:
        """Record that the server now holds these documents as described."""
        with self._lock:
            for c in changes:
                self._conn.execute(
                    "INSERT INTO synced (key, seq, rev, at) VALUES (?, ?, ?, ?)"
                    " ON CONFLICT(key) DO UPDATE SET seq = MAX(seq, excluded.seq),"
                    " rev = excluded.rev, at = excluded.at",
                    (c.key, c.seq, c.rev, _now()))
            self._conn.commit()

    def prune(self) -> int:
        """Drop journal rows the server has acknowledged. Returns how many went.

        The `synced` cursor stays: it is what still answers "is this document
        waiting" once the rows describing it are gone.
        """
        with self._lock:
            cur = self._conn.execute(
                "DELETE FROM changes WHERE seq <= COALESCE("
                " (SELECT seq FROM synced WHERE synced.key = changes.key), -1)")
            self._conn.commit()
            return cur.rowcount

    def synced_rev(self, key: str) -> int | None:
        row = self._conn.execute("SELECT rev FROM synced WHERE key = ?", (key,)).fetchone()
        return row[0] if row else None

    # -- writes ------------------------------------------------------------

    def _write(self, key: str, doc: dict, previous: dict | None, setter) -> None:
        if previous is not None and _same_apart_from_rev(previous, doc):
            # Nothing changed. Keep the rev the document already had, so an
            # idle re-save is not a push.
            if "rev" in previous:
                doc = {**doc, "rev": previous["rev"]}
            setter(doc)
            return
        rev = int((previous or {}).get("rev") or 0) + 1
        doc = {**doc, "rev": rev}
        setter(doc)
        self._record(key, "set", doc.get("uid"), rev)

    def _erase(self, key: str, previous: dict | None, deleter) -> None:
        deleter()
        uid = (previous or {}).get("uid")
        self._record(key, "delete", uid, None)
        if uid:
            self.mark_gone([uid])

    def mark_gone(self, uids: list[str]) -> None:
        with self._lock:
            self._conn.executemany("INSERT OR IGNORE INTO gone (uid) VALUES (?)",
                                   [(u,) for u in uids])
            self._conn.commit()

    def gone(self) -> set[str]:
        return {r[0] for r in self._conn.execute("SELECT uid FROM gone")}

    # -- scores ------------------------------------------------------------

    def get_library(self) -> dict | None:
        return self._inner.get_library()

    def set_library(self, doc: dict) -> None:
        # One document, one key. It is what a share and a push address the
        # device by (design/FIREBASE.md §9.2), so it owes the server a rev like
        # anything else.
        self._write("library/self", doc, self._inner.get_library(),
                    self._inner.set_library)

    def set_score(self, score_id: str, doc: dict) -> None:
        self._write(f"scores/{score_id}", doc, self._inner.get_score(score_id),
                    lambda d: self._inner.set_score(score_id, d))

    def get_score(self, score_id: str, include_deleted: bool = True) -> dict | None:
        return self._inner.get_score(score_id, include_deleted)

    def list_scores(self, include_deleted: bool = False) -> list[dict]:
        return self._inner.list_scores(include_deleted)

    def count_scores(self) -> int:
        return self._inner.count_scores()

    def delete_score(self, score_id: str) -> None:
        # The versions and sources go with it in the store. They are NOT
        # journaled one by one: the server deletes a tombstoned score's
        # subcollections, and a hundred tombstones for one deleted arrangement
        # would be a hundred writes saying what one already says.
        self._erase(f"scores/{score_id}", self._inner.get_score(score_id),
                    lambda: self._inner.delete_score(score_id))

    # -- pieces ------------------------------------------------------------

    def set_piece(self, piece_id: str, doc: dict) -> None:
        self._write(f"pieces/{piece_id}", doc, self._inner.get_piece(piece_id),
                    lambda d: self._inner.set_piece(piece_id, d))

    def get_piece(self, piece_id: str) -> dict | None:
        return self._inner.get_piece(piece_id)

    def list_pieces(self) -> list[dict]:
        return self._inner.list_pieces()

    def delete_piece(self, piece_id: str) -> None:
        self._erase(f"pieces/{piece_id}", self._inner.get_piece(piece_id),
                    lambda: self._inner.delete_piece(piece_id))

    # -- setlists ----------------------------------------------------------

    def set_setlist(self, setlist_id: str, doc: dict) -> None:
        self._write(f"setlists/{setlist_id}", doc, self._inner.get_setlist(setlist_id),
                    lambda d: self._inner.set_setlist(setlist_id, d))

    def get_setlist(self, setlist_id: str) -> dict | None:
        return self._inner.get_setlist(setlist_id)

    def list_setlists(self) -> list[dict]:
        return self._inner.list_setlists()

    def delete_setlist(self, setlist_id: str) -> None:
        self._erase(f"setlists/{setlist_id}", self._inner.get_setlist(setlist_id),
                    lambda: self._inner.delete_setlist(setlist_id))

    # -- books -------------------------------------------------------------

    def set_book(self, book_id: str, doc: dict) -> None:
        self._write(f"books/{book_id}", doc, self._inner.get_book(book_id),
                    lambda d: self._inner.set_book(book_id, d))

    def get_book(self, book_id: str) -> dict | None:
        return self._inner.get_book(book_id)

    def list_books(self) -> list[dict]:
        return self._inner.list_books()

    def delete_book(self, book_id: str) -> None:
        self._erase(f"books/{book_id}", self._inner.get_book(book_id),
                    lambda: self._inner.delete_book(book_id))

    # -- sources and versions (subcollections of a score) ------------------

    def add_source(self, score_id: str, source_id: str, doc: dict) -> None:
        self._write(f"scores/{score_id}/sources/{source_id}", doc,
                    self._inner.get_source(score_id, source_id),
                    lambda d: self._inner.add_source(score_id, source_id, d))

    def get_source(self, score_id: str, source_id: str) -> dict | None:
        return self._inner.get_source(score_id, source_id)

    def list_sources(self, score_id: str) -> list[dict]:
        return self._inner.list_sources(score_id)

    def add_version(self, score_id: str, version_id: str, seq: int, doc: dict) -> None:
        self._write(f"scores/{score_id}/versions/{version_id}", doc,
                    self._inner.get_version(score_id, version_id),
                    lambda d: self._inner.add_version(score_id, version_id, seq, d))

    def get_version(self, score_id: str, version_id: str) -> dict | None:
        return self._inner.get_version(score_id, version_id)

    def list_versions(self, score_id: str) -> list[dict]:
        return self._inner.list_versions(score_id)

    def delete_version(self, score_id: str, version_id: str) -> None:
        self._erase(f"scores/{score_id}/versions/{version_id}",
                    self._inner.get_version(score_id, version_id),
                    lambda: self._inner.delete_version(score_id, version_id))


def journaling_factory(journal_path: Path) -> Callable[[Path], Repository]:
    """A `workspace.repository_factory` that journals. Install it at sign-in.

    Before the first `workspace._repo()` call, since the repository is a
    singleton:

        workspace.repository_factory = sync.journaling_factory(path)
        workspace._reset_repo_for_testing()   # if one is already open
    """

    def make(db_path: Path) -> Repository:
        return JournalingRepository(SqliteRepository(db_path), Path(journal_path))

    return make


def is_journaling(repo: Repository) -> bool:
    return isinstance(repo, JournalingRepository)


__all__ = ["Change", "JournalingRepository", "journaling_factory", "is_journaling"]
