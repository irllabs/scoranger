"""Build the library `measure_open.sh` opens scores from.

    engine/.venv/bin/python ios/scripts/make_open_library.py <corpus-dir> <workspace-dir>

One arrangement per `<corpus-dir>/*.musicxml`, through the vendored
`bridge.handle` -- the function the app itself calls -- so the database is the
one the app would have written (the same route as make_launch_library.py).

The corpus files are copies of version files from a real library, and the
point of the benchmark is to open THOSE bytes. An import writes the notation
back out through music21, which is not guaranteed to be byte-identical to
what came in, so after the import each arrangement's v001 is overwritten with
its corpus file exactly. The launch passes are run afterwards, as on a device
that has launched before; one that writes a new version (number-bars-from-one
on a score whose first full bar is 0) is what that device would open too.

Last, a DECOY: a four-bar melody imported after everything else, so it is
the most recently changed arrangement. At launch the app selects that one by
itself (`AppState.adoptDefaultSelection`) and engraves it behind the library;
with the decoy there, that engrave warms the Verovio toolkit -- as any
earlier open in a running app has -- and never pre-engraves a score being
measured, which would make its open a cache hit.

Writes `<workspace-dir>/open-bench.json`: {corpus stem: slug} and the decoy's
slug, which the script uses to name the arrangement to open. The corpus is gitignored and some
of it is copyrighted; nothing here or in the workspace is committed.
"""

import hashlib
import json
import os
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
IOS = HERE.parent


def corpus_digest(files: list[Path]) -> str:
    h = hashlib.sha256()
    for f in files:
        h.update(f.name.encode())
        h.update(f.read_bytes())
    return h.hexdigest()


DECOY = "open-bench-decoy"


def write_decoy(path: Path) -> None:
    """Four bars of quarter notes on one treble staff, written by music21."""
    from music21 import meter, note, stream

    part = stream.Part()
    part.append(meter.TimeSignature("4/4"))
    for pitch in "C4 D4 E4 F4 G4 A4 B4 C5 C5 B4 A4 G4 F4 E4 D4 C4".split():
        part.append(note.Note(pitch, quarterLength=1))
    score = stream.Score([part])
    score.write("musicxml", fp=str(path))


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    corpus = Path(sys.argv[1]).resolve()
    target = Path(sys.argv[2]).resolve()
    files = sorted(corpus.glob("*.musicxml"))
    if not files:
        print(f"no .musicxml files in {corpus}")
        return 2
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
    slugs: dict[str, str] = {}
    for f in files:
        slug = call("import", path=str(f), name=f.stem)["score"]
        path = Path(call("version-file", score=slug)["path"])
        shutil.copyfile(f, path)
        slugs[f.stem] = slug
        print(f"  {f.stem} -> {slug} ({path.name})", flush=True)

    call("sweep")
    call("tidy-pieces")
    call("number-bars-from-one")

    decoy_file = target.parent / f"{DECOY}.musicxml"
    write_decoy(decoy_file)
    try:
        decoy = call("import", path=str(decoy_file), name=DECOY)["score"]
    finally:
        decoy_file.unlink()
    m = call("manifest")
    newest = max(m["scores"], key=lambda s: s["versions"][-1]["time"] if s["versions"] else "")
    if newest["slug"] != decoy:
        raise SystemExit(f"the decoy is not the most recent arrangement: {newest['slug']} is")
    versions = {s["slug"]: len(s["versions"]) for s in m["scores"]}
    (target / "open-bench.json").write_text(json.dumps(
        {"corpus_sha256": corpus_digest(files), "slugs": slugs, "decoy": decoy,
         "versions": versions}, indent=2) + "\n")
    print(json.dumps({"arrangements": len(m["scores"]), "versions": versions}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
