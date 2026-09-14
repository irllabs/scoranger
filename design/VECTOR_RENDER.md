# Direct vector rendering of the score page

Status: first pass of 0.8.3 item 1. A display list, a renderer, a flag that is
OFF by default, and a harness that draws the same page both ways for a person
to look at. The bitmap path is untouched and still draws every page the app
shows.

Every claim below is marked **verified** (measured here, with the command that
measured it) or **inferred** (read off the code, not executed). The two sample
scores in `testdata/app-samples/` are the corpus: a four-part string quartet
(8 pages) and an accordion solo (5 pages), engraved with the app's own option
set, `EngravingOptions.json(lyricSize: 4.5, continuous: false)`.

---

## 1. What Verovio actually hands us

**Verified.** Over every page of both scores, the drawable vocabulary outside
`<defs>` is eleven element kinds and twenty-three attributes, and no more:

| element | attributes seen | what it draws |
|---|---|---|
| `g` | `class` `id` `transform` `visibility` `xml:lang` | structure only |
| `path` | `d` `stroke-width` `stroke-linecap` `stroke-linejoin` | staff lines, stems, barlines, ledger lines, slurs, ties, brackets, group symbols, volta brackets |
| `polygon` | `points` | beams |
| `polyline` | `points` `stroke-width` `stroke-linecap` `stroke-linejoin` `fill` | hairpins |
| `ellipse` | `cx` `cy` `rx` `ry` | augmentation dots |
| `use` | `xlink:href` `transform` | every SMuFL glyph |
| `text` / `tspan` | `x` `y` `font-size` `font-family` `font-weight` `text-anchor` `class` `id` | labels, chord symbols, tempo marks, tuplet numbers, page numbers, credits |
| `svg` | `class` `color` `font-family` `viewBox` | one nested viewport, `class="definition-scale"` |
| `style` | `type` | one fixed stylesheet |
| `title` / `desc` | `class` | tooltips, not notation |

There is **one** `fill` attribute in the whole corpus — `fill="none"`, on the
nine three-point hairpin polylines — and **no** `stroke` or explicit colour
attribute anywhere. Colour is `stroke:currentColor` in the stylesheet plus
`color="black"` on the `definition-scale` element. That is the entire colour
model.

Command:

```
engine/.venv/bin/python - <<'PY'   # abbreviated; see §6 for the survey used
import verovio, re, collections
...
PY
```

### 1.1 Which SMuFL glyphs the scores use

**Verified.** 28 distinct codepoints across both scores, every one of them
referenced as `<use xlink:href="#CODE-pageid">`:

```
E050 E05C E062 E083 E084 E0A3 E0A4 E240 E241 E260 E261 E262 E4A0 E4A1
E4A2 E4A3 E4A4 E4A5 E4C0 E4E3 E4E4 E4E5 E4E6 E522 E52C E52D E566 E883
```

Clefs (E050 G, E05C C, E062 F), time-signature digits (E083/E084), noteheads
(E0A3 half, E0A4 black — 876 of them on the quartet alone), flags (E240/E241),
accidentals (E260 flat, E261 natural, E262 sharp), rests (E4E3–E4E6),
articulations (E4A0–E4A5), fermata (E4C0), dynamics (E522 *f*, E52C *p*,
E52D *mp*/*mf* family), tuplet bracket parts (E883), ornament (E566).

**The count per page is small and the sharing is total**: the quartet's page 1
uses 12 distinct glyphs across 267 `<use>` references.

### 1.2 Bravura: vendored, and not needed at draw time

**Verified, and it contradicts the plan in `BACKLOG.md`.** The backlog says
direct drawing "needs the Bravura font, the codepoint mapping, and path
rendering for everything that is not a glyph". Two of those three are wrong.

- **Verovio embeds the outline of every glyph a page uses in that page's own
  `<defs>`.** `<g id="E0A4-izsoi23"><path transform="scale(1,-1)" d="…"/></g>`.
  A `<use>` never leaves the document. Across the corpus, zero `<use>`
  references failed to resolve against the defs of their own page.
- **The face is Leipzig, not Bravura.** Leipzig is Verovio's default. Compared
  byte for byte: the E0A4 outline Verovio emits is
  `ios/Vendor/verovio/data/Leipzig/E0A4.xml`, not the Bravura one.
- **No codepoint mapping is needed** for `<use>`: the id *is* the codepoint.

Bravura *is* vendored, in two forms, and ships in the app today:
`ios/Vendor/verovio/data/Bravura/` (878 per-glyph outline XMLs),
`data/Bravura.xml` (metrics and glyph names), and
`ios/Vendor/verovio/fonts/Bravura/Bravura.otf`. The whole `data` directory is a
package resource (`Package.swift`: `resources: [.copy("data")]`) and is what
`VerovioRenderer.tk()` passes to `setResourcePath`. Nothing has to be fetched.

The one place a font file *would* be needed is §4.1: two SMuFL characters that
Verovio writes as **text** in family "Leipzig" rather than as `<use>`.

### 1.3 What `SVGGeometryParser` gives today

**Verified by reading it** (`ios/Scoranger/ScoreModel/SVGGeometryParser.swift`,
424 lines). It returns

```swift
struct Page  { var size: CGSize; var groups: [Group] }
struct Group { var id: String; var svgClass: String; var frame: CGRect }
```

— one axis-aligned **bounding box per classed `<g>`**, in document order, and
nothing else. It reads `<defs>` only to learn each glyph's *extent* so a `<use>`
can contribute a box; it discards the outline. `SVGPathBounds` folds every
control point of a curve into the box, which is deliberately a superset of the
true bounds. Its own header says so: "Bounds only. This deliberately does not
retain drawable paths."

So the backlog is right that this is new work rather than a rewiring. What it
*does* supply is `SVGTransform`, a complete `transform`-attribute parser, which
the new code reuses unchanged.

### 1.4 Everything that is not a glyph

**Verified**, with counts from the quartet (8 pages) and the accordion (5):

| drawn as | element | quartet | accordion | paint |
|---|---|---|---|---|
| staff lines | `path` 2-point | 2720 | 1710 | stroke, width 13 |
| stems | `path` 2-point | 1142 | 1039 | stroke, width 18 |
| barlines | `path` 2-point | 548 | 519 | stroke, width 27 |
| ledger lines | `path` 2-point | 512 | 241 | stroke |
| system brackets | `path` 2-point (`class="system"`) | 22 | 26 | stroke |
| group symbol (brace) | `path` (`class="grpSym"`) | 0 | 52 | stroke |
| volta brackets | `path` 2-point | 3 | 0 | stroke |
| beams | `polygon`, 4 points | 179 | 83 | fill |
| augmentation dots | `ellipse` | 186 | 99 | fill |
| slurs | `path`, closed C-curve outline | 125 | 35 | **fill and stroke** |
| ties | `path`, closed C-curve outline | 50 | 44 | **fill and stroke** |
| hairpins | `polyline`, 2 or 3 points | 87 | 2 | stroke (`fill="none"` when 3 points) |

Two things in that table are easy to get wrong and both were caught by the
comparison:

- **Slurs and ties are filled *and* stroked.** They are closed outlines with a
  `stroke-width` of 9; drawing either half alone makes them visibly thin.
- **Every path command that appears is `M m L l H h V v C c S s Q q Z z`.** No
  arcs, anywhere. `S` needs the reflected-control-point rule to be right, which
  is the one place a bounds parser is allowed to be wrong and a drawing parser
  is not.

---

## 2. What was built

Six files, all in `ios/Scoranger/ScoreModel/`, so the existing
`ScorangerTests` target compiles them with no project change:

| file | what it is |
|---|---|
| `SVGPathData.swift` | `d` attribute → `CGPath`, with an `unsupported` report for arcs |
| `SVGTextPath.swift` | one styled text run → outlines, via Core Text, with the characters the face lacks named rather than drawn |
| `VectorPage.swift` | the display list: size, items (path + paint + owning class), and what was NOT drawn |
| `VectorPageParser.swift` | Verovio SVG → display list |
| `VectorPageRenderer.swift` | display list → `CGContext`, one loop, scale applied to the context |
| `VectorRendering.swift` | the flag |

Plus `ios/tools/vector-compare/`, a host SwiftPM executable whose sources are
**symlinks** to the app's own files, so both paths under comparison run the code
that ships.

### 2.1 The flag

`VectorRendering.isOn` reads `UserDefaults` key `vectorRendering`, and
Settings → Diagnostics carries the toggle, beside the touch readout and the
performance ledger. Default false. Chosen over a build-time `#if` for one
reason: the comparison can only be made on the iPad that has the scores on it,
and a compile-time switch cannot be flipped there.

### 2.2 The comparison harness

```
cd ios/tools/vector-compare && swift build
.build/debug/vector-compare <page.svg> … [--width 972] [--pixel-scale 2]
                            [--out DIR] [--dump-prepared]
```

For each page it writes `-bitmap.png`, `-vector.png`, `-side-by-side.png` and
`-difference.png`, and prints the display-list size, the ink in each, and what
the vector path did not draw. In the difference image **red is ink only the
bitmap path drew** and **blue is ink only the vector path drew**; grey is
agreement.

A host tool rather than an XCTest, deliberately: a simulator run costs a full
app build (Python framework, Firebase, the vendored engine) to produce files
that then have to be dug out of an `.xcresult`, and this produces the same
pictures in about a second against any page of any score.

---

## 3. What the comparison shows

**Verified**, 2026-09-14, six pages, `--width 972 --pixel-scale 2` (1944 ×
2516 px, which is the paged canvas at roughly its 2× floor):

| page | display list | ink only on the bitmap page | ink only on the vector page |
|---|---|---|---|
| quartet p1 | 1020 items | 10 359 px (3.5%) | 7 744 px (2.6%) |
| quartet p2 | 1124 | 9 387 (2.9%) | 5 221 (1.6%) |
| quartet p3 | 726 | 6 331 (3.1%) | 7 365 (3.6%) |
| accordion p1 | 1062 | 22 641 (7.7%) | 15 654 (5.3%) |
| accordion p2 | 1326 | 25 889 (7.6%) | 12 781 (3.8%) |
| accordion p3 | 1242 | 26 624 (8.1%) | 12 814 (3.9%) |

Looked at, not just counted. On the quartet the two pages are
indistinguishable: clefs, key signatures, meters, noteheads, dots, stems,
beams, slurs, ties, hairpins, dynamics, measure numbers and staff labels all
land on the same pixels. The 3% is two things, both visible in the difference
image and neither a missing mark:

1. **A staff line landing on one row or two.** A staff line is `stroke-width`
   13 in Verovio's grid, which is 0.585 pt, which is 1.17 px at 2×. The two
   rasterisers split that across rows differently, so at an ink threshold one
   path shows a 1 px line where the other shows 2 px. There is no position
   shift: the best-matching offset between the two images is (0, 0).
2. **The nested-viewport rule.** Verovio's `<svg class="definition-scale"
   viewBox="0 0 21590 27940">` has no width or height, so SVG puts it into its
   parent's viewport under `xMidYMid meet` — a uniform scale with the remainder
   split as margin. The vector path does that. `SVGForSwiftDraw` hoists the
   viewBox onto the root instead, and the sub-pixel difference is what tips
   rule 1 one way or the other.

The accordion pages disagree more, and all of it is **text**. §4 is the list.

---

## 4. What the vector path does not draw, or draws differently

### 4.1 Two SMuFL characters that are text, not `<use>`

**Verified.** A metronome mark is written as
`<tspan font-family="Leipzig" font-size="720px"> </tspan>` —
`metNoteQuarterUp` and `metAugmentationDot`. These are the only glyphs in the
corpus that are *not* `<use>` references, so they have no outline in the page
and no font on the device supplies them: across 581 font descriptors installed
on the build machine, none reports coverage of U+ECA5.

The vector path **does not draw them** and names them in its report. Core Text
answers a missing character with a last-resort box, and a box in the middle of
a tempo mark is a worse lie than a gap that is named.

The bitmap path **does** draw them, correctly, as a dotted quarter note.
Verified by substitution: replacing the two characters with "X" and "Y" in the
source SVG replaces the note and the dot in the bitmap render. **I could not
determine which font supplies them** — no installed face reports the codepoint,
and SwiftDraw's own `createCTFont` returns Times for an unknown family. This is
unresolved and it matters, because:

**Not verified: what either path does on an iPad.** The comparison ran on
macOS. iOS ships a different font set, and if the bitmap path's note comes from
a macOS-only face then the shipped app draws a box there too and this is not a
regression at all. This has to be checked on the device before the gap is
priced.

The fix is available and cheap either way: `data/Leipzig/ECA5.xml` and
`ECB7.xml` are already in the app bundle, with the same one-path-per-file shape
the `<defs>` glyphs have. Resolving SMuFL-in-text from the vendored outlines
rather than from a font is a contained piece of work and removes the font
dependency completely.

### 4.2 Text placement, now correct, and the bitmap path is the one that is wrong

Two defects were found by looking at the difference image and both are fixed:

- **Sibling runs stacked instead of flowing.** Verovio writes the composer and
  the arranger as two unpositioned `<tspan>`s of one `<text>`; SVG says the
  second continues where the first ended. The first pass drew both at the
  `<text>` element's x, one on top of the other.
- **An anchor applied to the first run instead of the whole chunk.** A page
  number is `"–"`, `"2"`, `"–"` under one `text-anchor="middle"`.

Runs are now banked until the chunk ends, measured together, and then placed.

In the other direction, the tempo mark showed the **bitmap path** getting two
things wrong that the vector path gets right, because `flattenTextElements`
concatenates a `<text>` block's runs into one string and takes the font size
from the first run that has one:

- `"♩. = 138"` is drawn entirely at the music glyph's 720 px, so the digits are
  nearly twice their engraved size. Verovio asks for 405 px.
- Verovio's stylesheet (`g.dir, g.dynam, g.mNum {font-style:italic}`,
  `g.ending, g.fing, g.reh, g.tempo {font-weight:bold}`) is ignored entirely,
  so "Tempo di Valse" and "accordion solo" print upright where Verovio engraves
  them italic.

The vector path reads both. **Inferred, not verified**: that Verovio's own
browser output is the standard both should be judged against — I have not
rendered these pages in a browser to confirm.

### 4.3 Known gaps, not yet addressed

- **Elliptical arcs** are drawn as a line to their endpoint and reported. No
  arc appears in either sample score, so this has never fired.
- **`<image>`, gradients, opacity, clipping, patterns** are not handled. None
  appears in the corpus.
- **The app canvas is not wired to the flag yet.** The flag exists, is read,
  and is off; `PDFPageImage` still draws from the PDF unconditionally. Wiring
  it needs `VerovioRenderer.Engraving` to carry the SVG pages (about 250 KB per
  page) and `AppState.engravingBytes` to charge for them.
- **Pinch behaviour is unmeasured.** The whole argument for the vector path is
  that it redraws at the live scale instead of re-rastering at the settled one,
  and nothing here has measured a redraw during a gesture. That is the question
  the backlog called the real unknown and it is still open.

---

## 5. The decision this is gated on

Not a test count, and not the percentages in §3. Ali reading from the vector
path beside the bitmap path on his own scores, on hardware, and saying which he
would rather play from. Until then the flag stays off.

What the evidence supports so far: on notation — every glyph, every stem, beam,
slur, tie, hairpin and barline — the vector path is already a faithful
reproduction at the zoom a page is read at, from a display list of about a
thousand items. Everything still wrong is text, and most of it is in the
*other* path.

---

## 6. Reproducing the survey

```bash
# pages to compare, straight out of the app's own option set
engine/.venv/bin/python - <<'PY'
import verovio
OPTS = {"scale": 45, "footer": "none", "breaks": "auto", "adjustPageHeight": False,
        "pageWidth": 2159, "pageHeight": 2794, "pageMarginTop": 100,
        "pageMarginBottom": 100, "pageMarginLeft": 120, "pageMarginRight": 120,
        "lyricSize": 4.5}
tk = verovio.toolkit(); tk.setOptions(OPTS)
tk.loadFile("testdata/app-samples/sous-le-ciel-quartet.mxl")
for p in range(1, tk.getPageCount() + 1):
    open(f"/tmp/quartet-p{p}.svg", "w").write(tk.renderToSVG(p, True))
PY

cd ios/tools/vector-compare && swift build
.build/debug/vector-compare /tmp/quartet-p*.svg
open /tmp/scoranger-vector-compare
```

`setOptions` takes a dict in the Python binding; handing it a JSON string logs
`Cannot parse JSON std::string` and silently leaves Verovio on its A4 defaults,
which is a 2100 × 2970 page instead of 972 × 1258 and a survey of the wrong
engraving.
