"""Round 5: 2C as an S. Five staff lines run along an S -- two arcs of
opposite turn, tangent where they meet -- and one line leaves the S as a
note's stem, the notehead hung on it at Bravura's stemUpSE anchor.

Geometry. The upper bowl turns counter-clockwise round C1, the lower bowl
clockwise round C2, with C2 = C1 + (0, 2R). Line k sits at offset o_k; it has
radius R + o_k in the upper bowl and R - o_k in the lower, so every line is
continuous through the join (both meet at y = C1.y + R + o_k). Where a bowl
reaches its rightmost (lower) or leftmost (upper) point the line is heading
straight down, which is where a line can become a stem without a kink.
"""
import math
import os

import cairosvg
from PIL import Image, ImageDraw, ImageFont

from concepts import CLAY, CLAY_DEEP, CLAY_LIGHT, INK, INK_LIFT, IVORY, PAPER, S, glyph, radial, wrap
from compose import tile_png

HERE = os.path.dirname(os.path.abspath(__file__))
OCHRE, TEAL, CREAM, NAVY = "#E2A23B", "#1F5F5B", "#F3EADB", "#1B2A3A"
STEM_UP_SE = (1.18, 0.168)   # Bravura noteheadBlack, in staff spaces


def pt(c, r, deg):
    a = math.radians(deg)
    return c[0] + r * math.cos(a), c[1] + r * math.sin(a)


def s_line(c1, R, o, top=-35.0, bottom=145.0, lead=0.0, tail=0.0, peel=None, foot=0.0):
    """One line of the S. `top` is where it starts on the upper bowl (degrees,
    running counter-clockwise to the join at 90); `bottom` where it ends on the
    lower bowl (running clockwise from -90). `lead`/`tail` run it straight on
    along its tangent; `peel`, 'lower' or 'upper', ends it instead at that
    bowl's vertical tangent and drops it `foot` px as a stem.
    Returns (path d, stem foot point or None)."""
    c2 = (c1[0], c1[1] + 2 * R)
    ru, rl = R + o, R - o
    # upper bowl, travelling with decreasing angle from `top` to -270 (= 90)
    sx, sy = pt(c1, ru, top)
    a = math.radians(top)
    dx, dy = math.sin(a), -math.cos(a)                  # direction of travel
    d = f"M{sx - dx * lead:.1f} {sy - dy * lead:.1f} L{sx:.1f} {sy:.1f}"
    if peel == "upper":
        ex, ey = pt(c1, ru, 180)                        # leftmost: heading down
        sweep = (top - 180) % 360
        d += f" A{ru:.1f} {ru:.1f} 0 {1 if sweep > 180 else 0} 0 {ex:.1f} {ey:.1f} L{ex:.1f} {ey + foot:.1f}"
        return d, (ex, ey + foot)
    jx, jy = pt(c1, ru, 90)
    sweep = (top - 90) % 360
    d += f" A{ru:.1f} {ru:.1f} 0 {1 if sweep > 180 else 0} 0 {jx:.1f} {jy:.1f}"
    # lower bowl, increasing angle from -90
    if peel == "lower":
        ex, ey = pt(c2, rl, 0)                          # rightmost: heading down
        d += f" A{rl:.1f} {rl:.1f} 0 0 1 {ex:.1f} {ey:.1f} L{ex:.1f} {ey + foot:.1f}"
        return d, (ex, ey + foot)
    ex, ey = pt(c2, rl, bottom)
    sweep = bottom + 90
    d += f" A{rl:.1f} {rl:.1f} 0 {1 if sweep > 180 else 0} 1 {ex:.1f} {ey:.1f}"
    b = math.radians(bottom)
    tx, ty = -math.sin(b), math.cos(b)
    d += f" L{ex + tx * tail:.1f} {ey + ty * tail:.1f}"
    return d, None


def s_staff(c1, R, gap, width, colors, n=5, peel_line=None, peel="lower", foot=110,
            space=88, head_color=None, transform="", **kw):
    """The five lines; `colors` is one colour or a list per line. The peeled
    line ends in a notehead hung on its stem."""
    out, head = [], ""
    colors = colors if isinstance(colors, list) else [colors] * n
    for k in range(n):
        o = (k - (n - 1) / 2) * gap
        p = peel if k == peel_line else None
        d, end = s_line(c1, R, o, peel=p, foot=foot, **kw)
        out.append(f'<path d="{d}" fill="none" stroke="{colors[k]}" stroke-width="{width}" '
                   f'stroke-linecap="{"butt" if p else "round"}" stroke-linejoin="round"/>')
        if end:
            x, y = end
            hx = x + width / 2 - STEM_UP_SE[0] * space
            head = glyph("E0A4", hx, y + STEM_UP_SE[1] * space, space, head_color or colors[k])
    return f'<g transform="{transform}">{"".join(out)}{head}</g>'


def ink_bg():
    return f'<rect width="{S}" height="{S}" fill="url(#i)"/>', radial("i", INK_LIFT, INK, cy=0.38)


def v1():
    """The direct S: ivory on ink, whole and centred; the innermost line of the
    lower bowl leaves at its right and drops into an ochre note."""
    bg, defs = ink_bg()
    lines = [IVORY] * 5
    lines[0] = OCHRE
    body = s_staff((512, 300), 150, 26, 12, lines, peel_line=0, foot=96, space=80,
                   top=-20, bottom=160, lead=40, tail=40)
    return wrap(bg + body, defs)


def v2():
    """Taller than the tile: both terminals run off the top and bottom, and
    what stays is the S's spine -- still an S, never a 6."""
    bg, defs = ink_bg()
    lines = [IVORY] * 5
    lines[0] = OCHRE
    body = s_staff((512, 222), 290, 38, 16, lines, peel_line=0, foot=118, space=104,
                   top=-20, bottom=160, lead=400, tail=400)
    return wrap(bg + body, defs)

def v3():
    """Italic: the S leans like a letter set in italic, mid-century cream and
    ink, a clay sun sitting in the upper bowl."""
    sun = f'<circle cx="548" cy="318" r="92" fill="{CLAY}"/>'
    body = s_staff((512, 330), 150, 26, 13, [INK] * 5, peel_line=0, foot=100, space=82,
                   head_color=INK, top=-25, bottom=155, lead=70, tail=70,
                   transform="rotate(14 512 512)")
    return wrap(f'<rect width="{S}" height="{S}" fill="{CREAM}"/>{sun}{body}')


def v4():
    """A letterform: the S has ball terminals, and the balls are noteheads --
    one at each end of the middle line, stemmed."""
    bg, defs = ink_bg()
    c1, R, gap, w, space = (512, 300), 150, 26, 12, 76
    body = s_staff(c1, R, gap, w, [IVORY] * 5, top=-25, bottom=155)
    # stems drop from the middle line's two ends; heads at their feet
    t = pt(c1, R, -25)
    b = pt((c1[0], c1[1] + 2 * R), R, 155)
    stems = (f'<path d="M{t[0]:.1f} {t[1]:.1f} L{t[0]:.1f} {t[1] + 120:.1f}" stroke="{OCHRE}" stroke-width="{w}"/>'
             f'<path d="M{b[0]:.1f} {b[1]:.1f} L{b[0]:.1f} {b[1] - 130:.1f}" stroke="{OCHRE}" stroke-width="{w}"/>')
    heads = (glyph("E0A4", t[0] + w / 2 - 1.18 * space, t[1] + 120 + 0.168 * space, space, OCHRE)
             # the lower one hangs from a stem going UP from its left: stemDownNW-like
             + glyph("E0A4", b[0] - w / 2, b[1] + 0.168 * space * 0 - 0, space, OCHRE))
    return wrap(bg + body + stems + heads, defs)


def v5():
    """Hairline: five fine lines on clay, the S drawn like an engraved staff,
    and one heavy ink note inside the lower bowl -- the contrast is the point."""
    defs = ('<linearGradient id="g" x1="0" y1="0" x2="0" y2="1">'
            f'<stop offset="0" stop-color="{CLAY_LIGHT}"/><stop offset="1" stop-color="{CLAY_DEEP}"/></linearGradient>')
    body = s_staff((512, 300), 150, 24, 6, [CREAM] * 5, top=-20, bottom=160, lead=40, tail=40)
    from concepts import fragment
    note = fragment('<note pname="a" oct="4" dur="4" stem.dir="up"/>', (450, 560, 130, 230), INK, stem=0.5)
    return wrap(f'<rect width="{S}" height="{S}" fill="url(#g)"/>{body}{note}', defs)


def v6():
    """An S that speaks: four of its lines gather into the point of a speech
    bubble at the tail; the fifth leaves at the right and drops into a note."""
    bg, defs = ink_bg()
    c1, R, gap, w = (520, 290), 145, 26, 12
    tip = (300, 880)
    out = []
    end = 78                                     # the bowl is heading down and left here
    for k in range(1, 5):
        o = (k - 2) * gap
        d, _ = s_line(c1, R, o, top=-20, bottom=end)
        ex, ey = pt((c1[0], c1[1] + 2 * R), R - o, end)
        b = math.radians(end)
        cx, cy = ex - math.sin(b) * 120, ey + math.cos(b) * 120   # on the tangent
        out.append(f'<path d="{d} Q{cx:.1f} {cy:.1f} {tip[0]} {tip[1]}" fill="none" stroke="{IVORY}" '
                   f'stroke-width="{w}" stroke-linecap="round" stroke-linejoin="round"/>')
    peeled = s_staff(c1, R, gap, w, [OCHRE] * 5, n=5, peel_line=0, foot=96, space=80, top=-20)
    # keep only the peeled line (and its head) from that staff
    import re
    keep = re.findall(r'<path d="[^"]*" fill="none" stroke="[^"]*" stroke-width="[^"]*" stroke-linecap="butt"[^>]*/>', peeled)
    head = peeled[peeled.rfind('<path fill='):peeled.rfind('</g>')]
    return wrap(bg + "".join(out) + "".join(keep) + head, defs)

def v7():
    """Only the turn: the tile frames the middle of a much larger S -- its
    spine running corner to corner, both bowls cut by the edges."""
    defs = radial("p", PAPER, "#ECE3D3", cy=0.4)
    lines = [INK] * 5
    lines[0] = CLAY
    body = s_staff((512, 142), 370, 46, 18, lines, top=-20, bottom=160)
    from concepts import fragment
    note = fragment('<note pname="a" oct="4" dur="8" stem.dir="up"/>', (600, 560, 150, 260), CLAY, stem=0.5)
    return wrap(f'<rect width="{S}" height="{S}" fill="url(#p)"/>{body}{note}', defs)

def v8():
    """Two colours, one line: the upper bowl ivory, the lower ochre, as if the
    voice changes register in the turn."""
    bg, defs = ink_bg()
    up = s_staff((512, 300), 150, 26, 12, [IVORY] * 5, top=-20, bottom=-90.01, lead=40)
    lines = [OCHRE] * 5
    low = s_staff((512, 300), 150, 26, 12, lines, peel_line=0, foot=96, space=80,
                  top=89.99, bottom=160, tail=40)
    return wrap(bg + up + low, defs)


def v9():
    """Poster: the bowls filled -- a cream disc in the top, an ink disc in the
    bottom -- with the S drawn over them on ochre. Mid-century, flat, loud."""
    discs = (f'<circle cx="512" cy="300" r="96" fill="{CREAM}"/>'
             f'<circle cx="512" cy="600" r="96" fill="{INK}"/>')
    lines = [INK] * 5
    body = s_staff((512, 300), 150, 26, 13, lines, peel_line=0, foot=92, space=78,
                   head_color=CREAM, top=-20, bottom=160, lead=60, tail=60)
    return wrap(f'<rect width="{S}" height="{S}" fill="{OCHRE}"/>{discs}{body}')


def v10():
    """On its side: the S laid flat is a wave -- a staff that rises and falls
    like sound -- and a note rides its crest."""
    bg, defs = ink_bg()
    lines = [IVORY] * 5
    body = s_staff((512, 352), 160, 24, 11, lines, top=-10, bottom=170,
                   transform="rotate(90 512 512)")
    from concepts import fragment
    note = fragment('<note pname="a" oct="4" dur="8" stem.dir="up"/>', (300, 150, 130, 230), OCHRE, stem=0.5)
    return wrap(bg + body + note, defs)


VARIANTS = [("S1", "Whole S; a line drops into a note", v1),
            ("S2", "Taller than the tile", v2),
            ("S3", "Italic, mid-century, a clay sun", v3),
            ("S4", "Ball terminals that are noteheads", v4),
            ("S5", "Hairline staff, one heavy note", v5),
            ("S6", "An S that speaks", v6),
            ("S7", "Only the turn, cropped", v7),
            ("S8", "Colour changes in the turn", v8),
            ("S9", "Poster: filled bowls on ochre", v9),
            ("S10", "On its side: a wave", v10)]

if __name__ == "__main__":
    out = os.path.join(HERE, "out5")
    os.makedirs(out, exist_ok=True)
    f = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 22)
    big, gap, label = 260, 44, 60
    W = gap + 5 * (big + gap + 76)
    H = gap + 2 * (big + label + gap)
    sheet = Image.new("RGB", (W, H), "#E8E2D8")
    d = ImageDraw.Draw(sheet)
    for i, (key, line, make) in enumerate(VARIANTS):
        svg = make()
        open(os.path.join(out, f"{key}.svg"), "w").write(svg)
        cairosvg.svg2png(bytestring=svg.encode(), write_to=os.path.join(out, f"{key}-1024.png"),
                         output_width=1024, output_height=1024)
        x = gap + (i % 5) * (big + gap + 76)
        y = gap + (i // 5) * (big + label + gap)
        t = tile_png(svg, big * 2).resize((big, big), Image.LANCZOS)
        sheet.paste(t, (x, y), t)
        s = 60
        tt = tile_png(svg, s * 3).resize((s, s), Image.LANCZOS)
        sheet.paste(tt, (x + big + 10, y + big - s), tt)
        d.text((x, y + big + 10), f"{key}  {line}", fill="#24221F", font=f)
    sheet.save(os.path.join(out, "round5.png"))
    print("ok", sheet.size)
