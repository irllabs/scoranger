"""The Swift<->Python boundary: one function, JSON in, JSON out.

Swift calls handle('{"op": ..., "args": {...}}'). The first call must be
"configure" with the workspace path (the app's Documents/workspace). Every
mutating op creates an immutable version, exactly like the desktop CLI.
"""

import json
import os
import shutil
import sys
import traceback

_ready = False
ops = None
workspace = None


def _ensure_engine():
    global _ready, ops, workspace
    if not _ready:
        from scoranger_engine import ops as _ops
        from scoranger_engine import workspace as _ws
        ops, workspace = _ops, _ws
        _ready = True


def _load(slug, version=None):
    from music21 import converter
    # resolve_notation_path: a PDF arrangement is refused here with a sentence
    # a reader can act on, rather than a music21 parse error
    return converter.parse(str(workspace.resolve_notation_path(slug, version)),
                           forceSource=True)


def _mutate(slug, op, args, fn):
    score = _load(slug)
    details = fn(score)
    entry = workspace.add_version(slug, score, op, args)
    # id AND label: the id is what anything addressing this version must use,
    # the label is the only one of the two a person can read in a chat step
    return {"new_version": entry["id"],
            "new_version_label": workspace.version_label(entry),
            "details": details}


def _part(score, name):
    return ops.find_parts(score, [name])[0]


def _place_element(a, op, duplicate):
    """move-element and duplicate-element: one body, because they place things
    by identical rules and two bodies would drift apart.

    The destination is a tapped BAR plus an offset stepper inside it -- this
    app has no drag. Spanners are refused inside ops.move_element, which is
    where the reason is written.
    """
    score = _load(a["score"], None)
    args = {"part": a["part"], "kind": a["kind"], "measure": int(a["measure"]),
            "ordinal": int(a.get("ordinal") or 0),
            "to_measure": None if a.get("to_measure") is None else int(a["to_measure"]),
            "to_offset": float(a.get("to_offset") or 0.0)}
    details = ops.move_element(score, args["part"], args["kind"], args["measure"],
                               ordinal=args["ordinal"],
                               to_measure=args["to_measure"],
                               to_offset=args["to_offset"], duplicate=duplicate)
    entry = workspace.add_version(a["score"], score, op, args)
    return {"version": entry["id"], "details": details}


def _dispatch(op, a):
    # -- the account's library on every device (0.16.0, librarysync) -------
    if op.startswith("library-sync-"):
        from scoranger_engine import librarysync
        if op == "library-sync-bind":
            return librarysync.bind(a["account"])
        if op == "library-sync-outbox":
            return librarysync.outbox(limit=int(a.get("limit") or 200))
        if op == "library-sync-ack":
            return librarysync.acknowledge(a.get("acks") or [])
        if op == "library-sync-apply":
            return librarysync.apply(a.get("records") or [])
        if op == "library-sync-status":
            return librarysync.status()
    if op == "manifest":
        return workspace.rebuild_manifest()
    if op == "selftest":
        # end-to-end: build a score, write+reload MusicXML, transpose,
        # version it in sqlite, then clean up
        from music21 import stream, note, metadata
        s = stream.Score()
        s.metadata = metadata.Metadata(title="Self Test")
        p = stream.Part()
        p.partName = "Test"
        for name in ("C4", "D4", "E4", "F4"):
            p.append(note.Note(name, quarterLength=1.0))
        s.append(p)
        slug, entry = workspace.create_score("Self Test", s, op="selftest", args={})
        reloaded = _load(slug)
        details = ops.transpose(reloaded, "M2", None)
        e2 = workspace.add_version(slug, reloaded, "transpose", {"interval": "M2"})
        pitches = [str(pt) for pt in _load(slug).pitches]
        workspace.delete_score(slug)
        return {"versions": [entry["id"], e2["id"]], "transposed": pitches,
                "details": details}
    if op == "add-version-from-file":
        # OMR on demand: the transcription becomes a NEW VERSION of the same
        # arrangement, not a new arrangement. The scan stays as v001, so the
        # reader can flip between the page they know and the transcription of
        # it -- which is exactly what checking OMR output requires.
        #
        # Through workspace.add_version_from_file, never converter.parse into
        # add_version: the file the app hands us is named after the version it
        # transcribed ("v001.mxl"), music21 makes that the movement title, and
        # Verovio engraves the movement title.
        entry = workspace.add_version_from_file(
            s_slug := a["score"], a["path"],
            a.get("op") or "omr", a.get("args") or {})
        out = {"score": s_slug, "version": entry["id"]}
        if entry.get("rhythm_warnings"):
            out["rhythm_warnings"] = entry["rhythm_warnings"]
        return out
    if op == "bundle-export":
        # One arrangement or setlist as a file the reader hands to somebody --
        # AirDrop, Files, a USB stick. No account, no network (FIREBASE.md §13).
        from scoranger_engine import bundle
        return bundle.export(a["target"], a["out"],
                             full_history=bool(a.get("full_history")),
                             ink_dir=a.get("ink"))
    if op == "share-payload":
        # What a shared setlist entry needs, decided by the engine because the
        # engine is what knows which version is pinned and where it lives.
        from scoranger_engine import bundle
        return bundle.share_payload(a["score"], ink_dir=a.get("ink"))
    if op == "bundle-inspect":
        # Read-only, and it is what the import screen is built from: nobody
        # takes a bundle in without being told what is in it first (§13.3).
        from scoranger_engine import bundle
        return bundle.inspect(a["path"])
    if op == "bundle-import":
        from scoranger_engine import bundle
        return bundle.import_(a["path"], into_piece=a.get("into_piece"),
                              ink_dir=a.get("ink"))
    if op == "import-book":
        # A BOOK, not a piece and not an arrangement: a collection that
        # arrangements are taken out of.
        name = a.get("name") or os.path.splitext(os.path.basename(a["path"]))[0]
        slug, doc = workspace.create_book(name, a["path"])
        return {"book": slug, "name": doc["name"], "pages": doc["pages"]}
    if op == "book-extract":
        slug, entry = workspace.extract_from_book(
            a["book"], int(a["from_page"]), int(a["to_page"]),
            a["name"], a.get("piece"))
        piece = a.get("piece") or workspace.ensure_own_piece(slug)["piece"]
        return {"score": slug, "version": entry["id"], "piece": piece}
    if op == "book-detect":
        # A PROPOSAL, read-only: where each tune starts and what it is called.
        # `needs_ocr` names the pages with no text layer; the app reads those
        # with Vision and asks again with `ocr` (fractions of the page).
        from scoranger_engine import booksplit
        workspace.resolve_book(a["book"])
        ocr = {int(k): v for k, v in (a.get("ocr") or {}).items()}
        return {"book": a["book"],
                **booksplit.propose(workspace.book_path(a["book"]), ocr)}
    if op == "book-contents":
        # Keep it a book: the tunes as page ranges, read like a set list.
        # `entries: null` clears them.
        from scoranger_engine import booksplit
        doc = booksplit.set_contents(a["book"], a.get("entries"))
        return {"book": a["book"], "contents": doc.get("contents") or []}
    if op == "book-split":
        # Take the tunes out: an arrangement each, under a piece named after it.
        from scoranger_engine import booksplit
        return booksplit.split(a["book"], a["entries"])
    if op == "book-file":
        # Where the book's own PDF is, so the reader can LOOK through it before
        # naming a page range. Asking someone for pages 137-139 of a fake book
        # they cannot see is asking them to guess.
        doc = workspace.resolve_book(a["book"])
        path = workspace.book_path(a["book"])
        if not path.exists():
            raise FileNotFoundError(f"'{doc['name']}' has no file at {path}")
        return {"path": str(path), "pages": doc.get("pages")}
    if op == "rename-book":
        # The book row's Rename. A book has no engraved title -- it is a PDF
        # nobody re-encodes -- so unlike an arrangement this is the library
        # name and nothing else.
        return workspace.rename_book(a["book"], a["name"])
    if op == "delete-book":
        workspace.delete_book(a["book"])
        return {"deleted": a["book"]}
    if op == "bulk-import":
        # A whole exported library at once: one folder per piece, its files the
        # arrangements. Plans FIRST and writes only when asked -- this runs
        # across an entire library and the tree is worth reading before it
        # exists.
        from scoranger_engine import bulk

        folder = a["folder"]
        # The caller may hand us the listing itself. It must, for a folder that
        # came from the iCloud file provider: os.walk sees such a directory as
        # EMPTY -- reading a file inside it works, enumerating it does not --
        # and an empty walk used to end the import in silence. Swift enumerates
        # under the security scope it already holds and passes what it found.
        given = a.get("files")
        if given is not None:
            names = [str(n) for n in given if not os.path.basename(str(n)).startswith(".")]
        else:
            names = []
            for base, _dirs, filenames in os.walk(folder):
                for fn in filenames:
                    rel = os.path.relpath(os.path.join(base, fn), folder)
                    if not fn.startswith("."):
                        names.append(rel)
        plan = bulk.plan(sorted(names), manifest=a.get("manifest"))
        # Pieces the reader deselected on the plan screen. Dropped from what is
        # WRITTEN, never from what is SHOWN: the plan still lists them, so the
        # numbers a reader approved are the numbers they saw.
        plan = bulk.without(plan, a.get("exclude"))
        if a.get("commit"):
            return {"plan": plan,
                    "result": bulk.run(plan, dry_run=False, root=folder)}
        return {"plan": plan, "result": bulk.run(plan, dry_run=True)}
    if op == "import-pdf":
        # The artifact IS the file: nothing parses it, nothing re-encodes it.
        # A scan reads and takes markup straight away; OMR is a later, explicit
        # step that turns it into an editable arrangement.
        name = a.get("name") or os.path.splitext(os.path.basename(a["path"]))[0]
        slug, entry = workspace.create_pdf_score(name, a["path"], op="import-pdf",
                                                 args={"source": a["path"]})
        if a.get("piece"):
            piece = workspace.assign_score_to_piece(slug, a["piece"])["piece"]
        else:
            # a scan is an arrangement too, and the rule is about arrangements
            piece = workspace.ensure_own_piece(slug)["piece"]
        return {"score": slug, "version": entry["id"], "piece": piece, "kind": "pdf"}
    if op == "import":
        # read_notation, never converter.parse: an ABC file can hold several
        # tunes and music21 returns an Opus for those, which has no `.parts`
        # and takes down everything that follows
        tunes = workspace.read_notation(a["path"])
        if not tunes:
            raise ValueError("that file holds no music")
        stem = os.path.splitext(os.path.basename(a["path"]))[0]
        rows = []
        for score in tunes:
            # music21 seeds the movement title with the file name, extension
            # and all, and that is what engraves; normalize before the first
            # version. `name` is the FALLBACK, so a tune that names itself
            # keeps its own name and a file of tunes imports as the tunes.
            name = a.get("name") or stem
            name = ops.clean_imported_metadata(score, name, source_stem=stem)["title"]
            slug, entry = workspace.create_score(name, score, op="import",
                                                 args={"source": a["path"]})
            if a.get("piece"):
                piece = workspace.assign_score_to_piece(slug, a["piece"])["piece"]
            else:
                # EVERY arrangement belongs to a piece. Without this the app's
                # own import was the thing that made UNFILED rows.
                piece = workspace.ensure_own_piece(slug)["piece"]
            # Odd bars in an imported score are reported, never fatal. OMR
            # output is imperfect by nature and the user brings the score in so
            # they can fix it; refusing the import left them unable to open
            # their own music.
            row = {"score": slug, "version": entry["id"], "piece": piece}
            if entry.get("rhythm_warnings"):
                row["rhythm_warnings"] = entry["rhythm_warnings"]
            rows.append(row)
        out = dict(rows[0])
        out["tunes_found"] = len(rows)
        out["arrangements"] = rows
        said = workspace.abc_report(a["path"], tunes) if os.path.splitext(
            a["path"])[1].lower() in workspace.ABC_SUFFIXES else {}
        if said:
            out["abc"] = said
        return out
    if op == "info":
        return ops.info(_load(a["score"], a.get("version")))
    if op == "playback":
        # ONE call, because the two halves must describe the same performance:
        # the MIDI a synthesiser plays, and the map from its beats back to the
        # engraved bars. Deriving them from separate reads of the score is how
        # a play head ends up following music that is not sounding.
        #
        # NOT a version: nothing about the arrangement changes. Playback is a
        # reading of it, like `info` and unlike every op above.
        slug = a["score"]
        version = a.get("version")
        played, timeline = ops.playback_timeline(_load(slug, version))
        out_dir = workspace.score_dir(slug).parent / "playback"
        out_dir.mkdir(parents=True, exist_ok=True)
        dest = out_dir / f"{slug}-{version or 'latest'}.mid"
        played.write("midi", fp=str(dest))
        return {"path": str(dest), "timeline": timeline}
    if op == "export":
        # Three formats, three sources -- and only two of them are ours.
        #
        # A version artifact IS MusicXML, so exporting one resolves a path
        # rather than re-serialising: writing it back through music21 would
        # risk changing bytes the user never asked to change. MIDI is a real
        # conversion and goes through music21. PDF is refused here on purpose:
        # `render.py` is not vendored into the app, the on-device engraver is
        # Swift, and chord adjustments and whistle fingerings are applied in
        # THAT pass -- so a PDF built here would not match the page on screen.
        fmt = (a.get("format") or "musicxml").lower()
        slug = a["score"]
        version = a.get("version")
        parts = [p.strip() for p in str(a.get("parts") or "").split(",") if p.strip()]
        stem = f"{slug}-{version}" if version else slug

        if fmt == "pdf":
            raise ValueError(
                "PDF is rendered on device by the Swift renderer, not the "
                "bridge: engraving carries chord adjustments and whistle "
                "fingerings that only that pass applies.")
        if fmt not in ("musicxml", "midi"):
            raise ValueError(f"unknown export format '{fmt}'. "
                             "Use musicxml, midi, or ask Swift for pdf.")

        out_dir = workspace.score_dir(slug).parent / "exports"
        out_dir.mkdir(parents=True, exist_ok=True)

        if fmt == "musicxml" and not parts:
            src = workspace.resolve_path(slug, version)
            dest = out_dir / f"{stem}.musicxml"
            shutil.copyfile(src, dest)
            return {"path": str(dest), "filename": dest.name, "format": fmt}

        score = _load(slug, version)
        if parts:
            ops.keep_parts(score, parts)
            stem = f"{stem}-{'-'.join(p.lower().replace(' ', '-') for p in parts)}"
        if fmt == "musicxml":
            dest = out_dir / f"{stem}.musicxml"
            score.write("musicxml", fp=str(dest))
        else:
            dest = out_dir / f"{stem}.mid"
            score.write("midi", fp=str(dest))
        return {"path": str(dest), "filename": dest.name, "format": fmt}

    if op == "versions":
        # NOT load_meta. This answer goes to a model provider, and the full
        # version documents carry artifact filenames, uids and a 200-character
        # excerpt of every earlier user prompt. One projection, shared with the
        # desktop agent's list_versions: workspace.VERSION_FIELDS.
        return workspace.version_history(a["score"])
    if op == "delete-score":
        workspace.delete_score(a["score"])
        return {"deleted": a["score"]}
    if op == "duplicate":
        src = _load(a["score"])  # latest version becomes the copy's v001
        name = a.get("name") or f"{a['score']} copy"
        slug, entry = workspace.create_score(name, src, op="duplicate",
                                             args={"source": a["score"]})
        # the copy stays filed with its source's piece
        piece = (workspace._repo().get_score(a["score"]) or {}).get("piece")
        if piece:
            workspace.assign_score_to_piece(slug, piece)
        return {"score": slug, "version": entry["id"]}
    if op == "restore-score":
        return {"restored": workspace.restore_score(a["score"])["slug"]}
    if op == "sweep":
        return {"swept": workspace.sweep()}
    if op == "tidy-pieces":
        return {"tidied": workspace.tidy_pieces()}
    if op == "delete-piece":
        workspace.delete_piece(a["piece"], with_arrangements=bool(a.get("with_arrangements")))
        return {"deleted": a["piece"]}
    if op == "create-piece":
        return workspace.create_piece(a["name"])
    if op == "assign-piece":
        return workspace.assign_score_to_piece(a["score"], a["piece"],
                                               create_if_missing=True)
    if op == "unassign-piece":
        return workspace.assign_score_to_piece(a["score"], None)
    if op == "combine-pieces":
        # ONE op rather than the app making N assign-piece calls: each of those
        # rebuilds the manifest and sweeps empty pieces, so a combine done
        # client-side is N round-trips racing the 2-second poll -- and a report
        # of what it did is the thing worth showing back.
        return workspace.combine_pieces(a["pieces"], into=a.get("into"),
                                        name=a.get("name"))
    if op == "rename-score":
        return workspace.rename_score(a["score"], a["name"])
    if op == "staff-spacing":
        score = _load(a["score"], None)
        details = ops.staff_spacing(score, staff=a.get("staff"),
                                    system=a.get("system"),
                                    fingering_rows=a.get("fingering_rows"),
                                    reset=bool(a.get("reset")))
        entry = workspace.add_version(a["score"], score, "staff-spacing",
                                      {"staff": a.get("staff"),
                                       "system": a.get("system"),
                                       "fingering_rows": a.get("fingering_rows"),
                                       "reset": bool(a.get("reset"))})
        return {"version": entry["id"], "details": details}
    if op == "paginate":
        score = _load(a["score"], None)
        details = ops.paginate(score,
                               measures_per_line=a.get("measures_per_line"),
                               break_at=a.get("break_at"),
                               remove_at=a.get("remove_at"),
                               clear=bool(a.get("clear")),
                               end_at=a.get("end_at"))
        entry = workspace.add_version(a["score"], score, "paginate",
                                      {"measures_per_line": a.get("measures_per_line"),
                                       "break_at": a.get("break_at"),
                                       "end_at": a.get("end_at"),
                                       "remove_at": a.get("remove_at"),
                                       "clear": bool(a.get("clear"))})
        return {"version": entry["id"], "details": details}
    if op == "measure-numbers":
        score = _load(a["score"], None)
        args = {"every": a.get("every"), "system": bool(a.get("system")),
                "none": bool(a.get("none")), "reset": bool(a.get("reset"))}
        details = ops.measure_numbers(score, **args)
        entry = workspace.add_version(a["score"], score, "measure-numbers", args)
        return {"version": entry["id"], "details": details}
    if op == "set-structure":
        score = _load(a["score"], None)
        details = ops.set_structure(score, a["kind"], measure=a.get("measure"),
                                    to_measure=a.get("to_measure"),
                                    number=a.get("number"), times=a.get("times"),
                                    remove=bool(a.get("remove")),
                                    move_to=a.get("move_to"))
        entry = workspace.add_version(a["score"], score, "set-structure",
                                      {"kind": a["kind"], "measure": a.get("measure")})
        return {"version": entry["id"], "details": details}
    if op == "adjust-element":
        score = _load(a["score"], None)
        # `scale` is the relative interface and `size` the absolute one the
        # adjust row already holds; ops.adjust_element refuses both at once.
        details = ops.adjust_element(
            score, a["part"], kind=a.get("kind") or "harm",
            measure=a.get("measure"), ordinal=int(a.get("ordinal") or 0),
            size=a.get("size"), scale=a.get("scale"),
            offset_x=a.get("offset_x"), offset_y=a.get("offset_y"),
            reset=bool(a.get("reset")), all_elements=bool(a.get("all")))
        entry = workspace.add_version(a["score"], score, "adjust-element",
                                      {"part": a["part"], "kind": a.get("kind") or "harm",
                                       "measure": a.get("measure")})
        return {"version": entry["id"], "details": details}
    if op == "add-element":
        score = _load(a["score"], None)
        details = ops.add_element(score, a["part"], a["kind"], int(a["measure"]),
                                  value=a.get("value"),
                                  offset=float(a.get("offset") or 0.0),
                                  placement=a.get("placement"))
        entry = workspace.add_version(a["score"], score, "add-element",
                                      {"part": a["part"], "kind": a["kind"],
                                       "measure": int(a["measure"]),
                                       "value": a.get("value")})
        return {"version": entry["id"], "details": details}
    if op == "move-element":
        return _place_element(a, op, duplicate=False)
    if op == "duplicate-element":
        return _place_element(a, op, duplicate=True)
    if op == "remove-element":
        score = _load(a["score"], None)
        details = ops.remove_element(score, a["part"], a["kind"],
                                     a.get("measure"),
                                     ordinal=int(a.get("ordinal") or 0),
                                     all_elements=bool(a.get("all")))
        entry = workspace.add_version(a["score"], score, "remove-element",
                                      {"part": a["part"], "kind": a["kind"],
                                       "measure": a.get("measure"),
                                       "ordinal": int(a.get("ordinal") or 0),
                                       "all": bool(a.get("all"))})
        return {"version": entry["id"], "details": details}
    if op == "guitar-tab":
        score = _load(a["score"], None)
        part = _part(score, a["part"])
        details = ops.guitar_tab(score, part, a.get("tuning") or "EADGBE",
                                 capo=int(a.get("capo") or 0),
                                 clear=bool(a.get("clear")))
        entry = workspace.add_version(a["score"], score, "guitar-tab",
                                      {"part": a["part"],
                                       "tuning": a.get("tuning") or "EADGBE",
                                       "capo": int(a.get("capo") or 0)})
        return {"version": entry["id"], "details": details}
    if op == "chord-diagrams":
        score = _load(a["score"], None)
        part = _part(score, a["part"])
        details = ops.chord_diagrams(score, part, a.get("tuning") or "EADGBE",
                                     clear=bool(a.get("clear")))
        entry = workspace.add_version(a["score"], score, "chord-diagrams",
                                      {"part": a["part"],
                                       "tuning": a.get("tuning") or "EADGBE"})
        return {"version": entry["id"], "details": details}
    if op == "whistle-fingerings":
        score = _load(a["score"], None)
        part = _part(score, a["part"])
        details = ops.whistle_fingerings(score, part, a.get("whistle") or "D",
                                         clear=bool(a.get("clear")))
        entry = workspace.add_version(a["score"], score, "whistle-fingerings",
                                      {"part": a["part"], "whistle": a.get("whistle") or "D"})
        return {"version": entry["id"], "details": details}
    if op == "rename-slug":
        return workspace.rename_slug(a["score"], a["to"])
    if op == "set-metadata":
        return workspace.set_score_metadata(a["score"], title=a.get("title"),
                                            composer=a.get("composer"),
                                            arranger=a.get("arranger"))
    if op == "repair-titles":
        # The other half of the v001.mxl fix. Guarding the way in protects only
        # versions written after the guard; a library OMR'd before it has the
        # file name baked into notation already on disk. This finds those and
        # -- only when asked -- gives each one a corrected NEW version through
        # set-metadata, so no history is rewritten.
        return workspace.repair_titles(dry_run=not a.get("apply"))
    if op == "set-piece-metadata":
        # Composer lives on the PIECE as well as in notation: an arrangement
        # imported as a PDF has none to write into, so a scan could otherwise
        # never be credited at all.
        return workspace.set_piece_metadata(a["piece"], composer=a.get("composer"),
                                            tags=a.get("tags"),
                                            arranger=a.get("arranger"))
    if op == "tags":
        return {"tags": workspace.all_tags()}
    if op == "rename-piece":
        return workspace.rename_piece(a["piece"], a["name"])
    if op == "reorder-piece":
        return workspace.set_piece_order(a["piece"], a["order"])
    if op == "reorder-setlist":
        return workspace.set_setlist_order(a["setlist"], a["order"])
    if op == "create-setlist":
        return workspace.create_setlist(a["name"])
    if op == "assign-setlist":
        return workspace.add_score_to_setlist(a["setlist"], a["score"],
                                              create_if_missing=True)
    if op == "unassign-setlist":
        return workspace.remove_score_from_setlist(a["setlist"], a["score"])
    if op == "bind-setlist-share":
        # Promotion's last step: the set list now IS the shared document.
        return workspace.bind_setlist_share(a["setlist"], a["shareId"],
                                            a["ownerUid"])
    if op == "rename-setlist":
        return workspace.rename_setlist(a["setlist"], a["name"])
    if op == "delete-setlist":
        return workspace.delete_setlist(a["setlist"])
    if op == "debug-orphan-arrangement":
        # TEST FIXTURE ONLY, and the only way to produce this shape any more:
        # create_score now rolls the row back if the version does not land, so
        # an arrangement with no versions cannot be made through the normal
        # path. The app calls this solely under -seedBrokenArrangement, to
        # prove that such an arrangement explains itself rather than spinning.
        slug = a.get("slug") or "broken-arrangement"
        workspace._repo().set_score(slug, {
            "id": slug, "slug": slug, "name": a.get("name") or "Morrison's jig",
            "title": a.get("name") or "Morrison's jig", "composer": None,
            "arranger": None, "created": workspace._now(), "latest": None,
        })
        workspace.rebuild_manifest()
        return {"score": slug, "versions": 0}
    if op == "debug-poison-title":
        # TEST FIXTURE ONLY, and the only way to produce this shape any more:
        # add_version_from_file now refuses to let a file name become a title,
        # so a version titled "v001.mxl" cannot be made through the normal path.
        # The app calls this under -seedPoisonedTitles to reproduce the library
        # the reader actually has -- OMR'd before the guard existed -- so the
        # repair, and the screenshots of it, are taken against the real damage.
        score = _load(a["score"])
        ops.set_metadata(score, title=a.get("title") or "v001.mxl")
        entry = workspace.add_version(a["score"], score, a.get("op") or "omr", {})
        return {"score": a["score"], "version": entry["id"],
                "title": a.get("title") or "v001.mxl"}
    if op == "create-arrangement":
        # a minimal valid score: one part, one 4/4 measure with a whole rest
        from music21 import clef, meter, metadata, note, stream
        s = stream.Score()
        name = a.get("name") or "Arrangement"
        s.metadata = metadata.Metadata(title=name, movementName=name)
        p = stream.Part()
        p.partName = "Part 1"
        m = stream.Measure(number=1)
        m.append(clef.TrebleClef())
        m.append(meter.TimeSignature("4/4"))
        m.append(note.Rest(quarterLength=4.0))
        p.append(m)
        s.append(p)
        slug, entry = workspace.create_score(name, s, op="create-arrangement",
                                             args={"piece": a["piece"]})
        workspace.assign_score_to_piece(slug, a["piece"])
        return {"score": slug, "version": entry["id"]}
    if op == "add-source":
        # a source is ONE reference edition; read_notation so a multi-tune ABC
        # cannot hand an Opus to add_source
        tunes = workspace.read_notation(a["path"])
        if not tunes:
            raise ValueError("that file holds no music")
        return workspace.add_source(a["score"], tunes[0],
                                    a.get("name") or "source", a["path"])
    if op == "analyze":
        return ops.analyze_harmony(_load(a["score"], a.get("version")), a.get("parts"))
    if op == "check-range":
        from music21 import instrument as m21instrument
        score = _load(a["score"])
        p = _part(score, a["part"])
        cls = (type(m21instrument.fromString(a["instrument"])).__name__ if a.get("instrument")
               else type(p.getInstrument(returnDefault=False)).__name__)
        if cls not in ops.RANGES:
            raise ValueError(f"No range data for '{cls}'. Known: {sorted(ops.RANGES)}")
        return {"part": ops.part_label(p), "instrument": cls,
                "violations": ops.range_violations(p, cls)}
    if op == "begin-turn":
        return workspace.begin_turn(a["score"], a.get("prompt") or "")
    if op == "end-turn":
        return workspace.end_turn()
    if op == "version-file":
        return {"path": str(workspace.resolve_path(a["score"], a.get("version")))}
    if op == "source-file":
        return {"path": str(workspace.source_path(a["score"], a["source"]))}

    s = a["score"]
    if op == "keep-parts":
        return _mutate(s, op, a, lambda sc: {"removed": ops.keep_parts(sc, a["parts"])})
    if op == "remove-parts":
        return _mutate(s, op, a, lambda sc: {"removed": ops.remove_parts(sc, a["parts"])})
    if op == "transpose":
        return _mutate(s, op, a, lambda sc: ops.transpose(
            sc, str(a["interval"]), a.get("parts"),
            a.get("from_measure"), a.get("to_measure")))
    if op == "transpose-elements":
        return _mutate(s, op, a, lambda sc: ops.transpose_elements(
            sc, str(a["interval"]), list(a["elements"])))
    if op == "transpose-diatonic":
        return _mutate(s, op, a, lambda sc: ops.transpose_diatonic(
            sc, a["degrees"], a.get("parts"),
            a.get("from_measure"), a.get("to_measure"), a.get("key")))
    if op == "transpose-diatonic-elements":
        return _mutate(s, op, a, lambda sc: ops.transpose_diatonic_elements(
            sc, a["degrees"], list(a["elements"]), a.get("key")))
    if op == "respell":
        return _mutate(s, op, a, lambda sc: ops.respell(
            sc, a.get("prefer", "flats"), a.get("parts"),
            a.get("from_measure"), a.get("to_measure")))
    if op == "set-rehearsal":
        return _mutate(s, op, a, lambda sc: ops.set_rehearsal(
            sc, measure=a.get("measure"), mark=a.get("mark"),
            remove=bool(a.get("remove")), move_to=a.get("move_to"),
            reletter=bool(a.get("reletter"))))
    if op == "clean-accidentals":
        return _mutate(s, op, a, lambda sc: ops.normalize_accidentals(sc, a.get("parts")))
    if op == "set-accidental":
        return _mutate(s, op, a, lambda sc: ops.set_accidental(
            sc, list(a["elements"]), show=a.get("show"), add=a.get("add"),
            remove=bool(a.get("remove")), color=a.get("color")))
    if op == "change-clef":
        return _mutate(s, op, a, lambda sc: ops.change_clef(_part(sc, a["part"]), a["clef"], a.get("from_measure", 1)))
    if op == "change-instrument":
        return _mutate(s, op, a, lambda sc: ops.change_instrument(_part(sc, a["part"]), a["to"]))
    if op == "rename-part":
        return _mutate(s, op, a, lambda sc: ops.rename_part(_part(sc, a["part"]), a["name"], a.get("abbreviation")))
    if op == "octave-shift":
        return _mutate(s, op, a, lambda sc: ops.octave_shift(sc, a["part"], a["octaves"], a["from_measure"], a["to_measure"]))
    if op == "merge-parts":
        return _mutate(s, op, a, lambda sc: ops.merge_parts(sc, a["parts"], a["name"], a.get("clef", "treble")))
    if op == "split-bass":
        return _mutate(s, op, a, lambda sc: ops.split_bass(sc, a["part"], a["bass_name"], a["chords_name"], a.get("instrument")))
    if op == "absorb-part":
        return _mutate(s, op, a, lambda sc: ops.absorb_part(sc, a["source"], a["target"], a.get("rules")))
    if op == "flatten-voices":
        return _mutate(s, op, a, lambda sc: ops.flatten_voices(sc, a["part"]))
    if op == "consolidate-ties":
        return _mutate(s, op, a, lambda sc: ops.consolidate_ties(sc, a["parts"]))
    if op == "limit-part":
        return _mutate(s, op, a, lambda sc: ops.limit_part(sc, a["part"], a.get("max_pitch"), a.get("monophonic", False)))
    if op == "simplify-rhythm":
        return _mutate(s, op, a, lambda sc: ops.simplify_rhythm(
            sc, a["mode"], [a["part"]] if a.get("part") else None,
            a.get("unit", "eighth"), a.get("from_measure"), a.get("to_measure")))
    if op == "simplify-repeats":
        return _mutate(s, op, a, lambda sc: ops.simplify_repeats(sc, a["part"]))
    if op == "strip-notes":
        # The names-only staff: the chart's changes with nothing engraved under
        # them. The engine has had the op and the CLI has documented it since
        # before this bridge existed, and the app could not ask for it -- found
        # while building a fixture that wanted one.
        return _mutate(s, op, a, lambda sc: ops.strip_notes(sc, a["part"]))
    if op == "set-chords":
        return _mutate(s, op, a, lambda sc: ops.set_chord_symbols(sc, a["part"], a["chords"]))
    if op == "chart-style":
        return _mutate(s, op, a, lambda sc: ops.chart_style(sc, a["part"]))
    if op == "pull-part":
        def fn(sc):
            from music21 import converter
            ref = a["from"]
            if ref.startswith("src:"):
                path = workspace.source_path(s, ref[4:])
            elif ref.startswith("arr:"):
                # sibling arrangement of the same piece — latest version
                path = workspace.resolve_path(ref[4:])
            else:
                path = workspace.resolve_path(s, ref)
            src_score = converter.parse(str(path), forceSource=True)
            rng = None
            if a.get("measures"):
                lo, hi = str(a["measures"]).split("-")
                rng = (int(lo), int(hi))
            return ops.pull_part(sc, src_score, a["part"], a.get("as"), a.get("replace"), rng)
        return _mutate(s, op, a, fn)
    raise ValueError(f"unknown op '{op}'")


def handle(request):
    try:
        req = json.loads(request)
        op = req.get("op")
        args = req.get("args") or {}
        if op == "configure":
            os.environ["SCORANGER_WORKSPACE"] = args["workspace"]
            _ensure_engine()
            # A device that has signed in to sync keeps journaling across
            # launches, signed in or not, so what it does while signed out
            # still reaches the account (librarysync.is_on). One that never
            # has, never starts: no journal file exists to find.
            from scoranger_engine import librarysync
            if librarysync.is_on():
                librarysync.start()
            import music21
            return json.dumps({"ok": True, "python": sys.version.split()[0],
                               "music21": music21.__version__})
        _ensure_engine()
        return json.dumps({"ok": True, "result": _dispatch(op, args)})
    except Exception as e:
        return json.dumps({"ok": False, "error": f"{type(e).__name__}: {e}",
                           "trace": traceback.format_exc()[-1200:]})
