# Chat divider, book reader and Extract (0.19.0)

Design spec for items 2, 3 and 4 of the 0.19.0 scope in `ios/project.yml`.
One recommended design per item. It stays inside the Notebook system
(`design/DESIGN_SYSTEM.md`, tokens in `ios/Scoranger/DesignSystem/Theme.swift`)
and its rules: one control in one place, beside rather than below, no sheets
or alerts, every control a capsule with a 44pt hit area, unavailable controls
at 45% rather than hidden.

Engine work: none. Every flow below uses calls the app already makes
(`findTunes`, `keepContents`, `takeOutTunes`, `extractFromBook`). Section D
lists what changes in how they are called.

Tokens are written as Swift names (`Theme.Ink.ink3`, `Theme.Metric.hitTarget`).
Sizes not in `Theme.Metric` are given in points and are on the §3 ladder.

---

## A. Chat divider

*One dashed rule with a grab handle sitting on it, in place of the solid
line, the handle below it and the dashed rule on the input bar.*

### What it replaces

`ChatView.inputGrip` draws a 1pt solid `Line.line2` rectangle with a 34 x 3
capsule under it, and `inputBar` draws `Theme.Rule()` along its own top edge.
That is three horizontal marks within 20pt, two of them lines of different
styles, which breaks C13 (a rule never doubles). Remove the solid rectangle
and the `inputBar` top overlay. The divider below is the only line between
the transcript and the input.

### What is drawn

```
  ...last agent bubble...
                                              12pt transcript bottom padding
 - - - - - - - - - - - -  ━━━━━  - - - - - - - - - - - -     <- 20pt row
                                              8pt input bar top padding
 ( Arrange...                               )  (mic)  (↑)
```

The divider is one row, 20pt tall in layout (`Theme.Metric.s20`), on
`Theme.Surface.panel`, full panel width:

| Part | Spec |
|---|---|
| Rule | `Theme.Rule()` (1pt dashed `Line.line2`, dash 3/3), across the full width at the row's vertical centre. |
| Gap | The rule stops 8pt (`s8`) either side of the handle: the handle sits on a `panel`-coloured pad 52pt wide, so the line visibly breaks around it. |
| Handle | `Capsule`, 36 x 4, `Theme.Ink.ink3` at full opacity, centred. |
| Hit area | 44pt tall (`Theme.Metric.hitTarget`), full width, centred on the rule: 12pt above the row into the transcript's bottom padding, 12pt below into the input bar's top padding. Neither padding holds a control, so nothing is covered. Implement as a clear overlay on the `VStack` with a `zIndex` above the scroll view, so the scroll view never claims the touch first. |
| Input bar | Top padding `s8` (was `s12`); sides and bottom stay `s12`. Visual gap from the rule to the field is 18pt; from the last bubble to the rule, 22pt. |

States:

| State | Handle | Rule |
|---|---|---|
| Rest | 36 x 4, `Ink.ink3` | dashed `Line.line2` |
| Pointer hover (iPad trackpad) | 36 x 4, `Ink.ink2` | unchanged |
| Dragging | 44 x 4, `Theme.Accent.clay` | unchanged. One accent in the region: the handle alone. |
| Released | returns to rest over 120ms (`Theme.Motion.pillState`); the box snaps to whole lines with the existing `.snappy(duration: 0.18)` | unchanged |
| Reduce Motion | colour changes instantly, no width animation | unchanged |

The drag behaviour already in the working tree (height follows the finger in
global coordinates, snaps to whole lines on release, 2 to 14 lines) is
unchanged. This item changes only what is drawn.

Accessibility: keep `chat-input-grip` (the UI test at
`ScorangerUITests.swift:2798` finds it), label "Resize the message box",
value "N lines", the existing adjustable action.

iPhone: identical. The chat panel is a pushed page there and the divider
spans it.

Not included: a solid line anywhere; a second rule on the input bar; a tint
band or shadow behind the divider; chevrons or arrow glyphs on the handle; any
"drag to resize" text; a line-count readout while dragging; a double-tap
reset.

---

## B. Book reader

*The page fills the screen between a 52pt bar and the filmstrip. Three views
as in the score. Everything about taking tunes out moves to Extract.*

### What leaves the reader

From `BookScreen`: the prev/next pager and its "page N of M" row, From here /
To here and the "Taking pages..." summary, the tunes block (proposal review,
kept contents list, Find the tunes, Edit the list, Find the tunes again), the
"Take out pages" form, and the tunes note. The fixed 420pt page height goes.

The filmstrip and its scrub bar stay (rule C12). It becomes the reader's one
page-position control.

### iPad layout (regular width)

```
┌──────────────────────────────────────────────────────────────────────────┐
│ (‹ Library)   The Real Book                (☰ Tunes) [▯|▯▯|↔] (⊕ Extract) │ 52
│               Autumn Leaves · pp. 30–31                                   │
├ - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -┤
│                                                                          │
│                  ┌──────────────────────────┐                            │
│                  │                          │                            │
│                  │                          │                            │
│                  │        page 30           │                            │
│                  │     (fitted to the       │      band (the table)      │
│                  │      height available)   │                            │
│                  │                          │                            │
│                  │                          │                            │
│                  └──────────────────────────┘                            │
│                                                                          │
├ - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -┤
│ ▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▣▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫ │ 72
│ ════════════════════════●══════════════════════════════════   30 / 480  │
└──────────────────────────────────────────────────────────────────────────┘
```

On an 11-inch iPad in landscape this gives the page about 680pt of height,
against 420 today.

### The bar

52pt (`Theme.Metric.scoreTopBar`), `Surface.panel`, `Theme.Rule()` along the
bottom: the score bar's shape and its `barButton` idiom (well capsule, 34pt,
glyph 15pt; lit = `clayTint` + 1.5pt `clay` ring). Left to right:

| Control | Content | Identifier | Notes |
|---|---|---|---|
| Back | `chevron.left` + "Library" (or the origin's name) | `screen-back` | Same as the score [C6]. The word yields first on a narrow bar. |
| Title block | Book name, `titleS` 16, one line, ellipsis. Under it, `meta` `Ink.ink3`: the tune on the current page and its pages ("Autumn Leaves · pp. 30–31") when the book has a tune list and the page is in one of its tunes; otherwise nothing. | `book-title` | Not a button. |
| Tunes | `list.bullet` + "Tunes" | `book-tunes` | Lit while its panel is open. Always present; see "Tunes panel". |
| Views | Three cells, the score's `layoutControl` exactly: 40 x 34 each, `Theme.Rule(vertical: true)` between, the group in `dashedBoundary()`. Glyphs and labels from `ScoreLayout`: `doc` "One page", `book.pages` "Two pages", `arrow.left.and.right` "Continuous". Active cell `clayTint` with the glyph in `clayStrong`. | container `book-layout`; cells `book-layout-page`, `book-layout-spread`, `book-layout-continuous` | Separate identifiers from the score's `layout-*` so a UI test cannot hit the wrong one. |
| Extract | `doc.badge.plus` + "Extract" | `book-extract` | The far right. Pushes the Extract screen (section C). A well capsule, not clay: one accent per region, and it is not the reader's primary act. |

The view choice is stored once for all books (`@AppStorage("bookLayout")`,
default One page), separate from the score's `layoutChoice`: a reader who
reads scores as a strip and books a page at a time should not have one undo
the other.

The current page is held per book in `AppState` (in memory), so the reader and
Extract open on the same page and Back returns to it.

### The pages area

`Surface.band` behind; each page on `Surface.paper`, `rScore` (6) corners, no
shadow, `s16` clear of the bar, the filmstrip and the sides. Rastered at twice
the drawn size, as `BookPageView` does now.

| View | What is on screen | How you move |
|---|---|---|
| One page | One page fitted inside the area (the smaller of width-fit and height-fit). | Swipe left/right turns one page. The score's bottom-corner tap zones turn. Pinch zooms 1x to 12x, zoom persists across turns, a drag pans while zoomed, and a swipe turns only when it began at fit or hard against the edge. These are the score's rules in `PagedCanvas` and `PageTurn`; reuse them, do not re-derive them. |
| Two pages | A spread of two pages, `s8` apart, fitted together. Units from `PagedCanvas.unit(at:spread:)`. | As One page, by two pages. |
| Continuous | Every page in one horizontal row, each at the full height of the area, `s12` apart, as many across as fit. | Free horizontal scroll with deceleration, no snapping. No pinch: to read small print, switch to One page. Pages are built and rastered lazily, so a 480-page book draws only what is near the screen. |

The current page in Continuous is the leftmost page more than half on screen.
It drives the filmstrip, the readout and the bar's tune line.

Changing view keeps the current page: Two pages shows the spread holding it,
Continuous scrolls it to the leading edge.

Inferred, not verified: a scan arrangement in the score view is already drawn
by this paged canvas from a `PDFDocument`, so the One page and Two pages views
should come from that code rather than from `PageImage` in a scroll view.
Confirm before building.

### The filmstrip (page position)

At the bottom of the screen, `Surface.panel`, `Theme.Rule()` along its top,
72pt: `s8` padding, the thumbnail row (20 x 27, 3 apart, current page or
spread ringed 1.5pt `clay`), `s6`, the scrub row, `s8`.

Scrub row: the 4pt `well` track with a 16pt `clay` handle, then at the
trailing end the readout in `data` mono `Ink.ink2`: "30 / 480", or
"30–31 / 480" for a spread. The end labels "1" and "480" under the track go;
the readout says the same in one place.

Tap a thumbnail to land; drag the scrub bar to fly, landing on lift. Both
move the pages in every view.

Identifiers: keep `book-thumbnails`, `book-thumb-N`, `book-scrub` (adjustable:
increment/decrement one page or spread), and `book-page-label` on the
readout. Pages: container `book-view`, each page `book-view-page-N` with the
label "Page N of M".

### Tunes panel

The access path to `BookEntryReader` for a book kept with a tune list. It
opens in the right panel (`PanelHost`, 380 wide, `Theme.Metric.panelWidth`),
and the pages area narrows and re-fits beside it [C8].

```
                                    ┌──────────────────────────────┐
                                    │ Tunes  124            Done   │
                                    │ - - - - - - - - - - - - - - -│
                                    │  1  All the Things You Are   │
                                    │     pp. 12–13                │
                                    │ - - - - - - - - - - - - - - -│
                                    │▓ 2  Autumn Leaves           ▓│  current
                                    │▓    pp. 30–31               ▓│
                                    │ - - - - - - - - - - - - - - -│
                                    │  3  Blue Bossa               │
```

- Header: `PanelHeader` "Tunes", the count in mono, Done. Done or a second
  tap on Tunes closes it.
- Rows: 56pt minimum, `panelSide` (22) padding. Ordinal `data` `Ink.ink3`,
  32 wide, trailing-aligned; title `titleS` `Ink.ink`, one line; pages
  `meta` `Ink.ink3` ("pp. 12–13", from `BookReading.pages`). `Theme.Rule()`
  under each.
- The tune holding the current page is a flat `clayTint` band [C4], and the
  panel scrolls it into view when it opens.
- Tap a row: pushes `BookEntryReader` for that entry, as `onRead` does today.
  Identifiers stay `book-tune-N`; the panel is `book-tunes-panel`.
- A book with no tune list: the panel holds one `body` note in `Ink.ink2`,
  "This book has no tune list yet.", and a `PanelButton` "Find tunes"
  (`book-tunes-find`), which pushes Extract in Find tunes.

### States

| State | What shows |
|---|---|
| Opening | The pages area holds a clay `ProgressView` and "Opening the book..." in `body` `Ink.ink2`, centred (`book-loading`). Views at 45%. |
| Cannot open | `StateView` centred in the pages area: title "Can't open this book", body "Its pages could not be read on this device." (`book-unopenable`). Views and filmstrip absent; Tunes works (the list is data); Extract works with typed page numbers (C, range fallback). |
| A page fails to draw | The page's placeholder with the `exclamationmark.triangle` in `Status.warn`, as now (`book-page-failed`). |

### iPhone (compact)

```
┌───────────────────────────────────┐
│ (‹) The Real Book    (☰)[▯|↔](⊕)  │ 44
├ - - - - - - - - - - - - - - - - - ┤
│                                   │
│         page, fitted              │
│                                   │
├ - - - - - - - - - - - - - - - - - ┤
│ ══════════●═══════════   30 / 480 │ 40
└───────────────────────────────────┘
```

- Bar 44pt (`scoreTopBarCompact`). Back, Tunes and Extract are glyph-only
  34pt circles with the same accessibility labels. No tune line under the
  title. Two view cells, One page and Continuous (`ScoreLayout.available
  (isCompact: true)`); no spread. All of it fits a 375pt bar with 38pt spare.
- The filmstrip drops its thumbnail row and keeps the scrub row (40pt).
- Tunes pushes as a page with ‹ (the panel's compact behaviour).

### Not included

Prev/next buttons; a "page N of M" sentence; the left thumbnail rail; From
here / To here; any tune list or extraction control on the page; Pencil,
Chat, Perform or More; pinch zoom in Continuous; keyboard shortcuts.

---

## C. Extract

*A pushed screen: the book's pages on the left, a panel on the right that
either lists the tunes found, with a tick for each, or takes a page range
marked with Start and End. Both end in the same destination control and one
primary button.*

### Structure

Route: a new `.bookExtract(slug)` on the library path, pushed by the reader's
Extract button and by "Find tunes" in the Tunes panel. It opens on the
reader's current page and view. Back returns to the reader on whatever page
Extract was last showing.

```
┌───────────────────────────────────────────────────────────────────────────┐
│ (‹ The Real Book)          Extract                          [▯|▯▯|↔]      │ 52
├ - - - - - - - - - - - - - - - - - - - - - - - - - - - - -┬- - - - - - - - ┤
│                                                          │ [Find tunes|Choose pages]
│   ┌────────┐ ┌────────┐ ┌────────┐                        │ - - - - - - - - │
│   │        │ │▓▓▓▓▓▓▓▓│ │▓▓▓▓▓▓▓▓│                        │                 │
│   │  p.29  │ │▓ p.30 ▓│ │▓ p.31 ▓│      pages, as in      │   panel 380     │
│   │        │ │▓▓▓▓▓▓▓▓│ │▓▓▓▓▓▓▓▓│      the reader        │   (the mode's   │
│   └────────┘ └────────┘ └────────┘                        │    content)     │
│               Start       End                            │                 │
├ - - - - - - - - - - - - - - - - - - - - - - - - - - - - -┤ - - - - - - - - │
│ ▫▫▫▫▫▫▫▣▣▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫▫ │ (footer, pinned)│
│ ══════●═══════════════════════════════════   30 / 480    │                 │
└──────────────────────────────────────────────────────────┴─────────────────┘
```

- Bar: back `chevron.left` + the book's name (`screen-back`); title
  "Extract" (`titleS`); the same three view cells as the reader (same stored
  choice, identifiers `extract-layout-page|spread|continuous`). Nothing else.
- Left: the reader's pages area and filmstrip, unchanged, plus the current
  page ring and the span tint below.
- Right: the panel, 380 wide, always open on this screen and with no Done
  (it is the screen's working half, like "This set list" at rest). `panelSide`
  (22) padding. Its top is the mode segment; its bottom a footer pinned to the
  panel's foot with `Theme.Rule()` on top.
- Mode segment: `well` track, `panel` thumb, two cells, 40pt, the panel's
  content width. "Find tunes" (`extract-mode-auto`) | "Choose pages"
  (`extract-mode-range`), container `extract-mode`. Default Find tunes.
  Switching keeps each mode's state, and tune-finding keeps running in the
  background while the reader chooses pages.

That segment is the only mode choice on the screen.

### The current page and the span, on the pages

- Current page: the page Start and End act on. In One page and Two pages it
  is the page on screen (in a spread, the last one tapped, default the left).
  In Continuous it is the last page tapped, default the leftmost more than
  half on screen. Tapping a page makes it current and does nothing else. It
  wears a 2pt `Accent.clay` ring at `rScore` + 2.
- Span: every page between Start and End sits on a `clayTint` mat, `s6`
  around the page, corners `rScore` + 6. Adjacent pages in a span share one
  mat across their gap, so a span reads as one block. Under the first page
  "Start", under the last "End" (one page: "Start · End"), `data` mono in
  `clayStrong`. In the filmstrip, span thumbnails take `clayTint` with a
  `clayBorder` edge, as `BookThumbnails` already does.
- The span shown is the open row's (Find tunes) or the range being marked
  (Choose pages). Nothing else is tinted.

### Find tunes

What the list holds when the screen opens, first match wins:

1. a proposal already in memory (`state.bookProposals[slug]`, e.g. from the
   import);
2. the book's saved tune list (`book.contents`), every row ticked;
3. nothing, in which case finding starts at once. Opening Extract on a book
   with neither is the request to find them; a button that says "Find" first
   would be one tap with no decision in it.

**While finding** (`extract-finding`):

```
│ [Find tunes|Choose pages]    │
│                              │
│  ◌  Finding the tunes        │
│     reading page 40 of 480   │   <- findingTunes[slug], mono
│                              │
│  You can choose pages while  │
│  this runs.                  │
```

Clay `ProgressView` (`controlSize(.small)`), "Finding the tunes" in `row`
`Ink.ink`, the stage in `data` `Ink.ink2`, the note in `body` `Ink.ink2`. No
Stop: `findTunes` cannot be cancelled, and a Stop that does not stop is
worse than none. Footer hidden.

**The list** (`extract-list`):

```
│ [Find tunes|Choose pages]                 │
│                                           │
│ 124 tunes                     Select none │  <- extract-select-all
│ From the book's bookmarks       Find again│  <- extract-found, extract-again
│ - - - - - - - - - - - - - - - - - - - - - │
│ ☑  All the Things You Are                 │
│    pp. 12–13                              │
│ - - - - - - - - - - - - - - - - - - - - - │
│▓☑ ( Autumn Leaves                      )▓│  <- open row: title field
│▓   ( Start 30 )  ( End 31 )            ▓│     and Start/End
│ - - - - - - - - - - - - - - - - - - - - - │
│ ☐  Blue Bossa                             │  <- unticked: title in ink2
│    pp. 40 · Joins your piece              │
│ - - - - - - - - - - - - - - - - - - - - - │
│              ...                          │
│ - - - - - - - - - - - - - - - - - - - - - │  footer
│ Each tune becomes a new piece, or joins   │
│ your piece of the same name.              │
│ ( Extract 123 tunes )  Save as tune list  │
└───────────────────────────────────────────┘
```

Head (not a row):

- "124 tunes", `titleS` `Ink.ink`. Trailing, a quiet button (no fill,
  `control` 12.5 in `clayStrong`): "Select none" while every row is ticked,
  "Select all" otherwise (`extract-select-all`).
- Under it, `meta` `Ink.ink3`, where the list came from, one phrase: "From
  the book's bookmarks", "From the titles on its pages", "Read from its
  scanned pages" (joined with "and" when mixed), or "Your tune list" for
  source 2 (`extract-found`). Trailing on the same line, quiet "Find again"
  (`extract-again`), which runs finding and replaces the list.
- Pages that belong to no tune, and contents or index pages, are not listed
  or described. They show on the pages as pages with no tint.

Rows (`extract-row-N`), `LazyVStack`, `Theme.Rule()` under each, 56pt
minimum, the panel's own scroll:

| Part | Spec |
|---|---|
| Tick | Leading, in the 44pt `checkboxGutter`: `checkmark.square.fill` 17pt `clayStrong` when ticked, `square` `Ink.ink3` when not. The Library's Edit-mode checkbox exactly. `extract-check-N`, label "Extract <title>", `.isSelected` when ticked. All rows start ticked. |
| Title | `titleS`, one line, ellipsis. `Ink.ink` when ticked, `Ink.ink2` when not. No strikethrough. |
| Meta | `data` mono `Ink.ink3`: "pp. 12–13" (or "p. 40"). Then, only when the title matches an existing piece's name (case-insensitive, `manifest.pieces`), `meta` `Ink.ink2` " · Joins your piece". Nothing else: no evidence label. |

Opening a row (tap anywhere on it except the tick):

- The row becomes a flat `clayTint` band [C4]. One row open at a time; a
  second tap, or a tap on another row, closes it.
- The pages turn to its first page and its span is tinted.
- The title becomes a `PanelField` (paper, 36pt capsule, clay ring on focus),
  `extract-title-N`. Edits are kept in the list.
- The meta line is replaced, in place, by two 36pt `paper` capsules:
  "Start 30" (`extract-row-start-N`) and "End 31" (`extract-row-end-N`),
  number in mono. Start sets the tune's first page to the current page, End
  its last; either pulls the other along so the span never inverts
  (`BookContents.setRange` clamps). Row height does not change (§5, 120ms
  fade).

Footer (pinned, `Theme.Rule()` on top, `s12` vertical):

- Destination: when two or more rows are ticked, one line of `meta`
  `Ink.ink2`: "Each tune becomes a new piece, or joins your piece of the same
  name." (`extract-dest-many`). When exactly one is ticked, the full
  destination control from "Destination" below, named after that tune.
- Primary `PanelButton(kind: .primary)`: "Extract 123 tunes" ("Extract 1
  tune") (`extract-auto`). One tap, no confirm: the count is in the label,
  the line above says where they go, and nothing in the book changes.
- Beside it, quiet: "Save as tune list" (`extract-keep`). This is what was
  "Keep as contents": it saves the ticked rows, with their edited titles and
  pages, as the book's tune list and extracts nothing. Accessibility hint:
  "The book stays one book. Its tunes are listed under Tunes."
- Both at 45% with no row ticked. A problem in a ticked row (an empty title)
  shows as one `meta` line in `Status.warn` above the buttons
  (`extract-problem`), and both buttons rest at 45% until it is fixed.
  Unticked rows are not checked for problems.
- Busy: the primary reads "Extracting 123 tunes..." with a small clay
  `ProgressView` before it; both buttons and the list are disabled.

**After Extract** (`extract-result`): the list is replaced by what was made.

```
│ Extracted 123 tunes                       │
│ 120 new pieces, 3 added to pieces         │
│ already here.                             │
│ - - - - - - - - - - - - - - - - - - - - - │
│ All the Things You Are                  › │  <- opens it
│ in All the Things You Are                 │
│ - - - - - - - - - - - - - - - - - - - - - │
│ ...                                       │
│ - - - - - - - - - - - - - - - - - - - - - │
│ Find again                                │  <- quiet, footer
```

- "Extracted 123 tunes" `titleS`; under it the existing
  `BookReview.summary` wording in `body` `Ink.ink2`.
- One row per made arrangement (`extract-result-row-N`): title `titleS`,
  "in <piece>" `meta` `Ink.ink3`, `chevron.right` 14pt `Ink.ink3`. Tap opens
  the arrangement (`onOpen(report.arrangements[n].score)`).
- Footer: quiet "Find again" (`extract-again`), the same action as in the list head.

**After Save as tune list** (`extract-saved`): "Saved 124 tunes as the tune
list." in `body` `Ink.ink`, and one `PanelButton` "Show the tune list"
(`extract-show-tunes`), which goes back to the reader with the Tunes panel
open.

**No tunes found** (`extract-none`), centred in the panel: title "No tunes
found" (`panelTitle`), body "Mark a tune's pages with Start and End
instead.", primary "Choose pages", which switches the segment.

**Finding failed** (`extract-failed`): title "Couldn't find the tunes", the
engine's reason in `body` `Ink.ink2`, then "Try again" (primary) and "Choose
pages". The panel is where this is said; do not also raise the global
`notice` for it (today `findTunes` sets `notice` and returns nil, so it needs
to hand the reason back).

### Choose pages

```
│ [Find tunes|Choose pages]                 │
│                                           │
│ Pages                                     │
│ ( Start 30 )  ( End 31 )              ✕   │  <- extract-range-start/-end/-clear
│ Pages 30–31                               │  <- extract-range-summary
│ - - - - - - - - - - - - - - - - - - - - - │
│ Name                                      │
│ ( Autumn Leaves                        )  │  <- extract-name
│ - - - - - - - - - - - - - - - - - - - - - │
│ Goes to                                   │
│ [ New piece | Existing piece ]            │
│ A new piece called "Autumn Leaves".       │
│ - - - - - - - - - - - - - - - - - - - - - │  footer
│ ( Extract pages 30–31 )                   │  <- extract-range
└───────────────────────────────────────────┘
```

Blocks, each under a `PanelLabel` with the dashed rule between them:

**Pages.**
- Two 40pt `well` capsules, "Start" (`extract-range-start`) and "End"
  (`extract-range-end`). Once set they read "Start 30", "End 31", the number
  in mono. Start marks the current page as the first; End as the last. If End
  is unset or before Start, Start sets both; End before Start moves Start to
  it (`BookPages.starting` / `.ending`, unchanged).
- Trailing, an `xmark` 34pt quiet icon button (`extract-range-clear`, label
  "Clear the pages"), only once something is set.
- Under them, one line (`extract-range-summary`): before anything is set,
  `body` `Ink.ink2` "Turn to the tune's first page, then press Start."; after
  Start only, "Now its last page, then End."; after both, "Pages 30–31" in
  `data` `Ink.ink`.
- When the book cannot be drawn, the two capsules are two mono `PanelField`s,
  "From" and "To" (`extract-range-from`, `extract-range-to`), and the line
  reads "This book's pages can't be shown, so type the page numbers."

**Name.**
- `PanelField`, placeholder "Name" (`extract-name`).
- Pre-filled when Start lands on the first page of a tune in the list (the
  proposal or the saved tune list), and only while the field is empty or still
  holds an earlier pre-fill. Typed text is never replaced.

**Goes to.** The destination control below.

**Footer.** Primary "Extract pages 30–31" ("Extract page 30") (`extract-range`),
45% until there is a range, a name, and, for an existing piece, a chosen
piece. Busy: "Extracting...".

**After Extract**: a one-line block at the top of the panel, above Pages
(`extract-made`): "Added “Autumn Leaves” to Autumn Leaves." (or "…to the
piece Standards.") in `body` `Ink.ink`, with a `PanelButton` "Open"
(`extract-open`) at its trailing end. The range and name clear; the
destination goes back to New piece. The line stays until the next Start or a
mode switch, so the reader can go straight on to the next tune.

### Destination

One component, used by Choose pages and by Find tunes when one row is ticked.

```
│ Goes to                                   │
│ [ New piece | Existing piece ]            │   extract-dest-new / -existing
│                                           │
│ (⌕ Search pieces                       )  │   extract-piece-search
│  Autumn Leaves               2 arr.   ✓   │   chosen: clayTint
│  Autumn in New York          1 arr.       │
│  ...                                      │
```

- Segment, 40pt, two cells: "New piece" (`extract-dest-new`, default) and
  "Existing piece" (`extract-dest-existing`). Existing is at 45% when the
  library has no pieces.
- New piece: one `body` `Ink.ink2` line:
  - "A new piece called “<name>”."
  - with no name yet: "A new piece, named after the tune."
  - when the name matches a piece already in the library (case-insensitive):
    "You already have a piece called “<name>”, so it goes there." This is
    what the engine does (`resolve_piece` matches by name before creating),
    and the line says it before the tap.
- Existing piece: a search field (`paper`, 40pt, `magnifyingglass` leading,
  placeholder "Search pieces", Clear inside) and under it the pieces as 44pt
  panel items, `band` at rest, filtered by case-insensitive substring, about
  six visible and the rest scrolling inside the block. Each: name in
  `panelItem`, arrangement count `data` `Ink.ink3` ("2 arr."). The chosen one
  is `clayTint` with a `checkmark` 14pt `clayStrong` trailing
  (`extract-piece-<slug>`). On switching to Existing, a piece whose name
  matches the tune is pre-chosen. No matches: `meta` "No piece matches."
- Many tunes (Find tunes, two or more ticked): no control, the one line in the
  footer. Per-row "Joins your piece" shows which ones join.

### iPhone (compact)

No side-by-side. The mode segment sits under the bar, full width, `s16`
sides.

```
Find tunes                         Tune pages (pushed)
┌───────────────────────────┐      ┌───────────────────────────┐
│ (‹)      Extract          │      │ (‹) Autumn Leaves  [▯|↔]  │
│ [Find tunes|Choose pages] │      ├ - - - - - - - - - - - - - ┤
│ 124 tunes     Select none │      │      ▓▓▓▓▓▓▓▓▓▓▓▓▓        │
│ - - - - - - - - - - - - - │      │      ▓  page 30  ▓        │
│ ☑ All the Things You Are  │      │      ▓▓▓▓▓▓▓▓▓▓▓▓▓        │
│   pp. 12–13             › │      ├ - - - - - - - - - - - - - ┤
│ - - - - - - - - - - - - - │      │ ( Autumn Leaves         ) │
│ ☑ Autumn Leaves         › │      │ (Start 30) (End 31) (Done)│
│ ...                       │      └───────────────────────────┘
│ - - - - - - - - - - - - - │
│ Each tune becomes a new   │      Choose pages
│ piece, or joins your...   │      ┌───────────────────────────┐
│ (    Extract 123 tunes   )│      │ (‹)      Extract   [▯|↔]  │
│      Save as tune list    │      │ [Find tunes|Choose pages] │
└───────────────────────────┘      │        page 30            │
                                   ├ - - - - - - - - - - - - - ┤
                                   │ (Start 30) (End 31) (Next)│
                                   └───────────────────────────┘
```

- Find tunes: the list fills the screen; rows carry a `chevron.right`. Tapping
  a row (not its tick) pushes **Tune pages**: the pages in the reader's view
  at the tune's first page with its span tinted, and a bottom strip
  (`Surface.panel`, `Theme.Rule()` on top): the title field on its first line,
  "Start 30", "End 31" and "Done" (`extract-pages-done`, pops back) on its
  second. The footer stacks: the destination line, the primary full width,
  "Save as tune list" under it.
- Choose pages: the pages fill the screen in the reader's view, with a
  bottom strip of "Start", "End" and "Next" (`extract-next`, primary, 45%
  until a range is set). Next pushes a page with Name, Goes to and the
  primary "Extract pages 30–31". After extracting it pops back to the pages,
  and the strip's first line shows the made line with "Open" until the next
  Start.
- Filmstrip on both: the scrub row only, above the strip.
- Destination's piece list is the same, full width.

### Accessibility

- VoiceOver: a page reads "Page 30 of 480", plus ", start of the range",
  ", in the range" or ", end of the range". Start and End read "Start at page
  30" / "End at page 31" or "Start, not set". The tick reads "Extract Autumn
  Leaves", selected or not.
- Dynamic Type through AX3: at AX1 and above the footer's two buttons stack,
  primary first; Start and End wrap to two lines in an open row; the panel
  scrolls as a whole.
- Every control above has a 44pt hit area (`contentShape`), including the
  17pt tick and the 34pt clear.

### Not included

Join previous, Split, Remove, the page steppers (− 12 +), the evidence label
per row ("bookmark", "page title", "read from scan"), the "pages N belong to
no tune / are contents" sentence, Discard (leaving the screen is discard: a
proposal stays in memory until it is extracted or saved, as today), the
two-step "Take out" confirm, a Stop for finding, per-tune destinations in a
many-tune extract, a "Piece (optional)" field (every extraction now files
under a piece), and sheets or alerts of any kind.

---

## D. Notes for the build

### Engine calls

| Flow | Call | Change from today |
|---|---|---|
| Find tunes | `state.findTunes(in:)` | Return the failure reason to the panel instead of setting `notice`. |
| Extract N tunes (N >= 2) | `state.takeOutTunes(of:, ticked)` | Pass only the ticked entries. `book-split` already files each under a piece named after its title, joining one of that name. |
| Extract 1 ticked tune | `state.extractFromBook(_:from:to:name:piece:)` | Used instead of split so the destination choice applies. Returns one slug, not a `BookSplitReport`; the result list has one row. |
| Choose pages | `state.extractFromBook(..., piece:)` | `piece` is never nil now: the tune's name for New piece, the piece's **slug** for Existing (`resolve_piece` tries slug before name, so a slug cannot be mistaken for another piece's name). Today an empty "Piece (optional)" left the arrangement unfiled; that path goes. |
| Save as tune list | `state.keepContents(of:, ticked)` | Pass only the ticked entries. |

`BookContents.problem` is evaluated over ticked entries only.

### What is retired, and the tests that use it

UI: `BookReview` (rows, steppers, row actions, the commit block),
`BookScreen.form`, `.markers`, `.pager`, `.tunes`, and the fixed
`BookPageView.height`. `BookContents.mergeWithPrevious`, `.split` and
`.remove` lose their callers; leave them and their unit tests in place this
build and file their removal (`BACKLOG.md`), rather than deleting tests.

Two UI test files exercise the old identifiers and need rewriting against the
new ones, not weakening:

| File | Old | New |
|---|---|---|
| `ScorangerUITests/BookShareIn.swift` | `book-review`, `book-review-found`, `book-review-row-N`, `book-review-keep`, `book-tune-N` | `extract-list`, `extract-found`, `extract-row-N`, `extract-keep` then `extract-show-tunes`, `book-tune-N` (in `book-tunes-panel`) |
| | `book-review-take-out`, `book-review-take-out-confirm`, `book-tunes-note` | `extract-auto` (one tap), `extract-result` |
| `ScorangerUITests/BookBrowser.swift` | `book-next` | swipe on `book-view`, or `book-thumb-N` |
| | `book-from-page` (typing a page turned the book) | Start/End on the current page (`extract-range-start`/`-end`); the typed fields exist only when pages cannot be drawn |
| | `book-thumbnails`, `book-page-label` | unchanged |

The previous `book-extract` identifier was the take-out button; it now names
the reader's Extract button.

### Risks and open points

1. **No bulk undo.** Extracting 123 tunes makes up to 123 pieces in one tap
   with no confirm, and the library has no "undo that extract". The pages are
   copied, so nothing is lost, but cleaning up is 123 deletes. The design
   accepts this because the count and destination are stated on the button
   and the line above it. If that is not acceptable, the remedy is an engine
   undo for one `book-split` (all arrangements it made), not a confirm step.
   Not in 0.19.0 scope; worth a BACKLOG line.
2. **Raster memory at full height.** A page at about 680pt rasters at about
   1100 x 1400 px; Continuous may hold four or five on screen plus their
   neighbours, and zoom to 12x in One page needs a sharper raster than
   `PageImage` makes. Reusing the scan canvas's raster path (inferred to
   exist, see B) is the way to stay inside what the score view already
   handles.
3. **"New piece" cannot make a second piece of the same name.** That is the
   library's rule (tunes that share a title share a piece), and the
   destination line states it. A reader who wants two pieces both called
   "Blues" has to rename one after. Recorded, not changed.
4. **A proposal lives in memory only.** Leaving Extract keeps it; relaunching
   the app loses it and Extract finds again. Unchanged from today.
5. **Two tunes on one page** stay one span (already in the build's NOT list).
   With Join and Split gone, the fix for a tune the finder merged is to untick
   it and take each part with Choose pages.
