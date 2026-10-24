#!/usr/bin/env python3
"""Deleting is recoverable for a window, and then it really is gone.

NAV_MODAL_FREE_0.4.2 §5.2 replaces the delete alert with a two-step confirm
strip and an undo bar. The bar is only honest if the engine can actually put
the thing back, so deletion is two phases: mark, then sweep.

Three things have to hold, and they pull against each other:
  1. a deleted arrangement comes BACK, whole, inside the window
  2. it is GONE after the window
  3. while marked it is invisible everywhere -- the library, the manifest,
     the piece's arrangement count -- or a "deleted" score would still be
     openable, which is worse than not offering undo at all

Run: engine/.venv/bin/python engine/scripts/check_undo.py
"""
import os
import sys
import tempfile
from datetime import datetime, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

FAILURES = []


def check(condition, message):
    if not condition:
        FAILURES.append(message)
    return condition


def main():
    root = tempfile.mkdtemp(prefix="scoranger-undo-")
    os.environ["SCORANGER_HOME"] = root
    from scoranger_engine import workspace
    import fixtures
    workspace.WORKSPACE = Path(root)      # type: ignore[attr-defined]
    if hasattr(workspace, "_reset_repo_for_testing"):
        workspace._reset_repo_for_testing()

    def library():
        return {s["slug"] for s in workspace.rebuild_manifest()["scores"]}

    slug, _ = workspace.create_score("Blue Bossa", fixtures.jig(bars=4))
    workspace.assign_score_to_piece(slug, "Blue Bossa")
    versions_before = len(workspace.load_meta(slug)["versions"])
    check(slug in library(), "the arrangement was never in the library")

    # --- 3. marked is invisible, everywhere ---------------------------------
    workspace.delete_score(slug)
    check(slug not in library(), "a deleted arrangement is still in the library")
    manifest = workspace.rebuild_manifest()
    pieces = {p["slug"]: p for p in manifest["pieces"]}
    check("blue-bossa" not in pieces,
          "the piece survived with a deleted arrangement as its only member")
    check(Path(workspace.score_dir(slug)).exists(),
          "the artifacts were reclaimed at once -- there is nothing left to undo")
    print("  marked: gone from the library, artifacts still on disk")

    # --- 1. it comes back, whole -------------------------------------------
    workspace.restore_score(slug)
    check(slug in library(), "undo did not bring the arrangement back")
    # ...into its piece. The piece was dropped at the first phase of the
    # delete, and the restored arrangement was filed under nothing -- in no
    # list at all (0.23.4).
    pieces = {p["slug"]: p for p in workspace.rebuild_manifest()["pieces"]}
    check(slug in pieces.get("blue-bossa", {}).get("arrangements", []),
          "undo brought the arrangement back without its piece")
    restored = workspace.load_meta(slug)
    check(len(restored["versions"]) == versions_before,
          f"it came back with {len(restored['versions'])} versions, "
          f"not the {versions_before} it had")
    print(f"  restored: back in the library with all {versions_before} version(s)")

    # --- a sweep must not touch what is not marked -------------------------
    check(workspace.sweep() == [], "the sweep reclaimed a live arrangement")
    check(slug in library(), "the sweep deleted something nobody asked it to")
    print("  sweep with nothing marked: nothing taken")

    # --- and not what is still inside its window ---------------------------
    workspace.delete_score(slug)
    check(workspace.sweep() == [],
          "the sweep reclaimed something still inside its undo window")
    check(Path(workspace.score_dir(slug)).exists(),
          "artifacts went while undo was still on offer")
    print("  sweep inside the window: nothing taken")

    # --- 2. gone after the window ------------------------------------------
    later = (datetime.fromisoformat(workspace._now())
             + timedelta(seconds=workspace.UNDO_WINDOW_SECONDS + 5)).isoformat()
    swept = workspace.sweep(now=later)
    check(slug in swept, f"the sweep did not reclaim the expired arrangement: {swept}")
    check(not Path(workspace.score_dir(slug)).exists(),
          "the sweep left the artifacts on disk -- nothing was reclaimed")
    check(slug not in library(), "it came back from the dead")
    try:
        workspace.load_meta(slug)
        FAILURES.append("the score document survived the sweep")
    except FileNotFoundError:
        pass
    print("  sweep after the window: row and artifacts both reclaimed")

    print()
    if FAILURES:
        print(f"FAILED ({len(FAILURES)}):")
        for f in FAILURES:
            print("  -", f)
        return 1
    print(f"OK: a delete is invisible at once, restorable for "
          f"{workspace.UNDO_WINDOW_SECONDS}s, and reclaimed after")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
