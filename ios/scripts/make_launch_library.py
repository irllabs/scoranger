"""Build a library the size of a working musician's, for the launch measurement.

    engine/.venv/bin/python ios/scripts/make_launch_library.py <workspace-dir>

The launch budget (300 ms from process start to the library's first rows,
`LaunchTiming`) is only meaningful against a library like Ali's: dozens of
pieces, most with several arrangements, each arrangement with a history. The
seeded test library is two scores, and `-seedLibraryShape` adds sixteen EMPTY
pieces, which costs the manifest nothing.

Everything goes through the vendored `bridge.handle`, the function the app
itself calls, so the database this writes is the one the app would have
written. The music is thesession.org's committed Drowsy Maggie settings
(ScorangerTests/Fixtures/thesession-tune-27.abc), retitled per piece.

The shape is fixed, so two runs make the same library apart from ids and
timestamps: 48 pieces, 141 arrangements (1 to 5 a piece), each with 1 to 6
versions (495 in all), four set lists and two 40-page books. Afterwards the
launch passes (sweep, tidy-pieces, number-bars-from-one) are run once, as a
device that has launched before has already run them.
"""

import json
import os
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
IOS = HERE.parent
ABC = IOS / "ScorangerTests" / "Fixtures" / "thesession-tune-27.abc"

PIECES = [
    "All Blues", "Autumn Leaves", "Balkan Ornaments", "Banish Misfortune",
    "Blue Bossa", "Ciribiribin", "Cooley's Reel", "Danny Boy", "Djangology",
    "Drowsy Maggie", "El Choclo", "Fascination", "Gnossienne", "Hejira",
    "Indifference", "Jeux d'enfants", "Kalinka", "La Foule", "La Vie en rose",
    "Les Feuilles mortes", "Libertango", "Manha de Carnaval", "Minor Swing",
    "Morrison's Jig", "Nuages", "Oblivion", "Orient Express", "Padam padam",
    "Por una cabeza", "Quelqu'un m'a dit", "Rakes of Mallow", "Reel des voyageurs",
    "Sous le ciel de Paris", "Swallowtail Jig", "Take Five", "The Butterfly",
    "The Kesh", "The Silver Spear", "Tico-Tico", "Under Paris Skies",
    "Valse musette", "Volver", "Whiskey Before Breakfast", "Yesterday",
    "Zorba", "Bal-musette", "Csardas", "Hava Nagila",
]

# a cheap op that writes a new version, cycled through for each arrangement's
# history; every one of them goes through `_mutate` like a reader's edit
HISTORY = [
    ("transpose", {"interval": "M2"}),
    ("measure-numbers", {"every": 1}),
    ("transpose", {"interval": "-M2"}),
    ("measure-numbers", {"system": True}),
    ("transpose", {"interval": "P4"}),
]


def settings(text: str) -> list[str]:
    """The file's X: blocks, each one a whole tune."""
    blocks, current = [], []
    for line in text.splitlines():
        if line.startswith("X:") and current:
            blocks.append("\n".join(current))
            current = []
        current.append(line)
    if current:
        blocks.append("\n".join(current))
    return [b for b in blocks if b.strip()]


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    target = Path(sys.argv[1]).resolve()
    if target.exists() and any(target.iterdir()):
        print(f"refusing: {target} is not empty")
        return 2
    target.mkdir(parents=True, exist_ok=True)

    os.environ["SCORANGER_WORKSPACE"] = str(target)
    sys.path.insert(0, str(IOS / "PythonApp" / "app"))
    import bridge  # noqa: E402  (the vendored one, beside the app's engine)

    def call(op: str, **args) -> dict:
        out = json.loads(bridge.handle(json.dumps({"op": op, "args": args})))
        if not out.get("ok"):
            raise SystemExit(f"{op} failed: {out.get('error')}")
        return out.get("result") or out

    call("configure", workspace=str(target))
    tunes = settings(ABC.read_text())
    scratch = Path(tempfile.mkdtemp(prefix="launch-library-"))

    arrangements = []
    for p, piece in enumerate(PIECES):
        for a in range(1 + p % 5):
            body = tunes[(p * 5 + a) % len(tunes)].splitlines()
            body = [f"T: {piece}" if line.startswith("T:") else line for line in body]
            path = scratch / f"{p:02d}-{a}.abc"
            path.write_text("\n".join(body) + "\n")
            name = piece if a == 0 else f"{piece} ({a + 1})"
            slug = call("import", path=str(path), name=name, piece=piece)["score"]
            for op, args in HISTORY[: (p + a) % 6]:
                call(op, score=slug, **args)
            arrangements.append(slug)
        print(f"  {p + 1:2d}/{len(PIECES)} {piece}", flush=True)

    for s, name in enumerate(["Friday gig", "Wedding set", "Session tunes", "Practice"]):
        for slug in arrangements[s::9][:12]:
            call("assign-setlist", setlist=name, score=slug)

    from pypdf import PdfWriter
    for name in ["Session Tunebook", "Real Book Excerpts"]:
        writer = PdfWriter()
        for _ in range(40):
            writer.add_blank_page(width=595, height=842)
        pdf = scratch / f"{name}.pdf"
        with pdf.open("wb") as fh:
            writer.write(fh)
        call("import-book", path=str(pdf), name=name)

    # the launch passes a device that has launched before has already run
    call("sweep")
    call("tidy-pieces")
    call("number-bars-from-one")
    m = call("manifest")
    versions = sum(len(s["versions"]) for s in m["scores"])
    print(json.dumps({"pieces": len(m["pieces"]), "arrangements": len(m["scores"]),
                      "versions": versions, "setlists": len(m["setlists"]),
                      "books": len(m["books"]),
                      "manifest_bytes": (target / "manifest.json").stat().st_size}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
