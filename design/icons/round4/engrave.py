"""Engrave the icon's notation with Verovio + Bravura, so stems, beams and
noteheads are drawn by an engraver rather than by hand.

Writes <name>.svg (cleaned: no clef, no barline, staff lines optional) and
prints each fragment's ink bounding box in its own viewBox units.
"""
import io
import os
import re
import sys

import cairosvg
import verovio
from PIL import Image

OUT = os.path.dirname(os.path.abspath(__file__))

MEI = """<?xml version="1.0" encoding="UTF-8"?>
<mei xmlns="http://www.music-encoding.org/ns/mei" meiversion="5.0">
<music><body><mdiv><score>
<scoreDef><staffGrp><staffDef n="1" lines="5" clef.shape="G" clef.line="2"/></staffGrp></scoreDef>
<section><measure n="1" right="invis"><staff n="1"><layer n="1">
{notes}
</layer></staff></measure></section></score></mdiv></body></music></mei>"""

FRAGMENTS = {
    # the classic pair: two eighths under one beam, rising
    "pair": '<beam><note pname="g" oct="4" dur="8" stem.dir="up"/>'
            '<note pname="c" oct="5" dur="8" stem.dir="up"/></beam>',
    # one eighth with its flag
    "single": '<note pname="a" oct="4" dur="8" stem.dir="up"/>',
    # a phrase on a staff: quarter, beamed pair, quarter
    "phrase": '<note pname="e" oct="4" dur="4" stem.dir="up"/>'
              '<beam><note pname="g" oct="4" dur="8" stem.dir="up"/>'
              '<note pname="b" oct="4" dur="8" stem.dir="up"/></beam>'
              '<note pname="d" oct="5" dur="4" stem.dir="down"/>',
    # four sixteenths, a run
    "run": '<beam><note pname="e" oct="4" dur="16" stem.dir="up"/>'
           '<note pname="g" oct="4" dur="16" stem.dir="up"/>'
           '<note pname="b" oct="4" dur="16" stem.dir="up"/>'
           '<note pname="d" oct="5" dur="16" stem.dir="up"/></beam>',
}


def engrave(notes: str, keep_staff: bool, stem: float = 0.2) -> str:
    tk = verovio.toolkit()
    tk.setOptions({"font": "Bravura", "svgViewBox": True, "adjustPageWidth": True,
                   "adjustPageHeight": True, "header": "none", "footer": "none",
                   "breaks": "none", "pageMarginLeft": 0, "pageMarginRight": 0,
                   "pageMarginTop": 0, "pageMarginBottom": 0, "scale": 100,
                   "svgRemoveXlink": True, "stemWidth": stem, "staffLineWidth": 0.3})
    tk.loadData(MEI.format(notes=notes))
    svg = tk.renderToSVG(1)
    import xml.etree.ElementTree as ET
    ET.register_namespace("", "http://www.w3.org/2000/svg")
    ET.register_namespace("xlink", "http://www.w3.org/1999/xlink")
    root = ET.fromstring(svg)
    parents = {c: p for p in root.iter() for c in p}
    drop = []
    for el in root.iter():
        classes = (el.get("class") or "").split()
        if {"clef", "barLine", "meterSig", "keySig"} & set(classes):
            drop.append(el)
        if not keep_staff and "staff" in classes:
            # staff lines are the bare <path> children of g.staff
            drop.extend(c for c in el if c.tag.endswith("path"))
    for el in drop:
        parents[el].remove(el)
    return ET.tostring(root, encoding="unicode")


def ink_box(svg: str):
    """The ink's bounding box in the outer viewBox's units."""
    vb = [float(v) for v in re.search(r'viewBox="([^"]+)"', svg).group(1).split()]
    width = 2000
    png = cairosvg.svg2png(bytestring=svg.encode(), output_width=width)
    im = Image.open(io.BytesIO(png)).convert("RGBA")
    box = im.getchannel("A").getbbox()
    k = vb[2] / im.width
    return (vb[0] + box[0] * k, vb[1] + box[1] * k, (box[2] - box[0]) * k, (box[3] - box[1]) * k)


if __name__ == "__main__":
    for name, notes in FRAGMENTS.items():
        for staff in (False, True):
            svg = engrave(notes, staff)
            tag = f"{name}{'-staff' if staff else ''}"
            open(os.path.join(OUT, f"{tag}.svg"), "w").write(svg)
            print(tag, [round(v, 1) for v in ink_box(svg)])
