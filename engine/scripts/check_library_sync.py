#!/usr/bin/env python3
"""Two devices, one account, one library (0.16.0).

Ali: "if i signin as google on my ipad and have a whole bunch of
pieces/setlists/books, when i sign in with google on my iphone, I expect to
see all the same pieces/setlists/books."

This drives the REAL engine on two workspaces, as two devices, through an
in-memory server that does what Firestore and Cloud Storage do for the app:
keep one record per (collection, uid), stamp each write with a server clock,
and hand back everything stamped after a cursor. The Swift sync layer
(LibrarySync) is that loop over the network; this is the same loop with the
network taken out, so what the engine promises is checked in seconds.

What has to hold:

  1. a library pushed from one device arrives WHOLE on the other: every
     arrangement with every version's exact bytes, its piece, its sources,
     every set list in its order, every book
  2. edits come back the other way -- a rename, a new version, a reorder
  3. slugs are local and uids are not: two devices that each have a "Reel"
     keep two arrangements, and a rename on one device is a rename on the
     other, never a delete-and-add
  4. a delete stays deleted -- a device that never saw the delete cannot push
     the arrangement back up (design/FIREBASE.md §7 rule 4)
  5. merging: a device that already had a library keeps it and adds the
     account's; the account gains the device's (Ali, 2026-09-26)
  6. two devices adding versions to one arrangement offline both keep both
  7. pulling what you already have changes nothing and owes nothing
  8. an arrangement whose music has not arrived yet is DEFERRED, not written
     empty, and arrives whole when it has

Run: engine/.venv/bin/python engine/scripts/check_library_sync.py
"""
import hashlib
import os
import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

FAILURES: list[str] = []


def check(condition, message):
    print(f"    {'ok  ' if condition else 'FAIL'} {message}")
    if not condition:
        FAILURES.append(message)
    return condition


def sha(path: Path) -> str:
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


class Server:
    """Firestore plus Storage, as the sync loop sees them."""

    def __init__(self):
        self.clock = 0
        self.docs: dict[tuple[str, str], dict] = {}
        self.files = Path(tempfile.mkdtemp())

    def write(self, record: dict, device: str) -> None:
        self.clock += 1
        stored = {"collection": record["collection"], "uid": record["uid"],
                  "deleted": record["deleted"], "fields": dict(record["fields"]),
                  "device": device, "stamp": self.clock, "file": None}
        if record.get("file"):
            name = record["file"]["name"]
            (self.files / name).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(record["file"]["path"], self.files / name)
            stored["file"] = name
        self.docs[(record["collection"], record["uid"])] = stored

    def since(self, cursor: int) -> list[dict]:
        return sorted((d for d in self.docs.values() if d["stamp"] > cursor),
                      key=lambda d: d["stamp"])


class Device:
    def __init__(self, name: str):
        self.name = name
        self.root = Path(tempfile.mkdtemp(prefix=f"{name}-"))
        self.cursor = 0
        self.held: list[dict] = []

    def use(self):
        from scoranger_engine import workspace
        from scoranger_engine.db import SqliteRepository

        os.environ["SCORANGER_WORKSPACE"] = str(self.root)
        workspace.WORKSPACE = self.root
        workspace.repository_factory = SqliteRepository
        workspace._reset_repo_for_testing()
        from scoranger_engine import librarysync
        if librarysync.is_on():
            librarysync.start()
        return workspace

    def sign_in(self, account: str) -> None:
        self.use()
        from scoranger_engine import librarysync
        librarysync.bind(account)

    def push(self, server: Server) -> int:
        self.use()
        from scoranger_engine import librarysync
        sent = 0
        while True:
            box = librarysync.outbox(limit=50)
            for record in box["records"]:
                server.write(record, self.name)
            librarysync.acknowledge([a for r in box["records"] for a in r["acks"]])
            sent += len(box["records"])
            if not box["more"]:
                return sent

    def pull(self, server: Server) -> dict:
        self.use()
        from scoranger_engine import librarysync
        fresh = [d for d in server.since(self.cursor) if d["device"] != self.name]
        if fresh:
            self.cursor = max(d["stamp"] for d in server.since(self.cursor))
        wanted = {(d["collection"], d["uid"]): d for d in self.held}
        wanted.update({(d["collection"], d["uid"]): d for d in fresh})
        records = []
        for d in wanted.values():
            record = dict(d)
            record["file_path"] = str(server.files / d["file"]) if d.get("file") else None
            records.append(record)
        result = librarysync.apply(records)
        held = {(x["collection"], x["uid"]) for x in result["deferred"]}
        self.held = [d for d in wanted.values() if (d["collection"], d["uid"]) in held]
        return result

    def view(self) -> dict:
        """The library as a person sees it, named by uid -- never by slug."""
        workspace = self.use()
        repo = workspace._repo()
        pieces = {p["uid"]: p for p in repo.list_pieces()}
        piece_uid = {p["slug"]: p["uid"] for p in pieces.values()}
        scores = {s["uid"]: s for s in repo.list_scores()}
        score_uid = {s["slug"]: s["uid"] for s in scores.values()}
        out = {"scores": {}, "pieces": {}, "setlists": {}, "books": {}}
        for uid, s in scores.items():
            versions = {v["id"]: sha(workspace.score_dir(s["slug"]) / v["file"])
                        for v in repo.list_versions(s["slug"])}
            sources = {src["uid"]: sha(workspace.score_dir(s["slug"]) / src["file"])
                       for src in repo.list_sources(s["slug"])}
            out["scores"][uid] = {"name": s["name"], "title": s.get("title"),
                                  "piece": piece_uid.get(s.get("piece")),
                                  "latest": s.get("latest"), "versions": versions,
                                  "sources": sources}
        for uid, p in pieces.items():
            out["pieces"][uid] = {"name": p["name"],
                                  "order": [score_uid[x] for x in p.get("order") or []
                                            if x in score_uid]}
        for d in repo.list_setlists():
            out["setlists"][d["uid"]] = {"name": d["name"],
                                         "scores": [score_uid[x] for x in d.get("scores") or []
                                                    if x in score_uid]}
        for b in repo.list_books():
            out["books"][b["uid"]] = {"name": b["name"], "pages": b.get("pages"),
                                      "file": sha(workspace.book_path(b["slug"]))}
        return out

    def pending(self) -> int:
        self.use()
        from scoranger_engine import librarysync
        return librarysync.status()["pending"]


def a_pdf(pages: int) -> Path:
    from pypdf import PdfWriter
    path = Path(tempfile.mkdtemp()) / "book.pdf"
    writer = PdfWriter()
    for _ in range(pages):
        writer.add_blank_page(width=612, height=792)
    with open(path, "wb") as f:
        writer.write(f)
    return path


def transposed(workspace, slug: str, interval: str):
    from music21 import converter
    score = converter.parse(str(workspace.resolve_notation_path(slug)), forceSource=True)
    return score.transpose(interval)


def build_a_library(ipad: Device) -> dict:
    """What Ali has on his iPad: pieces, arrangements with history, a set list,
    a book, a source."""
    import fixtures
    ws = ipad.use()
    jig, _ = ws.create_score("Morrison's Jig", fixtures.jig(bars=4))
    ws.assign_score_to_piece(jig, "Morrison's Jig")
    ws.add_version(jig, transposed(ws, jig, "M2"), "transpose", {"interval": "M2"})
    reel, _ = ws.create_score("Reel", fixtures.jig(bars=4))
    ws.assign_score_to_piece(reel, "Morrison's Jig")
    ws.add_source(jig, fixtures.jig(bars=4), "The Session setting", "thesession.org")
    ws.add_score_to_setlist("Friday", jig)
    ws.add_score_to_setlist("Friday", reel)
    book, _ = ws.create_book("Session Tunebook", a_pdf(3))
    return {"jig": jig, "reel": reel, "book": book}


def the_library_arrives_whole() -> tuple[Server, Device, Device]:
    print("\n1. a library pushed from one device arrives whole on the other")
    server, ipad, iphone = Server(), Device("ipad"), Device("iphone")
    build_a_library(ipad)
    ipad.sign_in("ali")
    sent = ipad.push(server)
    check(sent >= 9, f"the iPad sent its whole library ({sent} records)")
    check(ipad.pending() == 0, "and owes nothing after the server has it")
    iphone.sign_in("ali")
    result = iphone.pull(server)
    check(not result["deferred"], f"nothing deferred: {result['deferred']}")
    a, b = ipad.view(), iphone.view()
    check(a == b, "the iPhone's library is the iPad's, arrangement by arrangement")
    check(len(b["scores"]) == 2 and len(b["pieces"]) == 1 and len(b["setlists"]) == 1
          and len(b["books"]) == 1, "two arrangements, one piece, one set list, one book")
    jig = next(s for s in b["scores"].values() if s["name"] == "Morrison's Jig")
    check(len(jig["versions"]) == 2, "with the whole version history (2 versions)")
    check(len(jig["sources"]) == 1, "and its source")
    setlist = next(iter(b["setlists"].values()))
    check([b["scores"][u]["name"] for u in setlist["scores"]] == ["Morrison's Jig", "Reel"],
          "the set list in its running order")
    check(iphone.pending() == 0, "applying what the server sent owes the server nothing")
    return server, ipad, iphone


def edits_come_back(server: Server, ipad: Device, iphone: Device) -> None:
    print("\n2. edits come back the other way")
    ws = iphone.use()
    repo = ws._repo()
    reel = next(s for s in repo.list_scores() if s["name"] == "Reel")["slug"]
    jig = next(s for s in repo.list_scores() if s["name"] == "Morrison's Jig")["slug"]
    ws.rename_score(reel, "The Silver Spear")
    ws.add_version(jig, transposed(ws, jig, "-P4"), "transpose", {"interval": "-P4"})
    friday = repo.list_setlists()[0]["slug"]
    ws.set_setlist_order(friday, [reel, jig])
    # A copy adopted from a shared set list names its entry, and the account's
    # other device has to learn that with the copy, or it adopts the entry a
    # second time (0.18.0).
    ws.link_shared_entry(jig, "entry-from-the-band")
    iphone.push(server)
    ipad.pull(server)
    linked = [s.get("sharedEntry") for s in ipad.use()._repo().list_scores()
              if s["name"] == "Morrison's Jig"]
    check(linked == ["entry-from-the-band"],
          f"the shared entry an arrangement is a copy of travels with it: {linked}")
    a, b = ipad.view(), iphone.view()
    check(a == b, "the iPad now matches the iPhone")
    names = sorted(s["name"] for s in a["scores"].values())
    check(names == ["Morrison's Jig", "The Silver Spear"],
          f"the rename arrived as a rename, not a delete and an add: {names}")
    jig_view = next(s for s in a["scores"].values() if s["name"] == "Morrison's Jig")
    check(len(jig_view["versions"]) == 3, "the new version is in the iPad's history")
    setlist = next(iter(a["setlists"].values()))
    check([a["scores"][u]["name"] for u in setlist["scores"]]
          == ["The Silver Spear", "Morrison's Jig"], "and the set list's new order")


def a_delete_stays_deleted(server: Server, ipad: Device, iphone: Device) -> None:
    print("\n3. a delete stays deleted")
    ws = ipad.use()
    repo = ws._repo()
    spear = next(s for s in repo.list_scores() if s["name"] == "The Silver Spear")
    ws.delete_score(spear["slug"])
    ws.sweep(now="2999-01-01T00:00:00+00:00")     # the undo window has long passed
    book = repo.list_books()[0]["slug"]
    ws.delete_book(book)
    ipad.push(server)
    # The iPhone has been offline, and does something unrelated first.
    ws = iphone.use()
    jig = next(s for s in ws._repo().list_scores() if s["name"] == "Morrison's Jig")["slug"]
    ws.rename_score(jig, "Morrison's")
    iphone.push(server)
    iphone.pull(server)
    names = sorted(s["name"] for s in iphone.view()["scores"].values())
    check(names == ["Morrison's"], f"the deleted arrangement is gone from the iPhone: {names}")
    check(not iphone.view()["books"], "and so is the deleted book")
    iphone.push(server)
    ipad.pull(server)
    names = sorted(s["name"] for s in ipad.view()["scores"].values())
    check(names == ["Morrison's"],
          f"the iPhone pushed nothing that brings it back: {names}")
    check(ipad.view() == iphone.view(), "and the two agree")


def two_libraries_merge(server: Server) -> tuple[Device, Device]:
    print("\n4. a device that already had a library merges it into the account")
    import fixtures
    phone = Device("phone")
    ws = phone.use()
    own, _ = ws.create_score("Reel", fixtures.jig(bars=4))       # same NAME as the iPad's
    ws.add_score_to_setlist("Practice", own)
    phone.sign_in("ali")
    phone.pull(server)
    phone.push(server)
    tablet = Device("tablet")
    tablet.sign_in("ali")
    tablet.pull(server)
    names = sorted(s["name"] for s in phone.view()["scores"].values())
    check("Reel" in names and "Morrison's" in names,
          f"the phone kept its own and gained the account's: {names}")
    check(phone.view() == tablet.view(), "a third device sees the union")
    slugs = sorted(s["slug"] for s in phone.use()._repo().list_scores())
    check(len(slugs) == len(set(slugs)), f"no slug collides on the phone: {slugs}")
    return phone, tablet


def offline_versions_both_survive(server: Server, phone: Device, tablet: Device) -> None:
    print("\n5. two devices adding versions offline both keep both")
    start = len(next(s for s in phone.view()["scores"].values()
                     if s["name"] == "Morrison's")["versions"])
    for device, interval in ((phone, "m3"), (tablet, "M6")):
        ws = device.use()
        slug = next(s for s in ws._repo().list_scores() if s["name"] == "Morrison's")["slug"]
        ws.add_version(slug, transposed(ws, slug, interval), "transpose",
                       {"interval": interval})
    phone.push(server)
    tablet.push(server)
    phone.pull(server)
    tablet.pull(server)
    history = next(s for s in phone.view()["scores"].values()
                   if s["name"] == "Morrison's")["versions"]
    other = next(s for s in tablet.view()["scores"].values()
                 if s["name"] == "Morrison's")["versions"]
    check(history == other and len(history) == start + 2,
          f"both devices hold both new versions and every old one, byte for byte "
          f"({start} + 2 = {len(history)} / {len(other)})")


def pulling_again_changes_nothing(server: Server, phone: Device) -> None:
    print("\n6. pulling what you already have changes nothing")
    before = phone.view()
    phone.cursor = 0                         # everything again, from the start
    result = phone.pull(server)
    check(phone.view() == before, "the library is unchanged")
    check(phone.pending() == 0, "and nothing is owed back")
    check(not result["deferred"], "and nothing was deferred")


def music_before_pointer() -> None:
    print("\n7. an arrangement whose music has not arrived is deferred, not written empty")
    import fixtures
    server, a, b = Server(), Device("a"), Device("b")
    ws = a.use()
    ws.create_score("Drowsy Maggie", fixtures.jig(bars=4))
    a.sign_in("ali")
    a.push(server)
    # The pulling device sees the arrangement but not yet its version.
    versions = {k: v for k, v in server.docs.items() if k[0] == "versions"}
    for k in versions:
        del server.docs[k]
    b.sign_in("ali")
    result = b.pull(server)
    check(any(d["collection"] == "scores" for d in result["deferred"]),
          "the arrangement is deferred")
    check(not b.view()["scores"], "and nothing half-made is in the library")
    for k, v in versions.items():
        server.docs[k] = {**v, "stamp": server.clock + 1}
        server.clock += 1
    b.pull(server)
    check(len(b.view()["scores"]) == 1 and b.view() == a.view(),
          "once the music is there, it arrives whole")


def an_arrangement_deleted_in_its_undo_window_is_not_made_elsewhere() -> None:
    print("\n9. an arrangement deleted inside its undo window is not made on the other device")
    import fixtures
    server, a, b = Server(), Device("a2"), Device("b2")
    a.sign_in("ali")
    ws = a.use()
    kept, _ = ws.create_score("Kept", fixtures.jig(bars=4))
    gone, _ = ws.create_score("Self Test", fixtures.jig(bars=4))
    ws.delete_score(gone)                      # marked, not yet swept
    a.push(server)
    b.sign_in("ali")
    b.pull(server)
    ws = b.use()
    rows = [s["name"] for s in ws._repo().list_scores(include_deleted=True)]
    check(rows == ["Kept"], f"only the kept arrangement exists on the other device: {rows}")
    check(not (b.root / gone).exists(), "and no folder was made for the other")


def a_different_account_is_owed_everything() -> None:
    print("\n8. another account on the same device is owed the whole library")
    import fixtures
    server, d = Server(), Device("shared-ipad")
    ws = d.use()
    ws.create_score("Kesh", fixtures.jig(bars=4))
    d.sign_in("ali")
    d.push(server)
    check(d.pending() == 0, "Ali's account has everything")
    d.sign_in("echo")
    check(d.pending() > 0, "a different account is owed it all again")
    d.sign_in("echo")
    check(d.pending() > 0, "signing the same account in twice does not reset twice")


def main() -> int:
    server, ipad, iphone = the_library_arrives_whole()
    edits_come_back(server, ipad, iphone)
    a_delete_stays_deleted(server, ipad, iphone)
    phone, tablet = two_libraries_merge(server)
    offline_versions_both_survive(server, phone, tablet)
    pulling_again_changes_nothing(server, phone)
    music_before_pointer()
    a_different_account_is_owed_everything()
    an_arrangement_deleted_in_its_undo_window_is_not_made_elsewhere()
    print()
    if FAILURES:
        print(f"FAILED: {len(FAILURES)} check(s)")
        for f in FAILURES:
            print(f"  - {f}")
        return 1
    print("OK: two devices signed in to one account hold one library")
    return 0


if __name__ == "__main__":
    sys.exit(main())
