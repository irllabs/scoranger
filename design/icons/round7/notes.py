"""Round 7: D's quarter note becomes one larger eighth note (0.23.2).

The pair below came first and was turned down; the single eighth shipped.

Ali, 2026-10-21: "make the quarter note in the app icon a bit bigger so it's a
bit more visible on a small screen, and make the note two notes a major 3rd
apart (G and B) and make it two 8th notes with a connected stem".

Read as a treble clef, G and B are the second line and the middle line -- the
one pair of adjacent lines a major third apart -- so the notes sit on lines 3
and 2 (counted from the top, 0-based) of round 6's S, at the level stretch
where its middle stroke turns.

Each head sits on ITS OWN line at its own x, so neither drifts off the curve
(round 6's `beamed` placed a pair in one straight frame, which on the S puts
both heads about 6 px off their lines). Heads are Bravura's noteheadBlack,
turned to the staff where they sit; the stems are parallel and joined by one
beam. `size` scales the notes against the staff space: 1.0 is engraving
size, and anything below 1.6 keeps a head clear of the lines either side.
"""
import math
import os
import sys

import cairosvg
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "round6"))

from concepts import CLAY, CLAY_LIGHT, INK, IVORY, wrap  # noqa: E402
from compose import tile_png  # noqa: E402
from s7 import SShape, gpath, ink, paper  # noqa: E402

G_LINE, B_LINE, D_LINE = 3, 2, 1


def line_y(s, k, x):
    """Where line k crosses x, on whichever bowl x is in."""
    o = (k - 2) * s.gap
    u = x - s.c1[0]
    if u <= 0:
        r = s.ru + o
        return s.c1[1] + math.sqrt(r * r - u * u)
    r = s.rl - o
    return s.c2[1] - math.sqrt(r * r - u * u)


def line_angle(s, k, x):
    """The staff's direction at x on line k, in degrees."""
    h = 0.5
    return math.degrees(math.atan2(line_y(s, k, x + h) - line_y(s, k, x - h), 2 * h))


def pair(s, color, size, x_mid=512.0, spacing=2.5, stem=3.4, slant=0.35):
    """G then B as two eighths under one beam, stems up."""
    sp = s.gap
    k = sp * size / 250
    width = 1.18 * sp * size
    w = s.w * (1 + (size - 1) * 0.6)
    beam = 0.5 * sp * size
    xs = (x_mid - spacing * sp * size / 2, x_mid + spacing * sp * size / 2)
    heads, attach = [], []
    for x, line in zip(xs, (G_LINE, B_LINE)):
        y, a = line_y(s, line, x), line_angle(s, line, x)
        heads.append(f'<g transform="translate({x:.1f} {y:.1f}) rotate({a:.2f})">'
                     f'<path fill="{color}" transform="translate({-width / 2:.1f} 0) '
                     f'scale({k:.4f} {-k:.4f})" d="{gpath("E0A4")}"/></g>')
        # SMuFL's stemUpSE anchor: the head's right edge, a little above centre
        ax, ay = width / 2 - w / 2, -0.168 * sp * size
        r = math.radians(a)
        attach.append((x + ax * math.cos(r) - ay * math.sin(r),
                       y + ax * math.sin(r) + ay * math.cos(r)))
    # stem tops: engraving length from each head, the beam's slant reduced
    tops = [ay - stem * sp * size for _, ay in attach]
    mean, half = (tops[0] + tops[1]) / 2, (tops[1] - tops[0]) / 2 * slant
    tops = (mean - half, mean + half)
    parts = list(heads)
    for (ax, ay), t in zip(attach, tops):
        # ends inside the beam, so a slanted beam leaves no corner of it showing
        t += beam / 2
        parts.append(f'<rect x="{ax - w / 2:.1f}" y="{t:.1f}" width="{w:.1f}" '
                     f'height="{ay - t:.1f}" fill="{color}"/>')
    (x0, _), (x1, _) = attach
    parts.append(f'<path fill="{color}" d="M{x0 - w / 2:.1f} {tops[0]:.1f} L{x1 + w / 2:.1f} {tops[1]:.1f} '
                 f'L{x1 + w / 2:.1f} {tops[1] + beam:.1f} L{x0 - w / 2:.1f} {tops[0] + beam:.1f} Z"/>')
    return "".join(parts)


def eighth(s, color, size, line=D_LINE, x=512.0, stem=3.5):
    """One eighth note, stem up with Bravura's flag8thUp, its head on `line`."""
    sp = s.gap
    k = sp * size / 250
    width = 1.18 * sp * size
    w = s.w * (1 + (size - 1) * 0.6)
    y, a = line_y(s, line, x), line_angle(s, line, x)
    sx, top = width / 2 - w / 2, -stem * sp * size
    return (f'<g transform="translate({x:.1f} {y:.1f}) rotate({a:.2f})">'
            f'<path fill="{color}" transform="translate({-width / 2:.1f} 0) '
            f'scale({k:.4f} {-k:.4f})" d="{gpath("E0A4")}"/>'
            f'<rect x="{sx - w / 2:.1f}" y="{top:.1f}" width="{w:.1f}" '
            f'height="{-0.168 * sp * size - top:.1f}" fill="{color}"/>'
            f'<path fill="{color}" transform="translate({sx - w / 2:.1f} {top:.1f}) '
            f'scale({k:.4f} {-k:.4f})" d="{gpath("E240")}"/></g>')


def icon(size, clay_lines, dark=False, notes="eighth"):
    s = SShape(512, 480, 340, 430, 62, 20)
    bg, defs = ink() if dark else paper()
    base, accent = (IVORY, CLAY_LIGHT) if dark else (INK, CLAY)
    colors = [accent if k in clay_lines else base for k in range(5)]
    drawn = pair(s, accent, size) if notes == "pair" else eighth(s, accent, size)
    return wrap(bg + s.staff(colors) + drawn, defs)


#: The size that ships (C): the largest at which the head still clears the
#: lines either side of the one it sits on.
CHOSEN = 1.6

# The pair came first and Ali turned it down the same day: "the two notes look
# goofy; let's go to a single note again, but an 8th note". Kept, as a round.
VARIANTS = [
    ("pair-B", "the pair, 1.5x, clay on B", dict(size=1.5, clay_lines={B_LINE}, notes="pair")),
    ("A", "eighth, 1.3x, on the clay D line", dict(size=1.3, clay_lines={D_LINE})),
    ("B", "eighth, 1.5x, on the clay D line", dict(size=1.5, clay_lines={D_LINE})),
    ("C", "eighth, 1.6x, on the clay D line", dict(size=1.6, clay_lines={D_LINE})),
]

if __name__ == "__main__" and not sys.argv[1:]:
    out = os.path.join(HERE, "out")
    os.makedirs(out, exist_ok=True)
    font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 22)
    sizes = (300, 120, 60, 40)
    rows = [(key, label, icon(**kw)) for key, label, kw in VARIANTS]
    rows.append(("C-dark", "C on a dark home screen", icon(CHOSEN, {D_LINE}, dark=True)))
    W = 40 + sum(sizes) + 40 * len(sizes)
    H = len(rows) * 350 + 30
    sheet = Image.new("RGB", (W, H), "#E9E2D6")
    d = ImageDraw.Draw(sheet)
    for r, (key, label, svg) in enumerate(rows):
        open(os.path.join(out, f"{key}.svg"), "w").write(svg)
        cairosvg.svg2png(bytestring=svg.encode(), write_to=os.path.join(out, f"{key}-1024.png"),
                         output_width=1024, output_height=1024)
        x, y = 40, 20 + r * 350
        for px in sizes:
            t = tile_png(svg, px * 3).resize((px, px), Image.LANCZOS)
            sheet.paste(t, (x, y + 300 - px), t)
            x += px + 40
        d.text((40, y + 306), f"{key}  {label}", fill="#24221F", font=font)
    sheet.save(os.path.join(out, "round7.png"))
    print("ok", sheet.size)


def install():
    """The eighth at CHOSEN size goes into the app: the light and dark 1024s, RGB with no alpha as the
    App Store asks, and a picture of 0.23.1's icon beside it at the sizes a
    home screen draws."""
    import io
    root = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
    catalog = os.path.join(root, "ios", "Scoranger", "Assets.xcassets", "AppIcon.appiconset")
    # 0.23.1's icon from round 6's own sources, not the catalog this overwrites
    old = {look: Image.open(io.BytesIO(cairosvg.svg2png(
               url=os.path.join(HERE, "..", "round6", f"appicon-{look}.svg"),
               output_width=1024, output_height=1024))).convert("RGB")
           for look in ("light", "dark")}
    chosen = {"light": icon(CHOSEN, {D_LINE}), "dark": icon(CHOSEN, {D_LINE}, dark=True)}
    new = {}
    for look, svg in chosen.items():
        open(os.path.join(HERE, f"appicon-{look}.svg"), "w").write(svg)
        png = cairosvg.svg2png(bytestring=svg.encode(), output_width=1024, output_height=1024)
        new[look] = Image.open(io.BytesIO(png)).convert("RGB")
        name = "icon-1024.png" if look == "light" else "icon-1024-dark.png"
        new[look].save(os.path.join(catalog, name))

    font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 20)
    sizes = (180, 120, 60, 40)
    W, H = 60 + 2 * (sum(sizes) + 30 * len(sizes)) + 40, 2 * 250 + 40
    sheet = Image.new("RGB", (W, H), "#E9E2D6")
    d = ImageDraw.Draw(sheet)
    mask_cache = {}
    for row, look in enumerate(("light", "dark")):
        y = 30 + row * 250
        x = 40
        for label, im in (("0.23.1", old[look]), ("0.23.2", new[look])):
            d.text((x, y + 190), f"{label} {look}", fill="#24221F", font=font)
            for px in sizes:
                t = im.resize((px * 3, px * 3), Image.LANCZOS)
                if px not in mask_cache:
                    m = Image.new("L", (px * 3, px * 3), 0)
                    ImageDraw.Draw(m).rounded_rectangle((0, 0, px * 3 - 1, px * 3 - 1),
                                                        radius=int(px * 3 * 0.2237), fill=255)
                    mask_cache[px] = m
                t.putalpha(mask_cache[px])
                t = t.resize((px, px), Image.LANCZOS)
                sheet.paste(t, (x, y + 180 - px), t)
                x += px + 30
            x += 40
    sheet.save(os.path.join(HERE, "before-after.png"))
    print("installed; comparison at", os.path.join(HERE, "before-after.png"))


if __name__ == "__main__" and sys.argv[1:] == ["install"]:
    install()
