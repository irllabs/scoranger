# Scoranger design system — "Notebook" (0.8)

This document is the spec for 0.8. The drawings it describes are
`design/redesign-0.8/notebook-spec.html` (56 frames: every screen and every
panel state, iPad and phone), and the CSS layer that produces them is
`design/redesign-0.8/notebook.css`. The tokens in
`ios/Scoranger/DesignSystem/Theme.swift` follow this file.

It supersedes the "instrument panel" direction of 0.5–0.7 (kept in git history
at this path). The owner's verdict on that direction, from the 0.8 brief: too
square, too many hard edges, band headers that read as machine labels, menus
that open to half a screen for three rows, and disclosures that push the page
down. The palette survives unchanged; the forms do not.

The direction in one line: *a rehearsal notebook on a warm table — one or two
paper-coloured pages with soft corners, dashed rules, capsule controls, the
arrangement numeral stamped in a clay ring, and everything you open beside the
thing you opened it from, never below it.*

- **Paper & Clay**, unchanged: warm off-white surfaces, near-black ink, one
  burnt-clay accent. Light only.
- **Space Grotesk** for anything that names a thing, **Inter** for anything you
  read, **IBM Plex Mono** for every machine value. The ladder is one step larger
  than 0.7 at every rung the owner called hard to read.
- **Capsules and pages.** Every control is a capsule (radius 999); every screen
  is one or two pages with 22pt top corners on a `band` table.
- **Score first.** The score is the ground. One bar above, one tray below, a
  thumbnail rail at the left, the panel at the right. Performance mode removes
  all four.
- **Beside, not below.** The next level of anything opens in the right panel at
  the height of the row that opened it. A row's own actions open inside the
  row. Nothing pops up at the bottom, nothing pushes the page down, nothing
  needs closing that did not announce itself as a page.

---

## 0. The sixteen rules from review

The owner reviewed option 8 and draft 1 of the spec with annotated
screenshots. Each finding became a rule; they are marked `[Cn]` in
`notebook.css` and in the spec's captions. They are binding.

| # | Rule |
|---|---|
| C1 | The right panel is `panel`, never white. `paper` is the score page and the inside of a text field, nothing else. |
| C2 | No tab column on the panel. The panel shows what the tapped row opened, headed by its name, and closes with Done or with the row's ✕. |
| C3 | Knobs have no pointer tick. The clay arc alone carries the level; the LED is the centre of the dial and the mute. |
| C4 | A selected row is a flat tint band the width of the page: no ring, no radius, no indent. Its contents do not move when selected. |
| C5 | Performance mode is a labelled button, "Perform", in the score bar's right group. |
| C6 | The score bar leaves with ‹ and the name of where you came from (set list, piece, or Library). Never ✕. |
| C7 | The search field's label is one line and the field is never narrower than 240pt. When the panel is open, the tool row gives search the first line and the buttons the second. |
| C8 | Nothing is cut off. When the panel opens the page lays itself out again at the narrower width: tool rows wrap, meta text ends in an ellipsis, the ☰ stays inside the page. |
| C9 | Filters come from the data model: type (MusicXML, PDF, MIDI, photo), composer, instrument, tag, status. Capsules with counts, grouped, several at once. |
| C10 | Every library row carries two dates in mono: changed (with its version) and added (its first version). Sort offers Date added. |
| C11 | Selection starts from Edit in the tool row or a long press on any row, which enters Edit with that row checked. |
| C12 | A book has a full-width filmstrip of every page under the spread, with a scrub bar. |
| C13 | A dashed rule never doubles: a block that follows a row takes the row's rule. |
| C14 | Arrangement Details has a Tags field. Piece tags and arrangement tags are both filterable. |
| C15 | The chat compose field grows with the prompt and has a grab bar to drag it taller, up to half the panel. |
| C16 | In the score bar the title and its subtitle are one line each and end in an ellipsis when the panel narrows the bar. |
| C17 | **Full width.** A page's content runs the full width of the page, less the page padding (§3). Nothing centres a column of content inside a page and nothing caps its width -- not a list, a form, a search, a list of settings, a book's contents. On an iPad that puts a row's label and its control far apart, and that is accepted: the space is the reader's. (Ali, 2026-10-17, on build 214: "There's no reason to have these margins ... make that a high-level design system requirement.") `Theme.Metric.readingColumn`, the 720pt cap every pushed screen used, was deleted with this rule so no page can be capped again without a new constant saying why. A chat bubble, an alert and a text field keep their own widths: they are not page content. |

---

## 1. Colour

Unchanged from 0.7 in value. Changed in role: `band` becomes the app's ground,
`panel` becomes the page, and `ground` is retired.

### Surfaces

| Token | Hex | Where in 0.8 |
|---|---|---|
| `paper` | `#FFFFFF` | The score page, and the inside of a text field. Nothing else. |
| `band` | `#F1ECE2` | **The table**: the app's base colour behind every page. |
| `panel` | `#FAF7F1` | Pages: the list page, the right panel, the tray, the ink tools. |
| `well` | `#EFEAE0` | Controls at rest: capsule buttons, the segment track, chips. |
| `ground` | `#F4F0E8` | Retired. Keep the token one release for the transition; no new use. |

### Ink

| Token | Hex | Rule |
|---|---|---|
| `ink` | `#1A1917` | Titles, names, body, keys. |
| `ink2` | `#6B655C` | Secondary prose, mono values, the tempo arc. |
| `ink3` | `#8A8378` | Supplementary only, at 12pt and above: meta lines, counts, dates, placeholders. Never the only place information appears. |

### Accent

| Token | Hex | Rule |
|---|---|---|
| `clay` | `#CC5C2E` | The numeral's ring and digits, knob arcs, the current thumbnail's ring, the scrub handle, the performance tab, the field focus ring. Text only at ≥15pt semibold. |
| `clayStrong` | `#A8481F` | All small accent text: the alphabet letters, the lit button's label, back buttons, a link word in a note. |
| `clayPress` | `#B14D22` | Primary button fill (Open, Play, Add, Convert, Save as vNNN) and the play button. |
| `clayTint` | `#F7E7DD` | Selected row band, the lit control, the current panel item, the user's chat bubble, an inline confirmation block. |

### System status — outside the budget

Unchanged: `ok #3BA05C` (knob LEDs while a part sounds, the engine LED),
`warn #C8791B` (the OMR DRAFT chip's text), `danger #C0392B` (destructive
labels and the Delete confirm button), `highlight`, and the five pen inks.

Rules:

1. One accent per region. A lit capsule (tint + 1.5pt clay ring) marks the one
   control whose panel is open; nothing else in that row is clay.
2. Selection is `clayTint` alone, edge to edge, no outline [C4].
3. Never tint the score page.

---

## 2. Typography

Three families, bundled. No serif, no SF Pro.

| Role | Family | Size / weight | Where |
|---|---|---|---|
| `screenTitle` | Space Grotesk 700 | 28 / lh 1, −0.025em | "Library" on its page. |
| `headTitle` | Space Grotesk 700 | 26 / lh 1.1, −0.02em | Piece, set list, arrangement and book names on their screens. |
| `panelTitle` | Space Grotesk 700 | 20 / lh 1.1, −0.02em | The right panel's header. |
| `stamp` | Space Grotesk 700 | 15 in a 40pt ring; 22 in 56; 12 in 30 | The `#N` numeral, −0.03em, tabular. |
| `rowName` | Space Grotesk 600 | 16 / lh 1.2, −0.01em | Row names. |
| `barTitle` | Space Grotesk 600 | 16 | The score bar's title; one line, ellipsis [C16]. |
| `key` | Space Grotesk 600 | 15.5 | The key column of a key/value row; settings index items. |
| `panelItem` | Inter 500 | 14.5 | Items in the panel. |
| `body` | Inter 400 | 14 / lh 1.45 | Chat prose, notes under controls, empty states. |
| `control` | Inter 600 | 13.5 | Capsule labels. 12.5 inside a row's actions and in the panel's tool row. |
| `meta` | Inter 400 | 12.5 | Meta lines under a row name. |
| `data` | IBM Plex Mono 500 | 12 | Versions, bars, counts, dates, keys, hostnames. |
| `knobLabel` | Inter 600 | 9.5 | Under a knob; the level beside it in mono 9.5. The one exception to the 12pt floor, carried by VoiceOver. |

Rules:

1. Space Grotesk names things; Inter is read; anything the user could type into
   chat verbatim is mono.
2. The tracked-out 10pt caps `label` role of 0.7 is retired. Section labels in
   the panel are Inter 600 12 `ink3`, sentence case, with a dashed rule between
   blocks.
3. Sentences are notes, not labels. A control's label is one or two words; the
   explanation is a `body` note in `ink2` under it (§7.9).
4. Dynamic Type through AX3, declared with `relativeTo:`. At AX1 and above: the
   knob group and the thumbnail rail become scrolling lists; a row's inline
   actions wrap to a second line inside the row; the panel scrolls.

---

## 3. Space, size, hit targets

Ladder: **2, 4, 6, 8, 10, 12, 16, 22, 24**.

| Thing | Value |
|---|---|
| Table margin (edge of screen to a page) | 16 |
| Page padding (horizontal) | 24 |
| Panel padding (horizontal) | 22 |
| Gap between the page and the panel | 10 |
| Panel width | 380 (iPad); full width, pushed, on phone |
| Row | 64 minimum; 8 vertical padding; grid: stamp 40 · thumb · name 1fr · dates · ☰ |
| Ordered row | adds a 28pt right-aligned ordinal before the stamp |
| Control height | 40 (44 hit area); 36 inside a row's actions; 32 in the panel's tool row |
| Bar (score) | 56 |
| Tray (score) | **56, always** |
| Thumbnail rail | 60 wide; thumbnails 40 × 52, 6 apart |
| Book filmstrip | thumbnails 20 × 27, 3 apart; scrub bar 4pt with a 16pt handle |
| Knob | 32pt dial in a 44pt group; 14pt of drag per unit |
| Settings index | 300 wide (iPad) |
| Gap between sibling controls | 8 |
| Gap between panel blocks | 12, with the dashed rule |

Every tappable thing gets a 44 × 44 hit area via `contentShape`.

### Centring

Inside a capsule, text and glyph centre on the capsule's geometric centre with
line-height 1 and a 1pt optical lift on lowercase labels. A stamp's numeral
centres 1pt left of the ring's centre because of the hash. A knob's LED is the
dial's exact centre and the label centres under the dial. A panel block that
belongs to a row opens with its title on the row's centre line.

### Travel

A row's own actions replace its meta line inside the row, so the finger moves
along the row, never off it. The next level opens beside, at the row's height.
Nothing opens below the row that was tapped.

---

## 4. Line, radius, elevation

| Token | Value | Use |
|---|---|---|
| `rCtl` | 999 | Every button, field, chip, segment, panel item, settings index item. |
| `rPage` | 22 | Top corners of the list page, the panel and the tray. Pages run off the bottom of the table. |
| `rInner` | 14 | The scroll-mode score strip; message bubbles (16, with a 6pt corner toward the author). |
| `rScore` | 6 | A score page. 3 for a thumbnail, 2 for a filmstrip thumbnail. |
| `rule` | 1pt dashed `line2` | Under rows, under key/value rows, between panel blocks. The only line in the app [C13: never doubled]. |
| `ring` | 2.5pt `clay` | The stamp. 3pt at 56, 2pt at 30. |
| `focus` | 1.5pt `clay` inset | A focused field, a lit capsule. |
| shadow | `0 2 10 rgba(26,25,23,.12)` | Only on things that float: the ink tools and the selection chip over the score, and a row lifted by its ☰ (§7.3). |

No borders on controls. No shadows on pages. No gradients except the knob's
conic arc and the fade at the end of an overflowing knob group.

---

## 5. Motion

| Move | Duration | Rule |
|---|---|---|
| Panel in / out | 220ms spring | The page narrows on the same curve and lays out again at the new width [C8]; rows do not reflow, text truncates. |
| Row actions | 120ms | Meta fades out, actions fade in; the row's height does not change. |
| Tray | none | The tray never animates its height. Performance mode slides the tray off the bottom and the bar off the top together, 220ms. |
| Knob | live | Arc follows the finger; the LED changes instantly. |
| Inline confirm | 160ms | The destructive row becomes the tinted block in place. |
| Filmstrip scrub | live | Thumbnails ring under the finger; the spread lands on lift. |

Reduce Motion: cross-fades at 120ms, nothing slides.

---

## 6. Iconography

SF Symbols, `.medium`. 16pt in the bar and tray, 14 in rows and the panel.
One glyph per idea, the same everywhere: `line.3.horizontal` row menu (☰),
`xmark` the open row's close, `chevron.left` back, `chevron.right` opens
beside, `plus`, `square.and.arrow.up` share/send, `magnifyingglass`,
`arrow.up.arrow.down` sort, `line.3.horizontal.decrease` filter,
`checkmark.circle` edit/select, `pencil.tip` pencil, `lasso` select,
`bubble.left.and.text.bubble.right` chat, `rectangle.expand.vertical` perform
(always with its word), `ellipsis` more, `doc` / `doc.on.doc` /
`arrow.left.and.right` the three layouts, `play.fill` / `pause.fill`,
`backward.end.fill` to start, `metronome`, `repeat`, `slider.horizontal.3`
all-on/all-off, `trash` the button a row swiped left uncovers. The knob LED is a drawn 8pt circle with a 2pt halo, not a
symbol. The stamp is drawn, not a symbol.

---

## 7. Components

Each component is drawn in the spec's Components section and used across its
wireframes. The names here are the SwiftUI type names to build.

### 7.1 Page
`panel` fill, `rPage` top corners, 16 from the table's edge, runs off the
bottom. Holds a head (screen title or ‹ back + centred title + primary
action), an optional tool row, and a list. Two pages fit an iPad landscape:
the list page and the panel.

### 7.2 Panel (the right page)
380 wide, `panel`, `rPage` top corners, 10 from the page. Header: title 20,
optional mono count, optional ‹ (when it opened from another panel state),
Done at the trailing edge. Body: items (44pt `band` capsules; current is
`clayTint`), key/value rows (48pt, dashed rule), blocks separated by a dashed
rule, `body` notes, a `btns` row of 44pt buttons. Destructive items sit last
under a "Careful" label and confirm inline (§7.8). Opened by: a tool-row
button (Sort, Filter, Add to set list), a row's action (Arrangement,
Versions, Parts, Details, Set lists, Move to piece), the score bar (title,
Chat, +, More), or at rest on the set list and piece screens ("This set
list", "This piece"). On phone it is pushed as a page with ‹ in its header.

### 7.3 Row
64pt, dashed rule under, grid: stamp · thumbnail · name/meta · dates · ☰.
States: **rest**; **☰ open** — ☰ becomes ✕ and the actions take the meta
line's slot as 36pt `paper` capsules, the row a flat `clayTint` band [C4], the
action whose panel is open lit; **Edit** — a 24pt check leads the row, checked
rows are tint bands, no ☰. Entered by Edit or by a long press on a row [C11].
Dates: two mono lines at the right, `vNNN · changed` in `ink2` over `added
date` in `ink3` [C10].

An **ordered row** (a piece's arrangements, a set list's running order) has
two more gestures, and no Up, Down or Delete among its actions. Its ☰ is the
handle: pressed and moved, it lifts the row (`panel` fill, the shadow of §4)
and the rows it passes step aside; a tap without movement still opens the
actions. Swiped left, the row slides off its leading edge to uncover an 88pt
`danger` strip at its right edge, the row's full height, with a white `trash`
glyph; tapping it deletes, or takes the row out of the set list, with no
inline confirm (§7.9): the swipe and the tap are the confirmation, and a
deleted arrangement still leaves the undo bar. One row open at a time; a swipe
back or a tap anywhere else closes it. VoiceOver reaches all three as actions
on the row (Move up, Move down, Delete). `ReorderableRows` is the component.

### 7.4 Stamp
The `#N` numeral in a clay ring: 40pt/2.5pt/15 in rows, 56/3/22 on a head,
30/2/12 in a panel row. Unfiled arrangements have no stamp and no reserved
space.

### 7.5 Capsule controls
Button: `well` at rest, `clayTint` + 1.5pt clay ring when its panel is open,
`clayPress` + white when primary, transparent + `danger` text when
destructive, transparent ("quiet") in a tool row, 45% opacity when
unavailable and never hidden. Segment: `well` track, `panel` thumb, capsules
in a capsule. Field: `paper`, 40pt, clay ring on focus, label never wraps,
never narrower than 240 [C7]; Clear inside the field. Chip: `well`, 11pt
mono for formats (MUSICXML, PDF), `clayTint` for the people chip, `warn` text
for OMR DRAFT. Check: 24pt ring, clay fill with a white tick when on.

### 7.6 Tool row
One line: the search field, then the primary actions (Import, New, New set
list), then Sort (with its value in a lighter weight), Filter (with the count
of filters on), Edit. When the panel is open the field takes the first line
and the buttons the second [C7]. In Edit mode the row becomes Select all ·
the actions for the selection (Add to set list, Move to piece, Duplicate,
Delete) · Done.

### 7.7 Tray (score)
56pt, `panel`, `rPage` top corners, 16 from the table's edges, dashed rule on
top. Left to right: set list step chip and prev/next; play (clay), to start,
click, loop; one knob per part then a tempo knob; position in mono, and the
seek scrubber while playing; at the right the all-on/all-off glyph. More
parts than fit scroll sideways inside the knob slot under a fade; tempo and
position stay put. While converting a scan the tray carries the progress on
its one line. It replaces `ScoreFooter` and the mixer window.

### 7.8 Knob
32pt dial, `panel` face, a 270° conic arc from 7 o'clock in `clay` (`ink2` for
tempo), no pointer [C3]. The LED (8pt, `ok`, 2pt halo) is the centre; tap it
to mute, and the arc dims to 50% but keeps its level. Label under: Inter 600
9.5 with the level in mono beside it. Drag vertically, 14pt per unit; double-
tap tempo returns to the score's marking. 44pt group.

### 7.9 Inline confirm
A destructive item becomes, in place, a `clayTint` block the panel's width:
a 15pt title as a question, one `body` sentence naming the consequence, and
two buttons (the verb on `danger`, Keep). No alert, no sheet. Used for
Delete, Delete for everybody, Leave, Remove a person, Delete a piece.

### 7.10 Note
`body` in `ink2` under the control it explains, in the panel or the settings
section. This is where every sentence from 0.7's labels went.

### 7.11 Thumbnail rail
60 wide at the left of the score in paged reading; every page at 40 × 52
with its number in mono 8; the current page (or spread) ringed in clay. Tap
to jump, drag to scrub. Not shown in scroll mode. Replaces the bottom
thumbnail strip and the Pages panel.

### 7.12 Filmstrip (book)
Full width of the book page under the spread: every page at 20 × 27, 3
apart, the current spread ringed, page numbers at the ends, a 4pt scrub bar
with a 16pt clay handle. Drag to fly, tap to land [C12].

### 7.13 Score bar
56pt. ‹ and where you came from [C6] · the title block (stamp, title 16,
subtitle mono; one line each [C16]; tap opens Versions) · the layout segment
· Pencil · Select · Chat · + (set lists) · **Perform** (glyph and word) [C5] ·
More. On a scan the layout segment and Chat rest at 45%.

### 7.14 Ink tools
One capsule floating 14 above the tray: move · draw · erase · five ink dots
(live one ringed) · undo · Done. The tray rests at 50% while drawing and
names the version the ink belongs to.

### 7.15 Selection chip
Floats over the page after a lasso: "7 elements from bar 9", staff and voice
in meta, Use in chat (primary), ✕. Hold to add, tap an element to drop it.

### 7.16 Chat (in the panel)
Header: Chat, the model alias in mono, Done. Bubbles: agent on `band`, you on
`clayTint`, 16pt corners with a 6pt corner toward the author; the agent's
reply carries the ops and version it made in mono with a "Show the steps"
fold. Compose: a grab bar, then a field that grows with the prompt and can be
dragged taller up to half the panel [C15], dictation, send.

### 7.17 Settings split
Index at the left (300 wide; 48pt capsule items, each stating its section's
answer in meta; current in `clayTint`), the section at the right: an `alpha`
header, key/value rows with dashed rules, notes. Never more than a screen.

### 7.18 Empty state
Centred on the page: a 72pt stamp at 50%, a 22pt title, one `body`
paragraph no wider than 380, up to three buttons. Never a sign-in.

### 7.19 Progress
On a row: a 4pt `well` track with a `clay` fill in the row's action slot,
the stage in mono, a Stop. On the tray: the same, on its one line. In the
panel: a ring spinner beside the item. Never a popup.

---

## 8. Screens

All in `design/redesign-0.8/notebook-spec.html`, by frame id:

| Group | Frames | What they settle |
|---|---|---|
| Library | L1–L12 | Pieces at rest, search, Sort, Filter (five groups), Edit mode, a piece row's ☰, Set lists, a set list row's ☰, Books, empty library, Import folder, a Book with its filmstrip. |
| Piece | P1–P2 | This piece (details, sources, delete); an arrangement row's ☰ with Move to piece. |
| Arrangement | A1–A4 | Versions, Parts, Details (with Tags), Set lists. |
| Set list | S1–S7 | At rest (tools, people, marks), a member's ☰, Add, Invite (with the signed-out line), someone else's list, inline delete confirm, empty. |
| Score | SC1–SC15 | One page with the rail, two pages, scroll mode playing, the title block's Versions, Chat, Select, Pencil, More, Transpose and chord symbols, Export, + set lists, Performance, a scan with Convert, converting, nine parts. |
| Settings | T1–T10 | Account out and in, Reading, Titles, Engine, Server, Scanning, Model, Diagnostics, About. |
| Phone | Ph1–Ph6 | Library, set list (actions wrap in the row; the list's tools as a foot strip), the panel as a page, score, performance, settings index. |

---

## 9. Accessibility

- Contrast as in §1; `clayStrong` for every piece of clay text under 15pt;
  `ink3` at 12pt and above only. The knob label at 9.5pt is the one exception
  and is carried by VoiceOver ("Violin I, level 7, sounding").
- Hit targets 44 × 44 on everything, including 32pt knobs, 24pt checks, 20pt
  filmstrip thumbnails (the strip is one control with a scrub gesture), and
  the 22 × 84 performance tab (44 wide hit area).
- Dynamic Type through AX3 per §2.4.
- VoiceOver labels name the object: "Open Versions of Sous le ciel quartet",
  "Back to Tuesday at the Ship", "Mute Viola", "Page 4 of 9", "Perform".
- No login gate. Sign in appears in the Account section and in the Invite
  panel when signed out, nowhere else.
- Reduce Motion per §5.

---

## 10. Labels

The table in the spec's Labels section is the authority: every header, row
and button title the app shows today and its 0.8 text. The rule: one or two
ordinary words; the sentence moves into a note under the control. Notable:
Options → More; Close score → ‹ and the origin; Manage → gone; Running
order → gone (the list is the list); PDF conversion (OMR) → Scanning;
On-device engine / Remote engine → Engine / Server; Add arrangements → Add;
Play from the top → Play; Whose marks to show → Marks to show; Starts here /
Ends here → From page / To page.

---

## 11. Non-goals

Dark mode. A second accent. Serif type. SF Pro. Sheets and alerts as a
pattern. In-place bands that push the page. A second row on the tray.
Anything at the bottom that must be dismissed. Restyling the engraving.

---

## 12. Applying it

Staged as internal TestFlight builds, each one a build the owner can react
to. Each stage runs `ios/scripts/gate.sh` and ships with
`ios/scripts/deploy_testflight.sh` as 0.7.4 did.

1. **Tokens (0.8.0).** `Theme.swift`: `band` as the ground, `rCtl` 999,
   `rPage` 22, dashed rules, borders cleared, the type ladder of §2, the
   stamp, the knob without its pointer, Perform as a labelled button, ‹ back
   in the score bar. Every existing view restyles without changing shape.
   Visible everywhere; one day.
2. **Tray (0.8.1).** `Tray` replaces `ScoreFooter` and `MixerWindowPanel` /
   `MixerWindowStrips`: one 56pt line, knobs inline with a scrolling slot,
   LED-as-mute. The mixer's drag, park, clamp and collapse go.
   `MIXER_WINDOW.md` §13's knob anatomy stays.
3. **Panel and row actions (0.8.2).** `Panel` and `RowActions`; the
   management bands, Options, the version dropdown and switcher band, Sort
   and Filter bands, the OMR offer and `PanelDialogs` fold into them.
   `ThumbnailRail` replaces `PageScrubber`'s strip.
4. **Settings, filters, book (0.8.3).** `SettingsSplit`; Filter's five groups
   (instrument from the parts snapshot, type from the latest artifact, tags
   from piece and arrangement); Date added on rows and in Sort; Tags on
   Details; the book filmstrip; the resizable compose.
5. **Phone (0.8.4).** The panel as a pushed page; the set list's foot strip;
   the score bar's second row.

Risks worth naming: the tray at 56pt with AX text (fallback: a scrolling knob
list, as §13 already requires for the strip); the panel at 380 beside a
1194 page leaves 804 for a score, so paged reading with the panel open is
smaller (which is why only Versions, Chat and More open it while reading);
instruments as a filter need a parts snapshot, which a never-converted scan
does not have (those match no instrument, and the counts show it).
