"""Round 6: S7 developed. A larger S, cropped by the tile, with the proportions
of a typeface S -- the lower bowl larger than the upper, which is what stops
it reading upside down -- and notes written ON its five lines.

A note is placed in the staff's own frame: x along the staff, y across it,
positions counted in half-spaces from the middle line (+ is up, toward line
1). Its head is Bravura's noteheadBlack (or noteheadHalf) at one staff space
high, its stem hangs from the stemUpSE / stemDownNW anchors and is the staff
line's own weight, and the whole note is turned to the staff's direction at
that point -- so on the curve it leans the way the staff does.
"""
import math
import os

import cairosvg
from PIL import Image, ImageDraw, ImageFont

from concepts import CLAY, CLAY_DEEP, CLAY_LIGHT, INK, INK_LIFT, IVORY, PAPER, S, BRAVURA, radial, wrap
from compose import tile_png

HERE = os.path.dirname(os.path.abspath(__file__))
OCHRE, CREAM = "#E2A23B", "#F3EADB"
import re
_D = {}


def gpath(code):
    if code not in _D:
        _D[code] = re.search(r' d="([^"]+)"', open(f"{BRAVURA}/{code}.xml").read()).group(1)
    return _D[code]


class SShape:
    """The S's centreline: upper bowl radius ru round c1 (counter-clockwise),
    lower bowl radius rl round c2 = c1 + (0, ru + rl) (clockwise)."""

    def __init__(self, cx, join_y, ru, rl, gap, width, top=-62, bottom=118):
        self.c1 = (cx, join_y - ru)
        self.c2 = (cx, join_y + rl)
        self.ru, self.rl, self.gap, self.w = ru, rl, gap, width
        self.top, self.bottom = top, bottom

    def line(self, k):
        """Line k (0 = top line of the staff, the side a stem goes up to)."""
        o = (k - 2) * self.gap
        ru, rl = self.ru + o, self.rl - o
        a = math.radians(self.top)
        sx, sy = self.c1[0] + ru * math.cos(a), self.c1[1] + ru * math.sin(a)
        jx, jy = self.c1[0], self.c1[1] + ru
        b = math.radians(self.bottom)
        ex, ey = self.c2[0] + rl * math.cos(b), self.c2[1] + rl * math.sin(b)
        large_u = 1 if (self.top - 90) % 360 > 180 else 0
        large_l = 1 if self.bottom + 90 > 180 else 0
        # run on along the tangents far past the tile, so nothing ends in view
        dx, dy = math.sin(a), -math.cos(a)
        tx, ty = -math.sin(b), math.cos(b)
        # the start is already off the tile; only the tail runs on
        return (f"M{sx:.1f} {sy:.1f} "
                f"A{ru:.1f} {ru:.1f} 0 {large_u} 0 {jx:.1f} {jy:.1f} "
                f"A{rl:.1f} {rl:.1f} 0 {large_l} 1 {ex:.1f} {ey:.1f} L{ex + tx * 900:.1f} {ey + ty * 900:.1f}")

    def frame(self, bowl, deg):
        """Point on the centreline and the staff's direction there (degrees)."""
        a = math.radians(deg)
        if bowl == "upper":
            c, r = self.c1, self.ru
            travel = (math.sin(a), -math.cos(a))
        else:
            c, r = self.c2, self.rl
            travel = (-math.sin(a), math.cos(a))
        p = (c[0] + r * math.cos(a), c[1] + r * math.sin(a))
        return p, math.degrees(math.atan2(travel[1], travel[0]))

    def staff(self, colors):
        colors = colors if isinstance(colors, list) else [colors] * 5
        return "".join(f'<path d="{self.line(k)}" fill="none" stroke="{colors[k]}" '
                       f'stroke-width="{self.w}" stroke-linecap="butt"/>' for k in range(5))

    def note(self, bowl, deg, pos, color, stem="up", head="E0A4", length=3.5, flag=None):
        """A note at half-space position `pos` (0 = middle line, + up)."""
        p, ang = self.frame(bowl, deg)
        sp, w = self.gap, self.w
        k = sp / 250
        y = -pos * sp / 2
        width = 1.18 * sp if head == "E0A4" else 1.18 * sp
        hx = -width / 2
        parts = [f'<path fill="{color}" transform="translate({hx:.1f} {y:.1f}) scale({k} {-k})" d="{gpath(head)}"/>']
        if stem == "up":
            x = hx + width - w / 2
            parts.append(f'<rect x="{x - w / 2:.1f}" y="{y - length * sp:.1f}" width="{w}" '
                         f'height="{length * sp - 0.168 * sp:.1f}" fill="{color}"/>')
            if flag:
                parts.append(f'<path fill="{color}" transform="translate({x - w / 2:.1f} {y - length * sp:.1f}) '
                             f'scale({k} {-k})" d="{gpath("E240")}"/>')
        elif stem == "down":
            x = hx + w / 2
            parts.append(f'<rect x="{x - w / 2:.1f}" y="{y + 0.168 * sp:.1f}" width="{w}" '
                         f'height="{length * sp - 0.168 * sp:.1f}" fill="{color}"/>')
        return (f'<g transform="translate({p[0]:.1f} {p[1]:.1f}) rotate({ang:.2f})">'
                + "".join(parts) + "</g>")

    def beamed(self, bowl, deg, pos1, pos2, color, spacing=2.2):
        """Two eighths under one beam, stems up, in the staff's frame."""
        p, ang = self.frame(bowl, deg)
        sp, w = self.gap, self.w
        k = sp / 250
        width = 1.18 * sp
        xs = (-spacing * sp / 2, spacing * sp / 2)
        ys = (-pos1 * sp / 2, -pos2 * sp / 2)
        top = min(ys) - 3.5 * sp
        slope = (ys[1] - ys[0]) * 0.25
        parts = []
        stems = []
        for x0, y0 in zip(xs, ys):
            hx = x0 - width / 2
            parts.append(f'<path fill="{color}" transform="translate({hx:.1f} {y0:.1f}) scale({k} {-k})" d="{gpath("E0A4")}"/>')
            stems.append(hx + width - w / 2)
        t0, t1 = top - slope, top + slope
        for x, y0, t in zip(stems, ys, (t0, t1)):
            parts.append(f'<rect x="{x - w / 2:.1f}" y="{t:.1f}" width="{w}" height="{y0 - 0.168 * sp - t:.1f}" fill="{color}"/>')
        bt = 0.5 * sp
        parts.append(f'<path fill="{color}" d="M{stems[0] - w / 2:.1f} {t0:.1f} L{stems[1] + w / 2:.1f} {t1:.1f} '
                     f'L{stems[1] + w / 2:.1f} {t1 + bt:.1f} L{stems[0] - w / 2:.1f} {t0 + bt:.1f} Z"/>')
        return (f'<g transform="translate({p[0]:.1f} {p[1]:.1f}) rotate({ang:.2f})">'
                + "".join(parts) + "</g>")


def paper():
    return f'<rect width="{S}" height="{S}" fill="url(#p)"/>', radial("p", PAPER, "#ECE3D3", cy=0.4)


def ink():
    return f'<rect width="{S}" height="{S}" fill="url(#i)"/>', radial("i", INK_LIFT, INK, cy=0.38)


def v1():
    """The correction: bigger S, lower bowl larger, one clay quarter note
    sitting on the middle line where the staff runs level."""
    bg, defs = paper()
    s = SShape(512, 480, 340, 430, 62, 20)
    return wrap(bg + s.staff(INK) + s.note("upper", 90, 0, CLAY), defs)


def v2():
    """A melody riding the curve: three notes, each turned to the staff where
    it sits, climbing as the S turns."""
    bg, defs = paper()
    s = SShape(512, 480, 340, 430, 62, 20)
    notes = (s.note("upper", 132, -2, CLAY) + s.note("upper", 90, 1, CLAY)
             + s.note("lower", -52, 4, CLAY, stem="down"))
    return wrap(bg + s.staff(INK) + notes, defs)


def v3():
    """Night: ivory staff on ink, an ochre beamed pair on the level stretch."""
    bg, defs = ink()
    s = SShape(512, 480, 340, 430, 62, 20)
    return wrap(bg + s.staff(IVORY) + s.beamed("upper", 90, -1, 2, OCHRE), defs)


def v4():
    """The line that sings: one staff line in clay, and the note's head sits
    on exactly that line."""
    bg, defs = paper()
    s = SShape(512, 480, 340, 430, 62, 20)
    colors = [INK] * 5
    colors[1] = CLAY                                  # line 2 from the top: position +2
    return wrap(bg + s.staff(colors) + s.note("upper", 90, 2, CLAY), defs)


def v5():
    """Bigger still, mid-century: cream ground, ink staff cut by every edge,
    one ochre half note -- the open head -- held on the turn."""
    s = SShape(530, 500, 380, 480, 62, 20)
    return wrap(f'<rect width="{S}" height="{S}" fill="{CREAM}"/>' + s.staff(INK)
                + s.note("upper", 90, 0, OCHRE, head="E0A3"))


VARIANTS = [("A", "Corrected: one note on the level", v1),
            ("B", "A melody riding the curve", v2),
            ("C", "Night: a beamed pair", v3),
            ("D", "The line that sings", v4),
            ("E", "Bigger, a half note held", v5)]

if __name__ == "__main__":
    out = os.path.join(HERE, "out6")
    os.makedirs(out, exist_ok=True)
    f = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 22)
    big, gap, label = 300, 44, 56
    W = gap + 5 * (big + gap + 76)
    H = gap + big + label + gap
    sheet = Image.new("RGB", (W, H), "#E8E2D8")
    d = ImageDraw.Draw(sheet)
    for i, (key, line, make) in enumerate(VARIANTS):
        svg = make()
        open(os.path.join(out, f"{key}.svg"), "w").write(svg)
        cairosvg.svg2png(bytestring=svg.encode(), write_to=os.path.join(out, f"{key}-1024.png"),
                         output_width=1024, output_height=1024)
        x = gap + i * (big + gap + 76)
        t = tile_png(svg, big * 2).resize((big, big), Image.LANCZOS)
        sheet.paste(t, (x, gap), t)
        s = 60
        tt = tile_png(svg, s * 3).resize((s, s), Image.LANCZOS)
        sheet.paste(tt, (x + big + 10, gap + big - s), tt)
        d.text((x, gap + big + 12), f"{key}  {line}", fill="#24221F", font=f)
    sheet.save(os.path.join(out, "round6.png"))
    print("ok", sheet.size)
