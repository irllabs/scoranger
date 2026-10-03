"""The chat agent DISPATCHES -- asserted against a stubbed model, no network.

The app is chat-driven and this path had no automated coverage at all. What a
model CHOOSES to say is judgement and stays a manual question; what the code
does once a tool call arrives is not, and that is what this runs.

The model here is `pydantic_ai.models.function.FunctionModel`: a function that
returns the tool call we scripted, then reads the tool's answer back out of the
message history. No key, no provider, no bill -- and the run is not allowed to
reach for one. `socket.connect` is replaced with a raise before anything is
imported, so a stub that was somehow bypassed fails loudly here instead of
quietly costing money, and every step asserts the stub was the thing that ran.
A check that silently skips when a key is absent is worse than no check.

WHAT IT CATCHES. `chat.py`'s tool functions are never called by any other
check: the engine checks call `ops.*` directly and the app's checks go through
`bridge.py`. Three tools here -- whistle fingerings, guitar tab and chord
diagrams -- called a `_part` helper that exists in `bridge.py` and did not
exist in `chat.py`, so every one of them raised NameError the moment a model
picked it. That is the same failure `scor whistle-fingerings` had for months,
in the third of the four surfaces an op has to reach.

THE LEDGER. Every tool in `chat.TOOLS` is either driven below or named in
NOT_EXERCISED with a reason. A tool in neither fails the check, which is what
stops this coverage rotting the next time someone adds one.

Fixtures are synthetic: the repository is public, so no committed fixture may
carry copyrighted music.

Run: engine/.venv/bin/python engine/scripts/check_chat.py
"""

import os
import socket
import sys
import tempfile
from pathlib import Path

# -- no network, before anything that could open one is imported --------------
# Not a mock of our own code: the socket itself. If a run ever reaches a real
# provider, this is the line it dies on.
_ATTEMPTED: list[str] = []


def _forbidden(*args, **kwargs):
    _ATTEMPTED.append(str(args[:1]))
    raise AssertionError(
        "a network connection was attempted: the stubbed model was bypassed "
        "and a real provider was about to be called")


socket.socket.connect = _forbidden          # type: ignore[method-assign]
socket.socket.connect_ex = _forbidden       # type: ignore[method-assign]
socket.create_connection = _forbidden       # type: ignore[assignment]

# ...and no key, so nothing can authenticate even if it got out.
for _key in ("OPENROUTER_API_KEY", "ANTHROPIC_API_KEY", "OPENAI_API_KEY",
             "GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_APPLICATION_CREDENTIALS"):
    os.environ.pop(_key, None)

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "engine"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

WORKSPACE = Path(tempfile.mkdtemp()) / "workspace"
os.environ["SCORANGER_WORKSPACE"] = str(WORKSPACE)

import fixtures  # noqa: E402
from pydantic_ai.messages import (ModelResponse, TextPart,  # noqa: E402
                                  ToolCallPart, ToolReturnPart)
from pydantic_ai.models.function import AgentInfo, FunctionModel  # noqa: E402

from scoranger_engine import chat, workspace  # noqa: E402

FAILURES: list[str] = []


def check(condition: bool, message: str) -> None:
    if condition:
        print(f"  ok   {message}")
    else:
        print(f"  FAIL {message}")
        FAILURES.append(message)


# -- the stub -----------------------------------------------------------------

class Stub:
    """A model that says exactly one thing: call these tools, in this order.

    `rounds` is a list of tool calls; each entry is the model's next turn. When
    it runs out the stub answers with text, which is what ends the agent loop.
    It also keeps what the tools handed BACK, read off the message history the
    way the real model would read it.
    """

    # FunctionModel names the model after the function it was handed, so the
    # callable it gets needs one.
    __name__ = "scripted-stub"

    def __init__(self, *rounds: tuple[str, dict]):
        self.rounds = list(rounds)
        self.turns = 0
        self.offered: list[str] = []
        self.returned: list[tuple[str, object]] = []

    def __call__(self, messages, info: AgentInfo) -> ModelResponse:
        self.offered = [t.name for t in info.function_tools]
        for message in messages:
            for part in getattr(message, "parts", []):
                if isinstance(part, ToolReturnPart):
                    entry = (part.tool_name, part.content)
                    if entry not in self.returned:
                        self.returned.append(entry)
        turn = self.turns
        self.turns += 1
        if turn < len(self.rounds):
            name, args = self.rounds[turn]
            return ModelResponse(parts=[ToolCallPart(name, args)])
        return ModelResponse(parts=[TextPart("Done.")])

    def answer(self, tool: str) -> dict:
        for name, content in self.returned:
            if name == tool:
                return content if isinstance(content, dict) else {"content": content}
        return {}


def drive(slug: str, *rounds: tuple[str, dict]) -> Stub:
    """One chat turn against the stub, through `chat.run_chat` itself -- the
    same entry point the CLI's `scor chat` and the desktop viewer call."""
    stub = Stub(*rounds)
    chat.run_chat(slug, "do the thing", model=FunctionModel(stub))
    return stub


# -- the tools, in an order that lets each one stand on the last ---------------
# (score key, tool name, arguments the model "wrote")
JIG_STEPS: list[tuple[str, dict]] = [
    ("get_score_info", {}),
    ("list_versions", {}),
    ("analyze_harmony", {}),
    ("check_range", {"part": "#0", "instrument": "Flute"}),
    ("set_chords", {"part": "#0", "chords": [{"measure": 1, "symbol": "Em"},
                                             {"measure": 3, "symbol": "G"}]}),
    ("chart_style", {"part": "#0"}),
    ("guitar_chord_diagrams", {"part": "#0"}),
    # the four marks nothing could ADD before 0.8.2. Bar 5 is the tied bar:
    # notes start at 0 and at 1.5, which is what a note-attached mark needs.
    ("add_element", {"part": "#0", "kind": "dynamic", "measure": 5, "value": "p"}),
    ("add_element", {"part": "#0", "kind": "text", "measure": 5,
                     "value": "poco rit.", "offset": 1.5}),
    ("add_element", {"part": "#0", "kind": "fermata", "measure": 5, "offset": 0}),
    ("add_element", {"part": "#0", "kind": "articulation", "measure": 5,
                     "value": "tenuto", "offset": 0}),
    ("adjust_element", {"part": "#0", "kind": "dynamic", "measure": 5, "scale": 1.5}),
    ("move_element", {"part": "#0", "kind": "dynamic", "measure": 5,
                      "to_measure": 3, "to_offset": 1.5}),
    ("duplicate_element", {"part": "#0", "kind": "fermata", "measure": 5,
                           "to_measure": 4, "to_offset": 0}),
    ("remove_element", {"part": "#0", "kind": "articulation", "measure": 5,
                        "ordinal": 0}),
    ("set_structure", {"kind": "repeat-end", "measure": 4}),
    ("paginate", {"measures_per_line": 4}),
    ("paginate", {"end_at": [3]}),
    ("measure_numbers", {"every": 1}),
    ("staff_spacing", {"staff": 16, "fingering_rows": 4}),
    ("set_rehearsal", {"measure": 3, "mark": "A"}),
    ("transpose", {"interval": "M2"}),
    ("transpose_diatonic", {"degrees": "1"}),
    ("transpose_elements", {"interval": "m2", "elements": ["s1/m1/l1/note#0"]}),
    ("transpose_diatonic_elements", {"degrees": "1", "elements": ["s1/m1/l1/note#0"]}),
    ("respell", {"prefer": "sharps"}),
    ("clean_accidentals", {}),
    ("set_accidental", {"elements": ["s1/m1/l1/note#0"], "show": True}),
    # the three that raised NameError for want of `_part`
    ("penny_whistle_fingerings", {"part": "#0", "whistle": "D"}),
    ("guitar_tablature", {"part": "#0"}),
    ("simplify_repeats", {"part": "#0"}),
    # thin, not augment: augment halves the meter's denominator for the
    # whole score, and every step after this one would then be running on
    # music in a meter it was not written for. Both modes are proved in
    # check_rhythm_simplify.py; what this ledger asks is whether the tool
    # the model was offered reaches the op.
    ("simplify_rhythm", {"mode": "thin", "part": "#0", "unit": "eighth"}),
    ("consolidate_ties", {"parts": ["#0"]}),
    ("limit_part", {"part": "#0", "max_pitch": "C6"}),
    ("flatten_voices", {"part": "#0"}),
    ("octave_shift", {"part": "#0", "octaves": -1, "from_measure": 1, "to_measure": 2}),
    ("change_clef", {"part": "#0", "clef": "treble"}),
    ("rename_part", {"part": "#0", "name": "Whistle"}),
    ("change_instrument", {"part": "Whistle", "to_instrument": "Flute"}),
    ("pull_part", {"from_ref": "v001", "part": "Pennywhistle"}),
    # last on this score: it empties the staff the ops above needed notes on
    ("strip_notes", {"part": "Whistle"}),
    ("set_metadata", {"title": "Chat Jig", "composer": "Trad."}),
    ("assign_to_piece", {"piece_name": "Chat Reels"}),
]

QUARTET_STEPS: list[tuple[str, dict]] = [
    ("absorb_part", {"source": "Violin II", "target": "Violin I"}),
    ("merge_parts", {"parts": ["Viola", "Violoncello"],
                     "new_name": "Accordion L.H.", "clef": "bass"}),
    ("split_bass", {"part": "Accordion L.H.", "bass_name": "Acc. Bass",
                    "chords_name": "Acc. Chords"}),
    ("keep_parts", {"parts": ["Violin I", "Acc. Bass", "Acc. Chords"]}),
    ("remove_parts", {"parts": ["Acc. Chords"]}),
]

NOT_EXERCISED: dict[str, str] = {}


def failed(answer: dict) -> str | None:
    """The error a tool answered with, if it answered with one. Tools return
    failures as DATA -- that is the contract with the model -- so a raise is
    not what this looks for."""
    if not isinstance(answer, dict):
        return f"not a dict: {answer!r}"
    if answer.get("ok") is False:
        return str(answer.get("error"))
    return None


def main() -> int:
    jig_slug, _ = workspace.create_score("Chat Jig", fixtures.jig(bars=8))
    quartet_slug, _ = workspace.create_score("Chat Quartet", fixtures.quartet(bars=8))

    print("the model is a stub, and the run cannot reach a provider")
    probe = drive(jig_slug, ("get_score_info", {}))
    check(probe.turns >= 2,
          f"the stubbed model answered the agent {probe.turns} times")
    check(not _ATTEMPTED, "no socket was connected during the run")
    check(bool(probe.offered), f"it was handed {len(probe.offered)} tools")

    print("\nthe tools the model is offered are the ones chat.py registers")
    registered = [t.__name__ for t in chat.TOOLS]
    check(sorted(probe.offered) == sorted(registered),
          "the offered list and chat.TOOLS agree "
          f"({len(probe.offered)} vs {len(registered)})")
    for name in ("add_element", "move_element", "duplicate_element", "strip_notes"):
        check(name in probe.offered,
              f"'{name}' is described to the model -- it cannot reach what it "
              "is not told about")

    print("\nevery tool DISPATCHES: called as the model calls it, on the real "
          "engine")
    answers: dict[str, list[dict]] = {}
    exercised: set[str] = set()
    for slug, steps in ((jig_slug, JIG_STEPS), (quartet_slug, QUARTET_STEPS)):
        for tool, args in steps:
            stub = drive(slug, (tool, args))
            exercised.add(tool)
            answer = stub.answer(tool)
            answers.setdefault(tool, []).append(answer)
            if stub.turns < 2:
                check(False, f"'{tool}': the stub was never asked for a second "
                             "turn, so the tool never ran")
                continue
            error = failed(answer)
            if error:
                check(False, f"'{tool}' answered with an error: {error[:200]}")
    if not any(f.startswith("'") for f in FAILURES):
        check(True, f"all {len(exercised)} tools answered without an error")

    print("\nthe ledger: every registered tool is driven above or excused")
    unaccounted = sorted(set(registered) - exercised - set(NOT_EXERCISED))
    for name in unaccounted:
        check(False, f"'{name}' is a registered tool that nothing calls and "
                     "that has no reason in NOT_EXERCISED")
    if not unaccounted:
        check(True, f"all {len(registered)} accounted for")
    stale = sorted(set(NOT_EXERCISED) - set(registered))
    for name in stale:
        check(False, f"NOT_EXERCISED names '{name}', which is no longer a tool")

    print("\nand the ARGUMENTS arrive shaped: what the model wrote is what the "
          "op was given")
    added = [a.get("details", {}) for a in answers.get("add_element", [])]
    for kind, anchor in (("dynamic", "offset"), ("text", "offset"),
                         ("fermata", "note"), ("articulation", "note")):
        check(any(d.get("kind") == kind and d.get("anchor") == anchor
                  and d.get("ordinal") is not None for d in added),
              f"add_element carried --kind {kind} through as the "
              f"{anchor}-anchored mark, and said where it landed")

    adjusted = (answers.get("adjust_element") or [{}])[0].get("details", {})
    check(adjusted.get("scale") == 1.5 and adjusted.get("size") == 18.0,
          "adjust_element passed `scale` on: 1.5 arrived as 18.0pt of the "
          f"12.0 default (got scale={adjusted.get('scale')}, "
          f"size={adjusted.get('size')})")

    moved = (answers.get("move_element") or [{}])[0].get("details", {})
    check(moved.get("op") == "move"
          and moved.get("to") == {"measure": 3, "offset": 1.5},
          f"move_element placed it at the bar and offset asked for: {moved.get('to')}")
    copied = (answers.get("duplicate_element") or [{}])[0].get("details", {})
    check(copied.get("op") == "duplicate" and copied.get("anchor") == "note",
          f"duplicate_element copied a note-attached mark: {copied.get('anchor')}")

    gone = (answers.get("remove_element") or [{}])[0].get("details", {})
    check(gone.get("op") == "remove" and gone.get("removed") == 1,
          f"remove_element took one mark off: {gone.get('removed')}")

    stripped = (answers.get("strip_notes") or [{}])[0].get("details", {})
    check((stripped.get("notes_removed") or 0) > 0,
          f"strip_notes emptied the staff: {stripped.get('notes_removed')} notes")

    selected = (answers.get("transpose_elements") or [{}])[0].get("details", {})
    check(selected.get("elements_requested") == 1
          and selected.get("elements_transposed") == 1
          and not selected.get("missing"),
          "transpose_elements passed the address through unchanged and moved "
          f"the one note it names: {selected}")

    print("\nevery mutating tool left a VERSION behind it, with its own op name")
    history = {v["op"] for v in workspace.load_meta(jig_slug)["versions"]}
    for op in ("add-element", "adjust-element", "move-element",
               "duplicate-element", "strip-notes", "whistle-fingerings",
               "guitar-tab", "chord-diagrams"):
        check(op in history, f"'{op}' is in the arrangement's history")

    print("\na tool's FAILURE comes back as data, so the model can correct it")
    bad = drive(quartet_slug,
                ("change_clef", {"part": "Trombone", "clef": "bass"}),
                ("change_clef", {"part": "Violin I", "clef": "treble"}))
    first = next((c for name, c in bad.returned if name == "change_clef"), {})
    check(isinstance(first, dict) and first.get("ok") is False,
          f"the bad part name came back as an answer, not a crash: {first}")
    check("Violin I" in str(first.get("error", "")),
          "and the error names the parts that DO exist, which is what lets the "
          f"model retry: {str(first.get('error'))[:160]}")
    second = [c for name, c in bad.returned if name == "change_clef"][-1]
    check(isinstance(second, dict) and second.get("ok") is True,
          f"the corrected call in the same turn went through: {second}")
    check(bad.turns >= 3,
          f"the loop kept going after the error ({bad.turns} model turns)")

    print("\nthe four surfaces an op has to reach, for the ops this build wired")
    surfaces = {
        "the engine op (ops.py)": (ROOT / "engine/scoranger_engine/ops.py",
                                   ["def add_element(", "def move_element(",
                                    "def remove_element(",
                                    "def strip_notes("]),
        "the CLI (cli.py)": (ROOT / "engine/scoranger_engine/cli.py",
                             ['"add-element"', '"move-element"',
                              '"duplicate-element"', '"remove-element"',
                              '"strip-notes"']),
        "the desktop agent (chat.py)": (ROOT / "engine/scoranger_engine/chat.py",
                                        ["def add_element(", "def move_element(",
                                         "def duplicate_element(",
                                         "def remove_element(",
                                         "def strip_notes("]),
        "the on-device bridge (bridge.py)": (ROOT / "ios/PythonApp/app/bridge.py",
                                             ['op == "add-element"',
                                              'op == "move-element"',
                                              'op == "duplicate-element"',
                                              'op == "remove-element"',
                                              'op == "strip-notes"']),
        "the on-device agent (ChatTools.swift)":
            (ROOT / "ios/Scoranger/ScoreModel/ChatTools.swift",
             ['name: "add_element"', 'name: "move_element"',
              'name: "duplicate_element"', 'name: "remove_element"',
              'name: "strip_notes"',
              'op: "add-element"', 'op: "move-element"',
              'op: "duplicate-element"', 'op: "remove-element"',
              'op: "strip-notes"']),
    }
    for where, (path, needles) in surfaces.items():
        text = path.read_text(encoding="utf-8") if path.exists() else ""
        missing = [n for n in needles if n not in text]
        check(not missing, f"{where} offers them"
                           + (f" -- missing {missing}" if missing else ""))

    print("\nboth agents know a word is an element, and what it cannot do")
    # Lyrics come off the scanner now, and an element the app can produce is
    # one a reader will ask to change. The two tool tables are written twice
    # -- once for the desktop agent and once for the on-device one -- so the
    # vocabulary has to be asserted in both or one of them goes quiet.
    for label, path in (("chat.py", ROOT / "engine/scoranger_engine/chat.py"),
                        ("ChatTools.swift",
                         ROOT / "ios/Scoranger/ScoreModel/ChatTools.swift")):
        text = path.read_text(encoding="utf-8")
        check("lyric" in text.lower(),
              f"{label} offers the lyric kind at all")
        check("make the words bigger" in text.lower(),
              f"{label} says it in the words a reader uses")
        # remove_element is in the list because it was NOT, and the gap it
        # hid is the one this whole block exists to catch: the op removes a
        # lyric perfectly well, and neither tool table said so, so no model
        # would ever have offered it.
        for verb in ("add_element", "adjust_element", "move_element",
                     "remove_element"):
            start = text.index(f"def {verb}(" if label.endswith(".py")
                               else f'Spec(name: "{verb}"')
            body = text[start:][:4000].lower()
            check("lyric" in body, f"{label}'s {verb} names the lyric kind")
        start = text.index("def adjust_element(" if label.endswith(".py")
                           else 'Spec(name: "adjust_element"')
        adjust = text[start:][:4000].lower()
        sentence = adjust[adjust.index("lyric"):]
        check("refus" in sentence and "offset" in sentence,
              f"{label} says a lyric REFUSES an offset, so the model asks for "
              "something else rather than sending a nudge nothing draws")

    print("\nand what the size argument SAYS, because that is what a model acts on")
    for label, path in (("chat.py", ROOT / "engine/scoranger_engine/chat.py"),
                        ("ChatTools.swift",
                         ROOT / "ios/Scoranger/ScoreModel/ChatTools.swift")):
        text = path.read_text(encoding="utf-8")
        # the tool's OWN description, not the sentences other tools use to
        # point at it ("size and position are adjust_element's business")
        start = text.index("def adjust_element(" if label.endswith(".py")
                           else 'Spec(name: "adjust_element"')
        adjust = text[start:][:3000].lower()
        check("size is relative" in adjust,
              f"{label} tells the model size is RELATIVE to the engraved default")
        check("an absolute point size (12 is the default)" not in text,
              f"{label} no longer describes size as a plain point size, which "
              "it stopped being when `scale` became the interface")

    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILED")
        for line in FAILURES:
            print(f"  - {line}")
        return 1
    print("OK: every chat tool dispatches to the engine with the arguments the "
          "model wrote, and the model that wrote them was a stub -- no key, no "
          "provider, no network")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
