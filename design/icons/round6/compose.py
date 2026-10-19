"""Scoranger icon: a thought bubble holding engraved notation.

The notation is Verovio's, in Bravura (engrave.py), placed by its ink box.
The cloud is one construction: lobes on an inner ellipse, flatter along the
bottom, filled; two trailing dots down to the left. Everything is drawn on
Apple's 1024 grid; the tile itself is square (iOS applies the mask).
"""
import io
import math
import os
import re

import cairosvg
from PIL import Image, ImageDraw, ImageFont

from engrave import FRAGMENTS, engrave, ink_box

HERE = os.path.dirname(os.path.abspath(__file__))
S = 1024
CLAY, CLAY_DEEP, INK, IVORY, WHITE = "#CC5C2E", "#A8481F", "#1A1917", "#FAF7F1", "#FFFFFF"


def cloud(cx=520, cy=455, rx=245, ry=145, lobes=6, r_top=185, r_bottom=140, rot=-60):
    """Lobe circles on an ellipse, larger at the top, plus the body."""
    shapes = [f'<ellipse cx="{cx}" cy="{cy}" rx="{rx + 30}" ry="{ry + 20}"/>']
    for i in range(lobes):
        a = math.radians(rot + i * 360 / lobes)
        x, y = cx + rx * math.cos(a), cy + ry * math.sin(a)
        # sin < 0 is the top half (y grows downward)
        t = (1 - math.sin(a)) / 2
        r = r_bottom + (r_top - r_bottom) * t
        shapes.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{r:.1f}"/>')
    # the trail: two dots stepping down and left from the cloud's lower left
    shapes.append('<circle cx="296" cy="770" r="50"/>')
    shapes.append('<circle cx="206" cy="858" r="29"/>')
    return "".join(shapes)


def notation(name, staff, box, stem):
    """The engraved fragment, fitted into box=(x, y, w, h), centred."""
    svg = engrave(FRAGMENTS[name], staff, stem)
    bx, by, bw, bh = ink_box(svg)
    inner = re.sub(r"^<svg[^>]*>|</svg>\s*$", "", svg.strip())
    inner = inner.replace('color="black"', "")
    # stems and staff lines are stroked paths that inherit their colour
    inner = inner.replace(" stroke-width=", ' stroke="currentColor" stroke-width=')
    x, y, w, h = box
    k = min(w / bw, h / bh)
    ox = x + (w - bw * k) / 2 - bx * k
    oy = y + (h - bh * k) / 2 - by * k
    vb = re.search(r'viewBox="([^"]+)"', svg).group(1)
    vw, vh = [float(v) for v in vb.split()[2:]]
    return (f'<svg x="{ox:.1f}" y="{oy:.1f}" width="{vw * k:.1f}" height="{vh * k:.1f}" '
            f'viewBox="{vb}" overflow="visible">{inner}</svg>')


def icon(tile, cloud_fill, note_fill, name="pair", staff=False, box=(398, 282, 244, 356),
         stem=0.5, tile_gradient=None, shadow=False):
    defs, bg = "", f'<rect width="{S}" height="{S}" fill="{tile}"/>'
    if tile_gradient:
        top, bottom = tile_gradient
        defs += (f'<linearGradient id="g" x1="0" y1="0" x2="0" y2="1">'
                 f'<stop offset="0" stop-color="{top}"/><stop offset="1" stop-color="{bottom}"/>'
                 f'</linearGradient>')
        bg = f'<rect width="{S}" height="{S}" fill="url(#g)"/>'
    shade = ""
    if shadow:
        # a soft drop under the cloud, one notch darker than the tile
        defs += '<filter id="s" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="18"/></filter>'
        shade = f'<g fill="#000" opacity="0.16" filter="url(#s)" transform="translate(0 22)">{cloud()}</g>'
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {S} {S}" width="{S}" height="{S}">'
            f'<defs>{defs}</defs>{bg}{shade}'
            f'<g fill="{cloud_fill}">{cloud()}</g>'
            f'<g fill="{note_fill}" color="{note_fill}">{notation(name, staff, box, stem)}</g>'
            f'</svg>')


VARIANTS = {
    "A-clay": dict(tile=CLAY, cloud_fill=WHITE, note_fill=INK),
    "B-ink": dict(tile=INK, cloud_fill=IVORY, note_fill=CLAY),
    "C-ivory": dict(tile=IVORY, cloud_fill=CLAY, note_fill=WHITE),
    "D-clay-gradient": dict(tile=CLAY, cloud_fill=WHITE, note_fill=INK,
                            tile_gradient=("#DA6A3A", "#B9502A"), shadow=True),
    "E-run": dict(tile=CLAY, cloud_fill=WHITE, note_fill=INK, name="run",
                  box=(372, 300, 296, 330)),
    "F-single": dict(tile=INK, cloud_fill=IVORY, note_fill=CLAY, name="single",
                     box=(420, 282, 200, 356)),
}


def tile_png(svg, size):
    png = cairosvg.svg2png(bytestring=svg.encode(), output_width=size, output_height=size)
    im = Image.open(io.BytesIO(png)).convert("RGBA")
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size - 1, size - 1), radius=int(size * 0.2237), fill=255)
    im.putalpha(mask)
    return im


if __name__ == "__main__":
    os.makedirs(os.path.join(HERE, "out"), exist_ok=True)
    font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 24)
    rows = []
    for key, kw in VARIANTS.items():
        svg = icon(**kw)
        open(os.path.join(HERE, "out", f"{key}.svg"), "w").write(svg)
        cairosvg.svg2png(bytestring=svg.encode(), write_to=os.path.join(HERE, "out", f"{key}-1024.png"),
                         output_width=1024, output_height=1024)
        rows.append((key, svg))
    # contact sheet: each variant at 300, 120, 60, 29 on the warm grey of a desk
    sizes = (300, 120, 60, 29)
    W = 40 + sum(sizes) + 40 * len(sizes) + 60
    H = len(rows) * 360 + 40
    sheet = Image.new("RGB", (W, H), "#E9E2D6")
    d = ImageDraw.Draw(sheet)
    for r, (key, svg) in enumerate(rows):
        x, y = 40, 30 + r * 360
        for s in sizes:
            sheet.paste(tile_png(svg, s * 2).resize((s, s), Image.LANCZOS), (x, y + (300 - s)),
                        tile_png(svg, s * 2).resize((s, s), Image.LANCZOS))
            x += s + 40
        d.text((40, y + 308), key, fill="#3B3835", font=font)
    sheet.save(os.path.join(HERE, "out", "sheet.png"))
    print("ok")
