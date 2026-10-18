"""Round 4: three variants each of Stave into voice, Rising thought, Fermata.

Notes are Verovio-engraved (Bravura) or set from Bravura's outlines; where a
staff line itself turns into a stem, the notehead hangs on it at Bravura's
stemUpSE anchor (1.18, 0.168 spaces), the point an engraver attaches it.
"""
import math
import os

import cairosvg
from PIL import Image, ImageDraw, ImageFont

from concepts import (BRAVURA, CLAY, CLAY_DEEP, CLAY_LIGHT, INK, INK_LIFT, IVORY, PAPER,
                      S, fragment, glyph, radial, wrap)
from compose import tile_png

HERE = os.path.dirname(os.path.abspath(__file__))
OCHRE, TEAL, CREAM = "#E2A23B", "#1F5F5B", "#F3EADB"

EIGHTH = '<note pname="a" oct="4" dur="8" stem.dir="up"/>'
QUARTER = '<note pname="a" oct="4" dur="4" stem.dir="up"/>'
PAIR = ('<beam><note pname="g" oct="4" dur="8" stem.dir="up"/>'
        '<note pname="c" oct="5" dur="8" stem.dir="up"/></beam>')


# ---------------------------------------------------------------- stave rings
def rings(c, R, gap, color, width, skip_inner=False, n=5):
    """Five lines in from the lower left, each tangent to its ring at the
    upper left, running clockwise round and stopping short of the bundle."""
    t0 = math.radians(225)
    tx, ty = math.cos(math.radians(-45)), math.sin(math.radians(-45))
    stop = math.radians(160)
    out = []
    for k in range(n):
        if skip_inner and k == 0:
            continue
        r = R + (k - 2) * gap
        px, py = c[0] + r * math.cos(t0), c[1] + r * math.sin(t0)
        sx, sy = px - tx * 1200, py - ty * 1200
        ex, ey = c[0] + r * math.cos(stop), c[1] + r * math.sin(stop)
        out.append(f'<path d="M{sx:.1f} {sy:.1f} L{px:.1f} {py:.1f} A{r} {r} 0 1 1 {ex:.1f} {ey:.1f}" '
                   f'fill="none" stroke="{color}" stroke-width="{width}" stroke-linecap="round"/>')
    return "".join(out)


def stave_a():
    """Ink and ivory, heavier lines, an engraved eighth in clay inside."""
    c, R, gap = (566, 452), 226, 32
    body = rings(c, R, gap, IVORY, 13)
    note = fragment(EIGHTH, (c[0] - 80, c[1] - 128, 150, 236), CLAY_LIGHT, stem=0.5)
    return wrap(f'<rect width="{S}" height="{S}" fill="url(#i)"/>{body}{note}',
                radial("i", INK_LIFT, INK, cy=0.38))


def stave_b():
    """Mid-century print: cream ground, a clay sun set off-register behind
    the rings, ink lines over it, and a cream quarter note."""
    c, R, gap = (566, 452), 220, 30
    sun = f'<circle cx="{c[0] + 26}" cy="{c[1] + 22}" r="{R - 2 * gap - 8}" fill="{CLAY}"/>'
    body = rings(c, R, gap, INK, 14)
    note = fragment(QUARTER, (c[0] - 64, c[1] - 116, 128, 214), CREAM, stem=0.5)
    return wrap(f'<rect width="{S}" height="{S}" fill="{CREAM}"/>{sun}{body}{note}')


def stave_c():
    """The innermost staff line peels off the ring, drops straight down, and
    ends as a stem with a notehead on it: the line becomes the note."""
    c, R, gap, w = (566, 452), 226, 32, 13
    body = rings(c, R, gap, IVORY, w, skip_inner=True)
    r = R - 2 * gap
    t0 = math.radians(225)
    tx, ty = math.cos(math.radians(-45)), math.sin(math.radians(-45))
    px, py = c[0] + r * math.cos(t0), c[1] + r * math.sin(t0)
    sx, sy = px - tx * 1200, py - ty * 1200
    peel = math.radians(300)                     # where it leaves the ring
    qx, qy = c[0] + r * math.cos(peel), c[1] + r * math.sin(peel)
    foot = c[1] + 112                            # where the stem ends
    line = (f'<path d="M{sx:.1f} {sy:.1f} L{px:.1f} {py:.1f} A{r} {r} 0 0 1 {qx:.1f} {qy:.1f} '
            f'L{qx:.1f} {foot}" fill="none" stroke="{OCHRE}" stroke-width="{w}" '
            f'stroke-linecap="butt" stroke-linejoin="round"/>')
    space = 92
    hx = qx + w / 2 - 1.18 * space
    head = glyph("E0A4", hx, foot + 0.168 * space, space, OCHRE)
    return wrap(f'<rect width="{S}" height="{S}" fill="url(#i)"/>{body}{line}{head}',
                radial("i", INK_LIFT, INK, cy=0.38))


# ------------------------------------------------------------ rising thought
def trail(points, fill, music=EIGHTH):
    """Notes along a path, each engraved, each its own size: (x, y, height)."""
    return "".join(fragment(music, (x - h * 0.3, y - h, h * 0.6, h), fill, stem=0.5)
                   for x, y, h in points)


def rising_a():
    """Four eighths rising and growing, and a staff that is only there where
    the music has become real: it fades in under the larger notes."""
    pts = [(196, 840, 110), (318, 744, 170), (470, 622, 250)]
    defs = (radial("p", PAPER, "#ECE3D3", cy=0.38)
            + '<linearGradient id="f" x1="0" y1="0" x2="1" y2="0">'
              '<stop offset="0.35" stop-color="#151413" stop-opacity="0"/>'
              '<stop offset="0.85" stop-color="#151413" stop-opacity="0.85"/></linearGradient>')
    staff = "".join(f'<rect x="0" y="{560 + i * 46}" width="{S}" height="7" fill="url(#f)"/>' for i in range(5))
    big = fragment(EIGHTH, (600, 214, 260, 520), INK, stem=0.5)
    return wrap(f'<rect width="{S}" height="{S}" fill="url(#p)"/>{staff}{trail(pts, INK)}{big}', defs)


def rising_b():
    """Scale as provocation: the thought arrives too big for the tile. The
    last note is cropped by the edge; the trail behind it is small and exact."""
    pts = [(170, 900, 92), (262, 820, 138), (382, 712, 208)]
    big = fragment(EIGHTH, (470, -10, 560, 1080), INK, stem=0.5)
    return wrap(f'<rect width="{S}" height="{S}" fill="url(#p)"/>{trail(pts, INK)}{big}',
                radial("p", PAPER, "#ECE3D3", cy=0.38))


def rising_c():
    """The whole idea in one line: thought-bubble dots become noteheads,
    noteheads grow stems, and the last pair is beamed -- notation forming."""
    dots = "".join(f'<circle cx="{x}" cy="{y}" r="{r}" fill="{CLAY}"/>'
                   for x, y, r in [(150, 900, 16), (212, 838, 24)])
    heads = glyph("E0A4", 262, 790, 60, INK)
    pts = [(372, 718, 150), (480, 622, 214)]
    pair = fragment(PAIR, (560, 190, 330, 470), INK, stem=0.5)
    return wrap(f'<rect width="{S}" height="{S}" fill="url(#p)"/>{dots}{heads}'
                f'{trail(pts, INK, QUARTER)}{pair}', radial("p", PAPER, "#ECE3D3", cy=0.38))


# ------------------------------------------------------------------ fermata
def fermata_path(code):
    import re
    return re.search(r' d="([^"]+)"', open(f"{BRAVURA}/{code}.xml").read()).group(1)


def fermata_a():
    """One colour, as a fermata is: ivory on ink, set large and centred."""
    k = 330 / 250
    x, y = 512 - 304 * k, 540 + 64 * k
    return wrap(f'<rect width="{S}" height="{S}" fill="url(#i)"/>'
                f'<path fill="{IVORY}" transform="translate({x:.1f} {y:.1f}) scale({k} {-k})" '
                f'd="{fermata_path("E4C0")}"/>', radial("i", INK_LIFT, INK, cy=0.36))


def fermata_b():
    """Ink on clay: a half note under its fermata, both set by Verovio -- the
    hold, and what is held. No staff: at 60 px it would only be noise."""
    import re
    from engrave import MEI
    import verovio
    mei = MEI.format(notes='<note xml:id="n1" pname="b" oct="4" dur="2" stem.dir="up"/>')
    mei = mei.replace("</staff></measure>", '</staff><fermata startid="#n1" place="above"/></measure>')
    music = fragment_mei(mei, (292, 150, 440, 724), INK, staff=False)
    defs = ('<linearGradient id="g" x1="0" y1="0" x2="0" y2="1">'
            f'<stop offset="0" stop-color="{CLAY_LIGHT}"/><stop offset="1" stop-color="{CLAY_DEEP}"/></linearGradient>')
    return wrap(f'<rect width="{S}" height="{S}" fill="url(#g)"/>{music}', defs)


def fragment_mei(mei, box, fill, staff=True, stem=0.5):
    """fragment() for a whole MEI document (control events such as a fermata)."""
    import engrave as e
    original = e.MEI
    e.MEI = "{notes}"
    try:
        return fragment(mei, box, fill, staff=staff, stem=stem)
    finally:
        e.MEI = original


def fermata_c():
    """Two fermatas, above and below, closing on one point: an eye.
    The score looking back."""
    k = 300 / 250
    up, down = fermata_path("E4C0"), fermata_path("E4C1")
    x = 512 - 304 * k
    above = (f'<path fill="{IVORY}" transform="translate({x:.1f} {560:.1f}) scale({k} {-k})" d="{up}"/>')
    # fermataBelow: its arc opens upward, its dot at the top; shift it down so
    # the two dots coincide
    below = (f'<path fill="{IVORY}" transform="translate({x:.1f} {560 - 104 * k:.1f}) scale({k} {-k})" d="{down}"/>')
    return wrap(f'<rect width="{S}" height="{S}" fill="url(#i)"/>{above}{below}',
                radial("i", INK_LIFT, INK, cy=0.4))


ROWS = [
    ("Stave into voice", [("2a", "Ink and ivory, an eighth in clay", stave_a),
                          ("2b", "Mid-century print, a clay sun", stave_b),
                          ("2c", "The line becomes the note", stave_c)]),
    ("Rising thought", [("6a", "A staff fades in under the music", rising_a),
                        ("6b", "Too big for the tile", rising_b),
                        ("6c", "Dots become notes, notes a phrase", rising_c)]),
    ("Fermata", [("3a", "One colour, ivory on ink", fermata_a),
                 ("3b", "The hold over a held note", fermata_b),
                 ("3c", "Two fermatas: an eye", fermata_c)]),
]

if __name__ == "__main__":
    out = os.path.join(HERE, "out4")
    os.makedirs(out, exist_ok=True)
    f = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 26)
    fb = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 30)
    fs = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 20)
    big, gap, label, head = 340, 56, 70, 56
    W = gap + 3 * (big + gap + 88)
    H = 3 * (head + big + label) + 2 * gap + gap
    sheet = Image.new("RGB", (W, H), "#E8E2D8")
    d = ImageDraw.Draw(sheet)
    y = gap
    for row_title, items in ROWS:
        d.text((gap, y), row_title, fill="#24221F", font=fb)
        y += head
        for i, (key, line, make) in enumerate(items):
            svg = make()
            open(os.path.join(out, f"{key}.svg"), "w").write(svg)
            cairosvg.svg2png(bytestring=svg.encode(), write_to=os.path.join(out, f"{key}-1024.png"),
                             output_width=1024, output_height=1024)
            x = gap + i * (big + gap + 88)
            t = tile_png(svg, big * 2).resize((big, big), Image.LANCZOS)
            sheet.paste(t, (x, y), t)
            s = 60
            tt = tile_png(svg, s * 3).resize((s, s), Image.LANCZOS)
            sheet.paste(tt, (x + big + 16, y + big - s), tt)
            d.text((x, y + big + 12), f"{key}  {line}", fill="#24221F", font=f)
        y += big + label
    sheet.save(os.path.join(out, "round4.png"))
    print("ok", sheet.size)
