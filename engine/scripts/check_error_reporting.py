"""A failure the reader is not told about is a failure the app did not have.

This is the third time. The shape repeats exactly:

  1. `notice` was assigned in five places and read in NONE. Every message the
     app tried to give -- an import that found nothing, a PDF that would not
     transcribe, a missing OMR service -- went nowhere. Fixed in 0.5.2 by
     writing `NoticeBar` and rendering it.

  2. `lastError` was assigned in SIXTY places across thirty-three functions,
     and its only reader is the "Render failed" placeholder inside an OPEN
     score. Import Book died on a missing `pypdf`, wrote the reason there from
     the library, and looked exactly like a button that did nothing. It was
     reported as "nothing happens", and cost two rounds to find.

  3. -- prevented here.

Assignment is not delivery. What this asserts:

  A. Every `@Published` property of AppState is READ somewhere outside
     AppState.swift, or is listed below as internal WITH its reason. A new
     write-only published property fails the build. This is the general form
     of the bug and the reason this file exists.

  B. `lastError` is written only on the render path, where its reader is.
     Every other failure goes to `notice` through `report(_:_:)`.

  C. `notice` still has a renderer, and `report` still routes to it -- the
     destination cannot quietly become dead in its turn.

  D. No `catch` block in AppState swallows an engine failure in silence.

Run: engine/.venv/bin/python engine/scripts/check_error_reporting.py
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "ios" / "Scoranger" / "AppState.swift"
VIEWS = ROOT / "ios" / "Scoranger"

# Published properties AppState legitimately keeps to itself, each with the
# reason it is not dead UI. Anything NOT here must be read by a view.
#
# Adding a name to this list is a decision to be made deliberately and written
# down -- which is the whole point. "It is not wired up yet" is not a reason.
INTERNAL = {
    "arrangementTagsVersion": "a counter bumped when a tag changes so every "
                              "view observing AppState re-reads the tag store "
                              "(ArrangementTags.shared, a file); nothing "
                              "displays the number itself",
    "previewedSlug": "the row being previewed; AppState resolves it into "
                     "selectedSlug before any view asks",
    "renderedLayout": "the layout the pages on the canvas were engraved for; "
                      "read by `layout` to decide what may be DRAWN "
                      "(ScoreLayout.displayed), never shown",
    "engravingInFlight": "the engraving an engrave is being made for, read by "
                         "`layout` to tell a handover in progress from one that "
                         "failed (ScoreLayout.displayed). Published although no "
                         "view shows it: when an engrave FAILS nothing else "
                         "changes, and without this publish the canvas would "
                         "never re-read `layout` -- the reader stays stranded on "
                         "the continuous strip, which is the bug it fixes",
    "selection": "the lasso's result, read back through selectionPaths and the "
                 "ops that consume it",
    "selectionKey": "the engraving a selection was drawn on, compared inside "
                    "carrySelection when a re-render lands",
    "markAdjustments": "what every added mark already carries, by address; read "
                       "by retargetAdjustment to start a session from the "
                       "notation rather than from the default, not rendered",
    "combineMode": "replace/add/subtract, applied inside the selection merge",
}

# Where a render failure is allowed to be recorded. `lastError`'s one reader is
# ContentView's "Render failed" placeholder, which is on screen exactly here.
RENDER_PATH = "renderIfNeeded"

FAILURES: list[str] = []


def check(label: str, ok: bool, detail: str = "") -> None:
    if ok:
        print(f"  ok   {label}")
    else:
        FAILURES.append(f"{label}{': ' + detail if detail else ''}")
        print(f"  FAIL {label}{': ' + detail if detail else ''}")


def enclosing_func(lines: list[str], index: int) -> str | None:
    """The function a line sits in, walking back to the nearest `func`."""
    pattern = re.compile(
        r"\s*(?:@\w+\s+)?(?:private |public |internal |nonisolated )*func\s+(\w+)")
    for i in range(index, -1, -1):
        m = pattern.match(lines[i])
        if m:
            return m.group(1)
    return None


def main() -> int:
    app = APP.read_text()
    lines = app.split("\n")
    views = {p: p.read_text() for p in VIEWS.rglob("*.swift") if p != APP}
    view_text = "\n".join(views.values())

    # ---- A. no published property is written and never read -----------------
    published = re.findall(r"@Published\s+(?:private\(set\)\s+)?var\s+(\w+)", app)
    check("AppState still publishes something", len(published) > 10, str(len(published)))

    unread = [p for p in published if not re.search(r"\." + p + r"\b", view_text)]
    dead = [p for p in unread if p not in INTERNAL]
    check("every published property is read by a view, or declared internal",
          not dead,
          "written and never read, and not in INTERNAL: " + ", ".join(dead)
          + " -- either render it or add it to INTERNAL with the reason")

    # and the list does not rot the other way: a name that IS read now should
    # come off it, or the list stops meaning anything
    stale = [p for p in INTERNAL if p in published and p not in unread]
    check("the INTERNAL list carries nothing that a view now reads",
          not stale, ", ".join(stale) + " -- read by a view; drop from INTERNAL")

    gone = [p for p in INTERNAL if p not in published]
    check("the INTERNAL list names only properties that exist",
          not gone, ", ".join(gone))

    # ---- B. lastError is the render channel and nothing else ----------------
    strays: list[str] = []
    for i, line in enumerate(lines):
        if re.search(r"^\s*lastError\s*=", line):
            fn = enclosing_func(lines, i)
            if fn != RENDER_PATH:
                strays.append(f"line {i + 1} in {fn}()")
    check("lastError is written only on the render path",
          not strays,
          "; ".join(strays) + f" -- lastError is drawn only by the "
          f"'Render failed' placeholder inside an open score. Use "
          f"report(\"...\", error), which reaches NoticeBar")

    # the render path must still USE it, or the placeholder shows nothing
    check("the render path still records why it failed",
          any(re.search(r"^\s*lastError\s*=", l)
              and enclosing_func(lines, i) == RENDER_PATH
              for i, l in enumerate(lines)))
    check("a view still renders lastError",
          "state.lastError" in view_text,
          "the render-failure placeholder is gone; lastError is now dead too")

    # ---- C. the destination is alive ---------------------------------------
    check("report() exists as the one route to the reader",
          re.search(r"func report\(_ action: String, _ error: Error\)", app) is not None)
    check("report() writes to notice",
          re.search(r"func report\([^)]*\)\s*\{\s*\n\s*notice\s*=", app) is not None)
    check("report() is actually used", app.count('report("') >= 20,
          f"only {app.count('report(\"')} call sites -- the routing was undone")
    check("some view renders state.notice",
          re.search(r"state\.notice\b", view_text) is not None)
    # \b, not a substring: renaming it to NoticeBarX would otherwise still match
    check("a NoticeBar exists to render it",
          re.search(r"\bstruct NoticeBar\b", view_text) is not None)
    check("something instantiates it",
          re.search(r"\bNoticeBar\(", view_text) is not None,
          "NoticeBar is declared but never placed on screen")

    # ---- D. no catch swallows a failure in silence -------------------------
    # A block that neither reports, nor re-raises, nor says in a comment that it
    # is deliberately internal. The comment is the escape hatch, on purpose: it
    # forces the decision to be written down next to the code that made it.
    silent: list[str] = []
    for i, line in enumerate(lines):
        if not re.match(r"\s*\}?\s*catch\b.*\{\s*$", line):
            continue
        depth, body, j = 1, [], i + 1
        while j < len(lines) and depth > 0:
            depth += lines[j].count("{") - lines[j].count("}")
            if depth > 0:
                body.append(lines[j])
            j += 1
        text = "\n".join(body)
        spoken = any(t in text for t in (
            "report(", "notice =", "lastError =", "folderImportResult =",
            "throw", "return", "print(", "INTERNAL", "// ignored",
            "unavailable:", "engineOK",
            # reported somewhere other than a bar, and no less loudly for it
            "chatMessages[",     # the agent's failure belongs in the transcript
            "payload =",         # the DEBUG chat inbox answers in its result file
            "=FAILED(",          # the test seed answers in `seedOutcome`, which
                                 # is what a UI test reads to find out WHICH of
                                 # the seeding ops failed; there is no reader to
                                 # show a bar to, because nothing but the test
                                 # harness ever runs it
            "Task.sleep"))       # a retry: the last attempt throws
        if not spoken and body:
            silent.append(f"line {i + 1} in {enclosing_func(lines, i)}()")
    check("no catch block in AppState fails in silence",
          not silent,
          "; ".join(silent) + " -- report it, or say in a comment why not")

    if FAILURES:
        print(f"\n{len(FAILURES)} failed")
        return 1
    print("\nerror reporting: all good")
    return 0


if __name__ == "__main__":
    sys.exit(main())
