"""Compare two fidelity dumps of opened scores (measure_open.sh --fidelity).

    engine/.venv/bin/python ios/scripts/compare_open_fidelity.py <baseline-dir> <candidate-dir>

Prints IDENTICAL and exits 0 when every score in the baseline was opened the
same way in the candidate; otherwise prints each difference and exits 1.

A dump holds, per score (a directory named by the corpus stem):

  svg/page-NNN.svg   every page's SVG as handed to the rasteriser
  geometry.json      the hit-test model: page sizes, systems, bar frames, and
                     every element's kind, address and frame (0.01 precision)
  png/page-NNN.png   every page of the PUBLISHED document drawn at 1200 px
  reading.json       the open's timing, which is not compared except `pages`

Three checks because each catches what the others cannot. The PNGs are what a
reader sees, whatever route the pages took -- a build that skips the SVG stage
for a cached PDF is still held to them. The SVG is the engraving before our
rasteriser, so a change there is named at its source. The geometry is what a
lasso selects against, which no picture shows.

Verovio's element ids are NOT stable: it generates them afresh on every
load (`admw887`, `E050-admw887` for the glyph that element uses), so two
launches of the same build write SVGs whose bytes differ (measured,
2026-10-22). Every word-like token that some `id="..."` in the page defines
is therefore renamed to `idN`, N counted in order of first definition, before
comparing; references to it (`#id`, `xlink:href`) are renamed with it. What
is compared is the structure, every coordinate, path and attribute, and
which element refers to which -- only the names are taken out. The geometry
carries no ids at all (the session id is left out of it on purpose).

PNGs are compared by their decoded pixels when Pillow is importable (the
engine venv has it) -- the file bytes carry encoder choices that are not the
picture -- and by bytes otherwise.
"""

import hashlib
import json
import re
import sys
from pathlib import Path

try:
    from PIL import Image, ImageChops
except ImportError:  # compared by bytes instead; said in the output
    Image = None

ID_DEF = re.compile(r'\bid="([^"]+)"')
TOKEN = re.compile(r"[A-Za-z_][\w\-]*")


def canonical_svg(text: str) -> str:
    names: dict[str, str] = {}
    for m in ID_DEF.finditer(text):
        names.setdefault(m.group(1), f"id{len(names)}")
    if not names:
        return text

    def rename(m: re.Match) -> str:
        return names.get(m.group(0), m.group(0))

    # one pass over every word-like token, looked up whole, so a rename never
    # sees the output of another and a token that merely CONTAINS an id is
    # left alone
    return TOKEN.sub(rename, text)


def first_difference(a: str, b: str) -> str:
    al, bl = a.splitlines(), b.splitlines()
    for i, (x, y) in enumerate(zip(al, bl)):
        if x != y:
            return f"line {i + 1}: {x[:160]!r} != {y[:160]!r}"
    return f"lengths differ: {len(al)} lines vs {len(bl)}"


def compare_png(a: Path, b: Path) -> str | None:
    if Image is None:
        if hashlib.sha256(a.read_bytes()).digest() == hashlib.sha256(b.read_bytes()).digest():
            return None
        return "bytes differ (Pillow not available to compare pixels)"
    ia, ib = Image.open(a).convert("RGB"), Image.open(b).convert("RGB")
    if ia.size != ib.size:
        return f"size {ia.size} != {ib.size}"
    diff = ImageChops.difference(ia, ib)
    box = diff.getbbox()
    if box is None:
        return None
    # a pixel differs when ANY channel does; per band, so a one-level change
    # in one channel is not rounded away by a conversion to grey
    bands = [b.point(lambda v: 255 if v else 0) for b in diff.split()]
    mask = bands[0]
    for b in bands[1:]:
        mask = ImageChops.lighter(mask, b)
    pixels = mask.histogram()[255]
    worst = max(hi for _, hi in diff.getextrema())
    return f"{pixels} pixels differ (max channel delta {worst}) within {box}"


def compare_score(base: Path, cand: Path) -> list[str]:
    out: list[str] = []
    for kind, pattern in (("svg", "svg/page-*.svg"), ("png", "png/page-*.png")):
        bp = sorted(p.relative_to(base) for p in base.glob(pattern))
        cp = sorted(p.relative_to(cand) for p in cand.glob(pattern))
        if not bp:
            out.append(f"baseline has no {kind} pages")
        if bp != cp:
            out.append(f"{kind} pages: baseline {len(bp)}, candidate {len(cp)}")
        for rel in sorted(set(bp) & set(cp)):
            if kind == "svg":
                a = canonical_svg((base / rel).read_text())
                b = canonical_svg((cand / rel).read_text())
                if a != b:
                    out.append(f"{rel}: {first_difference(a, b)}")
            else:
                why = compare_png(base / rel, cand / rel)
                if why:
                    out.append(f"{rel}: {why}")
    bg, cg = base / "geometry.json", cand / "geometry.json"
    if not bg.exists():
        out.append("baseline has no geometry.json")
    elif not cg.exists():
        out.append("candidate has no geometry.json")
    else:
        a, b = bg.read_text(), cg.read_text()
        if a != b:
            out.append(f"geometry.json: {first_difference(a, b)}")
    try:
        bpages = json.loads((base / "reading.json").read_text()).get("pages")
        cpages = json.loads((cand / "reading.json").read_text()).get("pages")
        if bpages != cpages:
            out.append(f"published page count: {bpages} != {cpages}")
    except FileNotFoundError as e:
        out.append(f"missing {e.filename}")
    return out


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    base, cand = Path(sys.argv[1]), Path(sys.argv[2])
    scores = sorted(p.name for p in base.iterdir() if p.is_dir())
    if not scores:
        print(f"no scores in {base}")
        return 2
    problems: dict[str, list[str]] = {}
    for score in scores:
        if not (cand / score).is_dir():
            problems[score] = ["not in the candidate dump"]
            continue
        found = compare_score(base / score, cand / score)
        if found:
            problems[score] = found
    if not problems:
        print(f"IDENTICAL ({len(scores)} scores: {', '.join(scores)})"
              + ("" if Image else " [PNGs compared by bytes]"))
        return 0
    for score, found in problems.items():
        print(f"{score}: DIFFERENT")
        for line in found:
            print(f"  {line}")
    same = [s for s in scores if s not in problems]
    if same:
        print(f"identical: {', '.join(same)}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
