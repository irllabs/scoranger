"""Round 3: six concepts for Scoranger's icon, each a different idea.

Notation is engraved by Verovio (Bravura) or set from Bravura's own glyph
outlines, never drawn by hand. The one hand-drawn mark is the pencil loop in
"Circled", which is meant to look hand-drawn.
"""
import io
import math
import os
import re

import cairosvg
from PIL import Image, ImageDraw, ImageFont

from engrave import engrave, ink_box
from compose import tile_png

HERE = os.path.dirname(os.path.abspath(__file__))
S = 1024
CLAY, CLAY_DEEP, CLAY_LIGHT = "#CC5C2E", "#A8481F", "#E07A4C"
INK, INK_LIFT = "#151413", "#262422"
IVORY, PAPER = "#F6F1E8", "#FBF8F2"
BRAVURA = "/Users/ali.momeni/Documents/Code/scoranger/engine/.venv/lib/python3.14/site-packages/verovio/data/Bravura"


def glyph(code, x, y, space, fill):
    """A Bravura glyph with its SMuFL origin at (x, y); `space` is one staff
    space in px (SMuFL: 1 em = 4 spaces = 1000 units)."""
    d = re.search(r' d="([^"]+)"', open(f"{BRAVURA}/{code}.xml").read()).group(1)
    k = space / 250
    return f'<path fill="{fill}" transform="translate({x} {y}) scale({k} {-k})" d="{d}"/>'


def fragment(mei_notes, box, fill, staff=False, stem=0.5, fit="both"):
    """A Verovio-engraved fragment fitted into box=(x, y, w, h)."""
    svg = engrave(mei_notes, staff, stem)
    bx, by, bw, bh = ink_box(svg)
    inner = re.sub(r"^<svg[^>]*>|</svg>\s*$", "", svg.strip()).replace('color="black"', "")
    inner = inner.replace(" stroke-width=", ' stroke="currentColor" stroke-width=')
    x, y, w, h = box
    k = {"both": min(w / bw, h / bh), "width": w / bw, "height": h / bh}[fit]
    ox, oy = x + (w - bw * k) / 2 - bx * k, y + (h - bh * k) / 2 - by * k
    vb = re.search(r'viewBox="([^"]+)"', svg).group(1)
    vw, vh = [float(v) for v in vb.split()[2:]]
    return (f'<g fill="{fill}" color="{fill}"><svg x="{ox:.1f}" y="{oy:.1f}" width="{vw * k:.1f}" '
            f'height="{vh * k:.1f}" viewBox="{vb}" overflow="visible">{inner}</svg></g>')


def wrap(body, defs=""):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {S} {S}" width="{S}" height="{S}">'
            f'<defs>{defs}</defs>{body}</svg>')


def radial(id_, inner, outer, cx=0.5, cy=0.42, r=0.75):
    return (f'<radialGradient id="{id_}" cx="{cx}" cy="{cy}" r="{r}">'
            f'<stop offset="0" stop-color="{inner}"/><stop offset="1" stop-color="{outer}"/></radialGradient>')


# 1. CIRCLED -- a crop of a printed page, and a pencil loop around two notes:
# the app's own gesture (lasso a passage, then talk about it).
def circled():
    notes = ('<note pname="e" oct="4" dur="4" stem.dir="up"/>'
             '<beam><note pname="g" oct="4" dur="8" stem.dir="up"/><note pname="b" oct="4" dur="8" stem.dir="up"/></beam>'
             '<note pname="d" oct="5" dur="4" stem.dir="down"/>'
             '<note pname="c" oct="5" dur="4" stem.dir="down"/>')
    music = fragment(notes, (-120, 330, 1264, 380), INK, staff=True, stem=0.36, fit="width")
    # the loop: an ellipse drawn by hand -- radius wobbles, the end overshoots the start
    cx, cy, rx, ry, tilt = 470, 500, 128, 176, -10
    pts = []
    for i in range(0, 404):
        a = math.radians(-130 + i)
        wob = 1 + 0.025 * math.sin(3 * a + 0.6) + 0.012 * math.sin(5 * a)
        grow = 1 + 0.06 * (i / 404)
        x, y = rx * wob * grow * math.cos(a), ry * wob * grow * math.sin(a)
        t = math.radians(tilt)
        pts.append((cx + x * math.cos(t) - y * math.sin(t), cy + x * math.sin(t) + y * math.cos(t)))
    d = "M" + " L".join(f"{x:.1f} {y:.1f}" for x, y in pts)
    loop = (f'<path d="{d}" fill="none" stroke="{CLAY}" stroke-width="13" stroke-linecap="round" '
            f'stroke-linejoin="round"/>'
            f'<path d="{d}" fill="none" stroke="{CLAY}" stroke-width="5" stroke-linecap="round" '
            f'opacity="0.45" transform="translate(7 -5) rotate(1.5 {cx} {cy})"/>')
    defs = radial("p", PAPER, "#EEE7DA", cy=0.4)
    return wrap(f'<rect width="{S}" height="{S}" fill="url(#p)"/>{music}{loop}', defs)


# 2. STAVE INTO VOICE -- five staff lines run in from the corner and curl into
# a speech bubble: the score itself starts to speak. One notehead inside.
def stave_voice():
    c, R, gap, n = (566, 452), 226, 30, 5
    t0 = math.radians(225)                       # tangent point: upper left of each ring
    tx, ty = math.cos(math.radians(-45)), math.sin(math.radians(-45))   # heading up and right
    stop = math.radians(520 - 360)               # 160 degrees: short of the incoming lines
    lines = []
    for k in range(n):
        r = R + (k - 2) * gap
        px, py = c[0] + r * math.cos(t0), c[1] + r * math.sin(t0)
        sx, sy = px - tx * 1100, py - ty * 1100
        ex, ey = c[0] + r * math.cos(stop), c[1] + r * math.sin(stop)
        lines.append(f'<path d="M{sx:.1f} {sy:.1f} L{px:.1f} {py:.1f} A{r} {r} 0 1 1 {ex:.1f} {ey:.1f}" '
                     f'fill="none" stroke="{IVORY}" stroke-width="10" stroke-linecap="round"/>')
    head = glyph("E0A4", c[0] - 78, c[1] + 4, 118, CLAY_LIGHT)
    defs = radial("i", INK_LIFT, INK, cy=0.38)
    return wrap(f'<rect width="{S}" height="{S}" fill="url(#i)"/>{"".join(lines)}{head}', defs)


# 3. FERMATA -- the hold: an arc over a point, an eye that is listening.
# Bravura's own fermata, the dot in clay.
def fermata():
    space = 300
    arc = re.search(r' d="([^"]+)"', open(f"{BRAVURA}/E4C0.xml").read()).group(1)
    # the glyph is two subpaths: the arc, then the dot; draw them in two colours
    arc_d, dot_d = arc.split("z M", 1)
    k = space / 250
    x, y = 512 - 302 * k, 560 + 50 * k
    tr = f'translate({x:.1f} {y:.1f}) scale({k} {-k})'
    defs = radial("i", INK_LIFT, INK, cy=0.36)
    return wrap(f'<rect width="{S}" height="{S}" fill="url(#i)"/>'
                f'<path fill="{IVORY}" transform="{tr}" d="{arc_d}z"/>'
                f'<path fill="{CLAY}" transform="{tr}" d="M{dot_d}"/>', defs)


# 4. DUET -- two voices a second apart, stem up meets stem down; Verovio sets
# the heads side by side, touching, as an engraver must.
def duet():
    notes = ('</layer><layer n="2">')  # placeholder, replaced below
    mei_voices = ('<note pname="f" oct="4" dur="4" stem.dir="up"/>'
                  '</layer><layer n="2"><note pname="e" oct="4" dur="4" stem.dir="down"/>')
    music = fragment(mei_voices, (282, 212, 460, 600), IVORY, staff=False, stem=0.5)
    defs = ('<linearGradient id="g" x1="0" y1="0" x2="0" y2="1">'
            f'<stop offset="0" stop-color="{CLAY_LIGHT}"/><stop offset="1" stop-color="{CLAY_DEEP}"/></linearGradient>')
    return wrap(f'<rect width="{S}" height="{S}" fill="url(#g)"/>{music}', defs)


# 5. CARET -- notes on a staff, and where the next one goes, a text cursor:
# write music the way you write a sentence.
def caret():
    notes = ('<note pname="g" oct="4" dur="4" stem.dir="up"/>'
             '<beam><note pname="a" oct="4" dur="8" stem.dir="up"/><note pname="c" oct="5" dur="8" stem.dir="up"/></beam>')
    music = fragment(notes, (-60, 360, 740, 320), IVORY, staff=True, stem=0.4, fit="height")
    cursor = f'<rect x="720" y="300" width="26" height="430" rx="13" fill="{CLAY}"/>'
    defs = radial("i", INK_LIFT, INK, cy=0.4)
    return wrap(f'<rect width="{S}" height="{S}" fill="url(#i)"/>{music}{cursor}', defs)


# 6. RISING THOUGHT -- the thought bubble with the cloud taken away: its trail
# of dots become noteheads, growing, and the last one is a note.
def rising():
    space = 80
    heads = [(214, 820, 0.5), (318, 716, 0.7), (446, 590, 0.9)]
    body = "".join(glyph("E0A4", x, y, space * s, INK) for x, y, s in heads)
    note = fragment('<note pname="a" oct="4" dur="8" stem.dir="up"/>', (560, 170, 260, 470), INK, stem=0.5)
    defs = radial("p", PAPER, "#EDE5D7", cy=0.38)
    return wrap(f'<rect width="{S}" height="{S}" fill="url(#p)"/>{body}{note}', defs)


CONCEPTS = [
    ("circled", "1  Circled", "a page of music, circled in pencil", circled),
    ("stave-voice", "2  Stave into voice", "the five lines curl into a speech bubble", stave_voice),
    ("fermata", "3  Fermata", "the hold: an arc over a point, an eye that listens", fermata),
    ("duet", "4  Duet", "two voices a second apart, heads touching", duet),
    ("caret", "5  Caret", "the next note goes where the cursor is", caret),
    ("rising", "6  Rising thought", "the bubble's trail turns into notes", rising),
]

if __name__ == "__main__":
    out = os.path.join(HERE, "out3")
    os.makedirs(out, exist_ok=True)
    f = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 28)
    fs = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 20)
    big, gap, label = 380, 64, 84
    W, H = 3 * big + 4 * gap, 2 * (big + label) + 3 * gap + 150
    sheet = Image.new("RGB", (W, H), "#E8E2D8")
    d = ImageDraw.Draw(sheet)
    for i, (key, title, line, make) in enumerate(CONCEPTS):
        svg = make()
        open(os.path.join(out, f"{key}.svg"), "w").write(svg)
        cairosvg.svg2png(bytestring=svg.encode(), write_to=os.path.join(out, f"{key}-1024.png"),
                         output_width=1024, output_height=1024)
        x, y = gap + (i % 3) * (big + gap), gap + (i // 3) * (big + label + gap)
        t = tile_png(svg, big * 2).resize((big, big), Image.LANCZOS)
        sheet.paste(t, (x, y), t)
        d.text((x, y + big + 14), title, fill="#24221F", font=f)
        d.text((x, y + big + 50), line, fill="#5B5650", font=fs)
        # its home-screen size, in the row below the grid
        s = 60
        sx = gap + i * ((W - 2 * gap) // 6)
        tt = tile_png(svg, s * 3).resize((s, s), Image.LANCZOS)
        sheet.paste(tt, (sx, H - 120), tt)
        d.text((sx + s + 10, H - 100), title.split()[0], fill="#5B5650", font=fs)
    d.text((gap, H - 160), "At 60 px", fill="#24221F", font=fs)
    sheet.save(os.path.join(out, "round3.png"))
    print("ok", sheet.size)
