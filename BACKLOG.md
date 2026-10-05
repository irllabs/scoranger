# Backlog

## After the first App Store approval: a $4.99/month subscription (0.19.0)

Ali, 2026-10-05: the first App Store release ships FREE so it is not held up,
and "we add subscription after review" at $4.99 a month. The app has no
StoreKit today, so this is a feature build, not a setting. To decide and do:

- **What it unlocks.** Apple rejects a subscription without ongoing value
  (guideline 3.1.2). The candidates are what costs a server: scanning a page
  into notation (OMR, Cloud Run), and library sync plus shared set lists
  (Firestore and Storage). Chat already bills the reader's own OpenRouter
  account. Whether a free trial comes with it is Ali's.
- **Ali's, in App Store Connect:** the Paid Applications agreement, banking
  and tax; the subscription group and the $4.99 product.
- **The build:** StoreKit 2 purchase and entitlement, a paywall at the gated
  features, Restore Purchases, and links to the Terms of Use and privacy
  policy in the app and the listing (required for subscriptions); the
  privacy policy and App Privacy answers re-checked.
- **Who already has it free.** Readers who installed the free release are
  grandfathered or not -- Ali's call, and it shapes the entitlement check.
- **Echo** is on a child account: every purchase goes through Ask to Buy.

## Next release (0.18.0) -- collecting, on fix/tempo-knob

Fixes found after 0.17.0 build 206, held for the next build (Ali,
2026-10-03), and one feature, which makes the build 0.18.0. Each is in
ios/project.yml's 0.18.0 scope block as it is taken on.

- **DONE on the branch: the tempo knob would not turn down.** Ali's recording:
  up from 120 to 186, then stuck. Not stuck -- the knob sits on the screen's
  bottom edge and turned only by vertical drag, down for slower, so there was
  ~40pt of travel below it (6 bpm): measured in the simulator, a 200pt
  downward drag moved it 8 bpm. It now turns by either axis (TempoDrag: up or
  right faster, down or left slower) with its drag start in @GestureState.
  Proof: TempoDragTests, and TempoKnobTurnsBothWays, which drags Ali's 470pt
  up, shows the downward drag still capped, and turns it down 43 bpm by
  dragging left -- and fails without the fix, which ignored sideways travel.
- **0.18.2: trackpad and mouse-wheel scrolling on the tempo knob**
  (ScrollWheelCatcher). UNVERIFIED on hardware: the simulator test tools cannot
  produce a trackpad scroll. TempoKnobTurnsBothWays proves a finger still
  turns it through the new layer. Ali to try it on an iPad with a trackpad.
- **DONE on the branch: a shared set list keeps in step.** Ali added a tune
  to "Echo and Bubba" on his iPad and it never reached Echo. The row was
  filled from the server once, at join, and adding to it from the library
  pushed nothing (the analysis under "Still open: a shared set list does not
  auto-update", below, was right). Now `SetlistSync.plan` (pure, in
  ScoreModel/) does a three-way merge of the row, the server's entries, and
  the entries the row held when last in step on this device; and
  `SharedSetlistSync` carries it out -- push on any change to a shared row
  (seen as a manifest change, so every path counts), an entries listener per
  shared set list, a sync on launch and on return to the app, and a Sync
  button beside the share button that shows in step / syncing / failed.
  An adopted copy records its entry on the arrangement (`link-shared-entry`),
  so library sync carries the link to the account's other devices.
  Proof: SetlistSyncTests (16), SharedSetlistSyncButton (UI, no Firebase),
  check_workflows and check_library_sync (the link), and a two-simulator run
  on the Firebase emulators with the real rules: Ali's add reached Echo's
  row, Echo's removal reached Ali's, the server ended with one live entry and
  one soft-removed, and the Sync button ran a sync. The first emulator run
  found a real fault the unit tests could not: a listener snapshot taken
  during a sync's own uploads was planned from, and the tune was pushed
  twice. The listener is now only a trigger and every sync reads afresh.
- **DONE on the branch (tests only): the unit suite played music through
  the Mac's speakers.** PlayheadTickerTests and PlayheadDriftTests' real-time
  test start the device output; the gate skips them, but a hand run of the
  whole bundle does not, and `SCORANGER_SILENT_AUDIO` deliberately stops at
  the UI tests. Both now turn their own output down: they count frames and
  read clocks, never loudness. Every other playback unit test renders offline.
- **Gate note, 0.18.0 (2026-10-03): two UI tests timed out under the
  four-worker pool and passed alone on the same build.**
  TransportVisibility (no mixer strip after 180s; 15s alone) and
  ContinuousFollows (no play head handle; 108s alone). Both wait on the
  playback graph, which is the slowest thing to build when four simulators
  share the Mac. If either fails a second gate, give it the serial lane.
- **0.18.1, found taking the App Store screenshots (2026-10-04):**
  - FIXED: the iPhone tray pushed play/stop off the left edge of the screen
    for a multi-part score, and while playing (PhoneTransport, phone lane).
  - FIXED: "OMR DRAFT" was on every fresh notation import and on no real
    scan transcription (LibraryModel.isOMRDraft).
  - FIXED: 0.18.0's Sync button pushed a shared row's Play off the right
    edge on an iPhone; on a phone Sync is in the row's ☰ (PhoneSharedRow).
  - FIXED in 0.18.2: chord diagrams for two chords close together overlapped
    (Amazing Grace bars 3-4 and 15-16). Each is drawn smaller to fit the room
    before the next, never below half size (render.diagram_fit,
    ChordDiagrams.fit). Below half size they still overlap, by design.
  - FIXED in 0.18.2: the engine's PDF export drew the tempo mark's note as a
    box; leading music glyphs are now drawn as Verovio's own outlines
    (render._draw_leading_music_glyphs, check_render.py).
  - FIXED in 0.18.2: a pickup read "bar 0" in the transport and page header;
    every reader-facing bar label goes through BarName now.
  - FIXED in 0.18.2: "Part 7" was the part's name "Part" beside its fader
    level 7. An unnamed part is named at import: "Melody" alone, "Part N"
    among several (ops.name_unnamed_parts). Arrangements already in a library
    keep "Part".
- **Open, shared set list sync:**
  - nothing syncs while the app is closed (no push notifications or
    background refresh); a reader sees changes when they open the app;
  - two of one account's devices can each adopt the same new entry before
    library sync tells either about the other's copy. The row keeps one (the
    plan drops the second from the row), but the second arrangement stays in
    that library;
  - a shared entry is a copy pinned at the version it was added at, so a
    later edit to the arrangement does not reach the band (repinning);
  - a shared row's title loses one more button's width (44pt) to the Sync
    button.


## Measure numbers and pagination -- what 0.17.0 does NOT do

- **A measure number's position and size are Verovio's.** `measure-numbers`
  chooses WHICH bars are numbered; nothing nudges or resizes one.
- **The chosen line length is an estimate.** `natural_measures_per_line`
  counts notes per bar against NOTES_PER_LINE (32), read off Verovio's layout
  for a reel and a jig. It has not been measured against a printed fake book,
  a piano score or a whistle tune with a guitar tab under it.
- **Scores paginated by 0.13-0.16 carry no forced-line memory.** Their breaks
  were all written alike, so the first change after this build re-derives them
  at the length they show; a line the reader forced then is not remembered.
- **Print leaves Pencil markup off.** A drawing is stored in the canvas's own
  points at whatever width the page had when it was drawn, not in the PDF's
  coordinates, so putting it on paper needs that width recorded (or the ink
  normalised to the page) first. The engraved pages print in full.
- **Chords the chat wrote as TEXT marks before 0.17.0 stay text marks.** The
  op now refuses a chord name as text; existing ones need "replace the Em text
  marks with chord symbols" (remove_element + set_chords).
- **The launch renumbering writes a version per affected arrangement.** With
  library sync on, two devices launching before either has synced can each
  write one: a harmless fork of two identical versions.
- **"every N" numbers the bars whose number divides by N** (Verovio's rule),
  not every Nth bar counted from the first: with a pickup, or a score starting
  at bar 5, "every 4" is 8, 12, 16.


## Library sync -- what 0.16.0 does NOT do

0.16.0 keeps a signed-in account's library the same on every device
(`librarysync.py`, `LibrarySync.swift`; proved by check_library_sync.py, the
rules tests and a two-simulator run against the Firebase emulators). Left out,
each on purpose and each in the ios/project.yml scope block:

- **Pencil markup on your own library does not sync.** Ink is keyed by score
  uid and version id already (bundle._ink_files), so it is addressable; it
  needs a record kind of its own and a merge rule for two devices drawing on
  one page.
- **Concurrent edits to ONE document merge by document, not by field.** A
  document this device still owes wins on the way down (librarysync.apply
  skips it) and goes up whole. design/FIREBASE.md §7 rule 3 wants per-field
  last-writer-wins; `SyncMerge.swift` has the rule, unwired.
- **Every version is downloaded.** No holding policy or eviction (§5.1, §5.4;
  `HoldingPolicy.swift` exists, unwired). A first sign-in on a new device
  fetches every version of every arrangement.
- **No "two libraries" screen** (§9.3). A second device merges; an arrangement
  imported separately on both shows twice until one is deleted.
- **Google and Apple sign-in are different accounts** unless Firebase links
  them by a shared email. Hide My Email on Apple means the iPad signed in with
  Google and the iPhone with Apple hold two libraries.
- **No App Check** on Firestore or Storage; the rules are the protection.
- **Deletes on the device were not driven through the UI in the simulator
  run** (the simulator panel's access prompt was not answered); they are
  proved at the engine level, check_library_sync.py scenario 3.

## Book import: file copies on the main thread -- FIXED in 0.14.1

Found diagnosing the 0.14.0 gate's one failure, and not its cause. Shipped in
0.14.0 on purpose: within one APFS volume `copyItem` is a clone, and a 28 MB
copy from another volume is ~30-150 ms -- a hitch, not a freeze. 0.14.1 routes
all FIVE incoming copies (share-in, book, PDF, score, bundle -- not the two
first named) through `IncomingCopy.make`, detached and awaited.

If `BookShareIn/testASharedBookIsAskedAboutFoundKeptAndRead` ever fails in the
SERIAL phase, the starvation diagnosis (gate.sh, ENGINE_SERIAL) was wrong. Look
first at the first `BookPageView` raster for the book, which happens while the
review is building, then at these copies.

**The copies were not it.** The first 0.15.0 gate, with the copies already off
the main thread, failed a sibling test the same way in the pool (main thread
"busy" 30s from New book to the review). Its two siblings are serial now, on
the evidence in gate.sh: 1.1s alone, 1.1s alone with every core saturated,
and a sampled main thread that was idle except for a 42 ms wait on dyld's
loader lock inside `os_log` while Python loaded an extension framework.
**Worth knowing beyond the gate:** that is a real way for the UI to stall --
any `os_log` on the main thread waits while the engine's first imports
dlopen their frameworks. 42 ms is nothing; on an old iPad at first launch it
has not been measured. Preloading the engine's imports before the library
appears would remove it either way.

## The baked keys -- the CHAT half is resolved (0.15.0); the OMR half is open

**Chat brings its own key from 0.15.0** (Ali, 2026-09-23), so the OpenRouter
exposure below is gone rather than guarded: no key ships, the deploy refuses an
archive that carries one, and a device forgets the retired key at launch. The
App Attest gateway is no longer needed for chat. The retired OpenRouter key
was revoked at openrouter.ai by Ali on 2026-09-23, which kills the copies in
builds 201-203 and in any Keychain the old self-heal wrote to. Still open: the
OMR key, still baked, capped at one server instance, whose gateway is the only
remaining reason for the plan below.

## (history) The baked keys -- as planned 2026-09-22

**What is exposed.** The build step bakes the repo `.env`'s OpenRouter key into
the app bundle as `openrouter-default-key.txt` (`project.yml`, "Bake OpenRouter
key"), and `LocalChat.swift` falls back to it whenever a reader has not entered
their own -- which is nearly everyone. The OMR service's shared key is baked the
same way (`AppState.bakedOMRKey`). An .ipa is a zip: anyone who downloads
Scoranger can read both in half a minute, and both work from `curl`, unrelated
to the app. Confirmed in the build 201 archive, 2026-09-22. Not an App Review
rejection; a cost and abuse exposure that grows with every download.

**Do now, whatever is built:** rotate both keys (the OMR one was printed into a
session transcript on 2026-09-22), and set a hard monthly spend cap on the
OpenRouter account.

**The fix is a proxy the keys live behind, and it must NOT be Firebase App
Check.** App Check was recommended first and chosen on that recommendation;
it breaks a written rule. design/FIREBASE.md: "Signed out, the app makes no
Firebase contact of any kind. Not anonymous auth, not App Check, not a
configuration call." -- and check_signed_out.py enforces it.

The version that keeps the rule: a small Cloud Run gateway holding BOTH keys in
Secret Manager, fronting OpenRouter and the OMR service, and admitting only the
real app by **Apple App Attest, verified directly** (DeviceCheck's
`DCAppAttestService` on the device; attestation checked against Apple's root on
the server, then a signed assertion per request). No Firebase, no Google SDK in
the app. A signed-out reader's chat and scans already leave the device, for
OpenRouter and for our Cloud Run; they would go to our gateway instead, so no
new category of contact. The privacy policy then needs one sentence -- chat
passes through our server on its way to OpenRouter -- and the gateway must log
no request bodies.

Decisions for Ali before it starts: App Attest is unavailable in the Simulator
and on some older devices, so the gateway needs a policy for those (refuse, or
a rate-limited unattested lane); and whether a reader's OWN OpenRouter key
bypasses the gateway entirely, as it bypasses the baked one today.

## Books: import-as, auto-split, contents -- what 0.14.0 does NOT do

Measured on the Comhaltas San Diego tunebook (134 pages, 124 tunes, jsPDF):
bookmarks 124/124; text-layer headings alone 124/124; read as a SCAN (Vision
on the Mac, text layer and bookmarks ignored) 124/124 starts, 121/124 exact
titles, 0 false starts, all 8 contents/index pages recognised. One book. A
real fake book (handwritten Real Book titles, two tunes a page) has not been
measured, and is the next thing to measure before trusting the scan rule.

- **Two tunes on one page stay one entry.** The split is by page. Fiddle and
  session books do this constantly. Overlapping entries ARE allowed, so a
  reader can give one page to two tunes by hand; the detector never proposes it.
- **Words in the top quarter of a scanned page read as a title.** The scan rule
  judges by position (topmost real words in the band), so a turned page whose
  first line is lyrics or a caption starts a false tune. `check_book_split.py`
  records this as a known limit; the review list's "Join previous" is the fix
  today. A better rule would compare a candidate to the first page of the
  current tune (same left edge, same size as its title).
- **The printed contents and index are recognised, not READ.** They could map
  titles to printed page numbers (the tunebook's printed 1 is PDF page 6) and
  cross-check the headings; nothing uses them yet.
- **No Pencil markup on a book entry.** Ink is keyed to an arrangement's
  version; a book entry is the book's own pages. Take the tune out to mark it.
- **A book's contents cannot go into a set list.**
- **The "New arrangement in an existing piece" choice is not UI-tested.** It
  calls the existing `receiveFile(at:intoPiece:)`; BookShareIn covers the other
  two choices and Cancel.
- **`scor book-split` joins pieces by NAME**, the rule every import follows. A
  tunebook's "Cooley's" lands in a library's "Cooley's" -- intended -- but also
  in an unrelated piece that happens to share the name.

## Staff spacing and the whistle band -- what 0.13.0 does NOT do

`staff-spacing` and the packed fingering band shipped in 0.13.0. Left open,
each on purpose:

- **"Tighter" below what the music claims is impossible, not unbuilt.**
  `spacingStaff` and `spacingSystem` are Verovio MINIMUMS. The op says so in
  its report and the chat tool is told to say so, rather than let a reader ask
  twice for something no option can give.
- **The band floor is four rows.** Three would save one more lyric line, and
  puts the top hole 150 units into the margin toward the system above --
  check_render.py refuses it. Getting to three would mean drawing the column
  tighter than HOLE_PITCH_RATIO, which Ali tuned by eye; that is his call.
- **A note carrying both sung words and fingerings is not packed.** It was not
  moved above the staff before 0.13.0 either (`mei_with_fingerings_above`
  requires every verse on the note to be a hole). Pre-existing, rare, and
  untouched.
- **The canvas's stranded-strip bug is survivable, not explained.** 0.13.0
  lets the choice win when no engrave is in flight (`ScoreLayout.displayed`,
  `awaiting`), and records the layout a page was engraved with rather than the
  choice after the await. What made the handover fail on Whiskey In A Jar in
  the first place was not found.

## Bar numbering: ABC counts from 0, MusicXML from 1 -- RESOLVED in 0.17.0

Ali, 2026-10-03: "when I say put chord measures, it should start at the first
bar." New imports number the first full bar 1 (`ops.number_bars_from_one`, in
`workspace.create_score`), and `number_bars_from_one_everywhere` gives every
arrangement still numbered from 0 one new version at launch. A pickup stays 0.
check_bar_numbers.py. The original entry:

Found while building `ops.bar_label` and nearly shipped as a bug. music21's ABC
reader numbers EVERY tune from 0 whether or not it has a pickup, while a
MusicXML import is numbered from 1. So bar 0 means two different things:

    Morrison's Jig (no pickup)   bar 0, paddingLeft 0.0, a full 6/8 bar
    Star of the County Down      bar 0, paddingLeft 2.0, a two-eighth upbeat

`bar_label` now tells them apart by `paddingLeft` and only calls the second one
"the pickup". What is NOT resolved is the wider oddity: for a pickup-less ABC
tune the app calls the first bar 0 everywhere -- the transport, the play head,
`--from-measure`, and now a report -- while the reader counts from 1. Nothing
is wrong with itself; it just disagrees with the musician. Renumbering on
import would fix it and would move every bar number in every existing library,
including the ones written into set lists and rehearsal marks, so it is Ali's
call and not a build's.

## From the screen recording of 2026-09-22 (Star of the County Down)

Thirty-three seconds on the iPad: lasso five notes and transpose them a third
in key, build a Penny Whistle staff off the top Voice line with fingerings,
then lasso ten and transpose them an octave. Every op did what it was asked.
Three faults in what the app SAID about it, all fixed on
`fix/report-bar-numbers`; two things that looked like faults and are not,
written down so nobody chases them again.

**A report named bar 0 — FIXED.** "3 notes (B3 in bars 0, 3, and 11)". music21
numbers a pickup 0 and seven reports passed that number straight through, so
the reader was sent to a bar no page prints and `--from-measure` does not
reach. `ops.bar_label` now names the pickup instead of numbering it, and every
report carries `bar` as a string rather than `measure` as an int — a `0` a
model can print is not left lying in the JSON for it to find. Op ARGUMENTS
keep their integers; an element address may still say `m0`.
`check_whistle.py` builds a pickup with an out-of-range note in it and fails
without the fix.

**The step said "Harmonising" over a transposition — FIXED.** Both diatonic
ops were labelled "Harmonising a third above, in key" whatever the reader
asked, because the case that prompted the wording was a harmony a sixth below.
A harmony is two lines and this op writes no staff, so the label contradicted
the sentence under it, which correctly read "Transposed the 10 selected notes
up one octave". Now "Transposing …, in key" — the word Ali used, true of both
readings, and ", in key" still separates it from the chromatic `transpose`.

**CLAUDE.md put the whistle fingerings under the staff — FIXED.** It said
"engraved under the part as stacked lyric verses", which reads as below the
staff and is where verses otherwise go. `render.mei_with_fingerings_above`
lifts every one of them above it. The file now says both halves.

**NOT a fault: the octave-transposed notes have ledger lines.** Read off a
video frame as missing; Ali confirmed on the device that they are there. The
engine's SVG was checked first and does emit `<g class="ledgerLines above">`
with real paths, so there was never anything below it to find.

**NOT a fault: the fingering columns do not crowd the staff above.** Called
tight from a scaled-down frame; at full resolution the column sits in clear
white space, which is what `HOLE_PITCH_RATIO = 0.475` is for — the drawn
column is less than half the height of the text rows Verovio reserved for it.

## Shipped 2026-08-15: standalone iPad (engine on-device)

The laptop dependency is gone: CPython 3.14 + music21 embedded in the iOS app
(JSON bridge, workspace in app Documents), Verovio compiled in for rendering
(SVG preprocessed for SwiftDraw), native Swift chat loop over OpenRouter,
share-sheet import, and a Cloud Run Audiveris service for PDF→MusicXML
(`omr-service/`). Cross-device library sync remains a follow-up (iCloud or the
Firebase backend).

## Deferred from 0.11.0 (lyrics and ornaments as element kinds)

**A resized word overlaps the word beside it.** Verovio lays the verse line
out at one size and has no per-verse size, so `adjust-element --kind lyric
--scale` is applied to the drawn page afterwards, exactly as a chord symbol's
size is. A chord symbol is one per bar and has room; syllables are set tight,
so even 1.25x crowds its neighbour and 2x runs across it
(`design/screenshots/lyric-resized-and-moved.png`). The global option that
WOULD re-lay the line out, Verovio's `lyricSize`, also sizes `<harm>` -- that
is the whole reason `engine/scripts/check_render.py` exists -- so raising it
for the words would shrink or grow every chord name with them. A real fix
means per-verse layout, which is upstream work, or accepting a whole-part
size that re-engraves the line and compensating the chord symbols back, which
is the kind of cleverness that breaks quietly.

**A word resized on the iPad does not redraw there.** The engine writes the
size into the verse NAME (`ly@1.5`) and `render.apply_lyric_sizes` applies it
in the PDF export; the app draws its own pages, and
`ios/Scoranger/ScoreModel/ChordAdjustments.swift` knows five kinds, none of
them a verse. The pattern to copy is `FingeringDiagrams.swift`, which already
reads a verse's labelAttr title out of the SVG and rescales its tspan.

**The app cannot point at a word.** `ScoreElementKind` (in
`ios/Scoranger/ScoreModel/ScoreAddress.swift`) lists harm, dynam, text,
fermata and articulation, so tap-to-select and the adjust row do not reach a
lyric; the chat tools do, on both surfaces. Adding it means a selection story
for something drawn in a line rather than as a mark.

**The app cannot point at an ornament either, and does not redraw a resized
one.** The exact twin of the two entries above, for the kind 0.11.0's other
half added. `ScoreElementKind` has no `ornament` case, so a trill or a roll is
not tap-selectable and the adjust row does not offer it; and
`ChordAdjustments.Kind` knows the same five kinds it has always known (harm,
dynamic, text, fermata, articulation), so a resized ornament reaches the PDF
export through `render.apply_element_sizes` and does NOT redraw on the iPad's
own pages. Chat reaches ornaments on both surfaces today. This was found
during the 0.11.0 merge rather than on either feature branch, which is why it
is written here late: `feat/abc-decorations` changed no BACKLOG entry.
Unlike a lyric, an ornament IS drawn as a mark over one notehead, so it needs
no new selection story -- it is the same shape of work as `fermata`, which is
already wired end to end, and is the cheaper of the two to close.

## Deferred from 0.10.0 (ABC import)

**ABC export.** 0.10.0 reads ABC and cannot write it, because music21 cannot:
`ConverterABC.registerOutputExtensions` is empty, so there is no writer to
call. Writing one means emitting headers (X, T, M, L, K with the mode), the
unit-note-length arithmetic, barlines, repeats and endings, tuplets, grace
notes, ties and chord symbols -- a real piece of work, not a line of wiring.
Worth it only if Ali wants to give tunes BACK to thesession.org or to a
session; reading them is what he asked for.

**ABC ornaments -- DONE in 0.11.0, entry kept for the decision it records.**
music21's ABC reader still drops `~` (the roll) and `!...!` decorations;
`engine/scoranger_engine/enrich.py` now puts them back after the reader runs,
covering 33 marks over 56 spellings. The open question here -- what a roll IS
in MusicXML -- was decided rather than deferred: a roll is engraved as a TURN,
because the turn sign is what Irish repertoire actually prints and the
`<other-ornament>` this entry proposed draws nothing in any engraver we use.
The judgement is written down at `enrich.DECORATIONS`, not here.

**The `R:` tune type** (reel, jig, hornpipe, slip jig) is reported by the
import and not stored: it is not notation and has nowhere to live in
MusicXML. If it should be searchable, the piece's `tags` are where it belongs
-- `set_piece_metadata` already takes them -- and the import could offer it
rather than assume it.

**`OMR DRAFT` on rows that never saw OMR.** `LibraryModel.isOMRDraft` is one
version whose op is `"import"` or `"omr"`, so every freshly imported MusicXML,
MIDI and ABC row carries the chip. Predates 0.10.0 and is not ABC's; an
import the reader brought in already editable is not a draft of anything.
Photographed in `design/shots-0.10.0/abc-the-library-after-importing-a-tune.png`.

**Unfiled arrangements, now that imports all get a piece.** After 0.10.0 the
only things in the app that make an unfiled row are the reader choosing
"Remove from piece" and duplicating a row that is already unfiled (the copy
inherits its source's filing, or lack of it). Audited across every bridge op
that creates an arrangement: `import`, `import-pdf`, `duplicate` and
`create-arrangement` all end up filed; the two that do not are `selftest` and
`debug-orphan-arrangement`, which exist for tests. The UNFILED chip, its filter and `LibraryModel.unfiledRows`
all still work and existing libraries are untouched -- no migration was run.
Whether the concept should survive at all is Ali's call about data he already
has, not a build's.

## Candidate: portable score-ops kernel (Rust → iOS/Android/WASM)

Idea (2026-08-15): replace the embedded-Python slice of music21 with a small
Rust kernel implementing just our ~20 deterministic ops + MusicXML I/O,
compiled for iOS, Android, and WASM (browser viewer loses its server too).
The de-risking recipe that makes this trustworthy: **differential testing
against music21 as the oracle** — agentically generate thousands of scores,
run both engines, diff canonicalized MusicXML. Coverage alone is not the bar;
music21's 20 years of MusicXML edge-case semantics are (our real bugs were all
spec bugs: voice-padding phantom rests, enharmonic respelling, part ordering).
Sequence after product validation. Do NOT rewrite OMR this way — neural models
(Legato-class) are obsoleting rules-based OMR; portable OMR = shipped weights,
not transpiled Java.

Deferred from the prototype (see ARCHITECTURE.md for the full product design).
The prototype is: local React viewer + Python score engine, driven by Claude Code.

## Ali's second and third lists of 2026-09-14

Sent while the first seven were being built. Eight items. Two carry a
diagnosis made here rather than a symptom.

8. **The empty space at the bottom of a score page is awkward.** Morrison's jig
   (v016) carries two systems and then roughly a third of the sheet is blank.

9. **Make the bottom drawer like the top.** The transport tray at the foot of
   the score should match the top bar's treatment.

10. **Make the shape straight along the top.** The top bar sits in a rounded,
    inset container with background showing above it; he wants it flush and
    straight along the screen's edge. He drew the corner he means.

11. **Library rows contradict each other about what they hold.**
    "Swallowtail Jig — 20 versions" sits above "Tam Lin (Glasgow Reel) — 3
    arrangements"; "All Blues — 1 version" four rows above "Balkan Ornaments —
    1 arrangement". A piece holds ARRANGEMENTS; a version count belongs to an
    arrangement. He circled both and named them.

12. **"New → Piece does nothing."** DIAGNOSED, and it is not dead — it is
    off-screen. `runQuickAction(.new)` sets `segment = .pieces` and
    `libraryNaming = ""`, and `LibraryView` renders `InlineRenameRow` as the
    FIRST child of the list's `LazyVStack`, above the in-flight imports and
    every section. He was scrolled into the P section of a 41-piece library, so
    the row appeared several screens above the viewport. `LibraryView` has a
    `scrollTo` state but nothing scrolls to the creating row and nothing moves
    focus into it, so there is not even a keyboard to notice. **His own
    screenshots corroborate it**: on Set lists, with two rows and the top of
    the list on screen, the identical row appears with Cancel and Save. The fix
    is scroll-and-focus, not a new action.

13. **`+ New` should just create the thing the segment is showing.** He struck
    the whole New panel out, twice — once from Pieces ("this should just create
    a new piece") and once from Set lists ("this should just create a new set
    list"). The segmented control already says which kind he is looking at, so
    asking again is redundant. Note this does NOT remove the need to fix 12:
    a direct create that scrolls nowhere looks equally dead.

14. **Move the settings gear to the top right, and make it a bit bigger.**

15. **What he expects of a new piece**, in his words: "a new piece w/ no
    arrangements ready to type name" — the inline name field, focused.

## Ali's list of 2026-09-14, found using the app

Six of the seven are in 0.8.2, with the two extra findings. The one still open
is the first, and the analysis is below it so nobody has to find it again.

### Still open: a shared set list does not auto-update (item 1)

BUILT in 0.18.0 (see "Next release (0.18.0)" at the top); kept for the
analysis. NOT BUILT in 0.8.2. What the code does today, read on 2026-09-14:

- A shared set list's local row is filled from Firestore ONCE, at join
  (`AppState.joinSharedSetlist`): claim, fetch the document, fetch the
  entries, adopt each one through the ordinary import, file it into the local
  running order. After that nothing ever reads the entries again. Re-tapping
  the invitation link is the only thing that catches the row up, and it works
  precisely because both halves of adoption are idempotent.
- The only writer of a shared entry is the SHARED screen's Add
  (`SharedSetlistScreen` -> `SharedSetlists.addEntry`). Adding an arrangement
  to the set list on its ORDINARY library row calls `assign-setlist` and
  pushes nothing.
- So both directions are missing for the row Ali actually uses, and the
  feature needs both: a change made locally has to go up, and a change made
  by somebody else has to come down.

What a build of it looks like, so the next pass starts here:

1. A pure `SetlistSync` in `ScoreModel/`: the state of one shared row (not
   shared / signed out / in step / catching up / offline showing a cache /
   trouble) and the DIFF between a remote running order and the local one.
   Testable with no Firebase, like `SetlistPermission` and `SharedOrder`.
2. PULL: an entries listener per bound set list, not just the open one. This
   needs NO new rule and no new query shape -- it is the same
   `setlists/{id}/entries` listen the shared screen already opens, which the
   deployed rules already allow a member. Then a reconcile that adopts what
   arrived, files it in `order`, and removes what was removed.
3. PUSH: `assign-setlist` and the reorder on a bound row have to upload the
   artifact and write the entry, which is what the shared screen's Add
   already does end to end.
4. The sync icon beside the share icon on the row (Ali asked for it by name),
   drawn from (1) so the state is visible rather than inferred.

Why it was not built here, plainly: the pull half imports arrangements into
somebody's library automatically, and it cannot be proven against the real
Firestore without a deploy, which is Ali's to authorise. An auto-reconcile
that writes to a reader's library on evidence no stronger than "it compiles"
does not belong in a release branch. Items 2-4 above are the rest of it.

### The seven as they were written

Seven, from a session with the app on his iPad. Two carry a diagnosis made
here rather than a symptom; the rest are as he described them.

1. **A shared set list does not auto-update.** A change by one member has to
   reach every member. He wants a **sync icon beside the share icon** on the
   set list's row, so the state is visible rather than inferred.

2. **Switching the score canvas between one page, two pages and scroll shows
   the WRONG view for a moment** before it settles. A frame of the old layout
   is drawn before the new one arrives.

3. **The transcribing chip belongs to no arrangement.** He opened one
   arrangement and saw "page 1 of 2" and "Transcribing…" for a job that
   belonged to a DIFFERENT one. Diagnosed: `AppState.omrPendingID` is a single
   app-wide "transcription in flight", and `omrStage`/`omrFraction` read it
   with no reference to what is on screen. `PendingImport` carries `name` and
   `piece` but NOT the arrangement it is transcribing, so there is nothing to
   scope by yet -- the identity has to be recorded before the chip can be
   filtered. Both readers (the More screen's row, the transport's chip) share
   the fault.

4. **A blank region mid-score, and staves that stop before the others.** On
   his 4-part arrangement, one system carries all four staves, the accordion
   staves stop, and the rest of the page is single-staff systems with a gap
   where the others were. Diagnosed: that arrangement was assembled by pulling
   parts out of two different arrangements (one of 1 part, one of 3), and
   `pull_part` neither pads a short part nor reports a length. Its return is
   `pulled` / `added_as` / `position` / `redundant_accidentals_hidden` -- no
   measure count, no comparison against the score it joined. So parts of
   unequal length assemble silently and the reader finds out by looking at the
   page. The op should report the measures it brought and how that compares,
   so a person AND the chat agent both notice.

5. **The piece panel's header should go** -- both the "This piece" title and
   its Done button -- and **Composer, Arranger and Tags must be editable**.
   They render as "—" today and cannot be typed into.

6. **The row action labelled `Arrangement` should read `Details`.** It sits
   between "Move to piece" and "Delete" on an expanded arrangement row.

7. **The three view-mode icons in the score bar want a dashed boundary**
   around them as a group -- one page, two pages, scroll -- in the dashed idiom
   the rest of the app already uses.

### Also seen in the photographs, not on his list

- The chat transcript showed a reader a raw `ValueError: No par…` from a
  failed rename step, then recovered by renaming with `#0`/`#1` indices. A
  stack-trace class name is not a sentence for a musician.
- The top bar said `page 1 of 2` while the canvas said `pp. 1-2 / 2` at the
  same moment, in two-page view. One of those is counting pages and the other
  spreads; they should not contradict each other on one screen.

## The release plan after 0.8.1 (set 2026-09-14)

Everything open in this file is assigned to one of two builds. The split is
the renderer: 0.8.3 owns direct vector rendering and what only makes sense on
top of it, because it is the one change that puts the surface Ali reads music
from at risk and must not ship beside feature work. 0.8.2 owns everything
else.

Assumed, absent an answer, and cheap to change before the interaction is
built: a move destination is a tapped bar plus a stepper for the offset inside
it (drag is gone from this app); size is RELATIVE to the engraved default;
the terms gate sits on sharing rather than on first launch; the renderer ships
behind a flag that is OFF by default.

### 0.8.2 -- what 0.8 promised, plus the test debt

In build order. Each step is testable when it lands and later steps stand on
earlier ones.

1. **Engine ops, with the CLI exercised as a process.** Book rename;
   `adjust_element` generalised past `harm` to other added text and marks;
   move and duplicate for the two tractable element classes (offset-anchored,
   note-attached). Spanners stay out -- re-pointing a slur has no answer when
   the rhythms differ. Every new op gets a test that runs the `scor` BINARY,
   which closes the CLI coverage gap with the same work that adds the ops.
2. **`bridge.py` coverage** for what step 1 added and for what it already
   routed.
3. **The four gaps 0.8.0 named for 0.8.1 and 0.8.1 did not carry**: the set
   list's foot strip and the score bar's second row on the phone; the OMR
   offer as a panel state rather than a row in More plus a chip; Rename on a
   book row (now that the engine has it); Settings as a split inside the
   score's 380pt panel.
4. **Added elements in the UI**: size and position for text and marks through
   the adjust row that chord symbols already use, then move and duplicate
   against the destination above.
5. **Chat dispatch against a stubbed model** -- tool-call dispatch and
   argument shaping asserted with no network and no key. The model's own
   judgement stays manual.
6. **Export from the app UI**, end to end through the share sheet.
7. **The gate debt**, late, when the machine is otherwise quiet: the
   `lyricSize` experiment on PaginationAfterAnOp; reproducing the eight
   rotating landscape failures by hand with the pool-then-serial timing; the
   engine-aware lock so `ENGINE_SERIAL` stops growing; the chord adjust row
   UI test on a stripped staff with its rests hidden.
8. **Copyright and terms posture** -- a written position and the gate it
   implies on the sharing path. Mostly Ali's decisions and a document. It
   belongs here because it gets harder the more external testers hold the app.

### Found while building 0.9.0: two licence texts that do not ship -- RESOLVED in 0.15.0

Both gaps below are closed, and the audit found them to be the smaller part
of it: apart from CPython and the sound bank, NO licence text shipped at all.
From 0.15.0 every credited project the app ships carries its text in the
bundle (`ios/Licences/`, provenance in its README.md), readable from the
credits screen, and deploy_testflight.sh refuses an archive missing one. Two
things the audit changed besides: Liberation.css (GPLv2, never loaded) no
longer ships, and the credits now follow the build products (SwiftProtobuf
out, AppCheckCore and RecaptchaInterop in). What is left:

- **`vendor_engine.sh` installs the Python packages UNPINNED** -- `pip install
  --target` takes whatever PyPI has today. The 0.15.0 vendoring matched build
  203 byte for byte (pypdf 6.19.0, urllib3 2.8.0, while the engine venv runs
  6.15.0 and 2.7.0), so the app and the desktop engine already run different
  versions, and the next vendoring can move the app's without anyone choosing
  to. Pin them in a requirements file both read. Not changed in 0.15.0: a pin
  is a decision, and it needs a gate of its own.
- **midifile's text is upstream master**, because Verovio's copy carries no
  notice and does not record which version it took.
- **The tracked texts are copied at a version** and do not follow a
  dependency that moves. Licences/README.md says so; nothing checks it.

The original entry, as written:

Building Settings -> "How Scoranger works" meant auditing what the app
actually carries, against `ios/project.yml`, `Package.resolved`, the vendored
trees under `ios/Vendor/`, `ios/PythonApp/app_packages/` and each Python
package's own `.dist-info`. The credit list on that screen is the result and
NAMES everything found. Two gaps are about the licence TEXTS, which several of
these licences require to travel with the binary, and neither is fixed by a
screen that names them:

1. **`ios/scripts/vendor_engine.sh` deletes every `.dist-info` on the way into
   the bundle**, and the `LICENSE` file goes with it. Eleven packages ship
   without their text: music21 (BSD-3-Clause), pypdf (BSD-3-Clause), requests
   (Apache-2.0), urllib3 (MIT), certifi (MPL-2.0), idna (BSD-3-Clause),
   chardet (0BSD), charset-normalizer (MIT), joblib (BSD-3-Clause), jsonpickle
   (BSD-3-Clause), more-itertools (MIT), webcolors (BSD-3-Clause). BSD-3,
   MIT, Apache-2.0 and MPL-2.0 all require the notice in a binary
   distribution. The fix is to keep each `dist-info/LICENSE*` rather than the
   whole `dist-info` (which is what made the directory worth deleting -- it is
   mostly `RECORD` and `WHEEL`), and to show them on this screen. A side
   effect of the same deletion, unrelated and harmless: `jsonpickle` reports
   its version as `0.0.0-alpha` on the device, because it reads
   `importlib.metadata`.

2. **The C libraries inside BeeWare's Python build carry no licence files in
   this tree.** `ios/Vendor/VERSIONS` declares OpenSSL 3.5.7, XZ 5.6.4,
   Zstandard 1.5.7, BZip2 1.0.8, libFFI 3.4.7 and mpdecimal 4.0.0, and
   `Scoranger.app/Frameworks/` confirms every one of them ships. The only
   licence file anywhere under `ios/Vendor/Python.xcframework` is CPython's
   own. 0.9.0 NAMES them on the credits screen, beside the Python build that
   brings them, and deliberately gives them no SPDX identifier, because
   nothing in this tree states one and a guessed licence identifier on a
   shipping attribution screen is worse than an honest gap. Source the six
   texts upstream and add them.

Also found, and NOT a problem: `samples-seed` holds two copyrighted editions
in a Debug build only. `project.yml`'s "Bake UI-test fixtures" phase removes
it for every other configuration and `check_no_bundled_scores.py` is the
release gate, both since 0.6.20. An audit of a Debug `.app` will keep finding
it; that is the gate working, not a leak.

### Found while building 0.8.2, recorded because nothing else records it

**Two faults in the shipped rendering path, on every page, for months.** Both
were found in an afternoon by a comparison harness -- the bitmap renderer's
output beside the vector renderer's on the same engraving -- and then
confirmed by eye on real pages. Neither had a test, neither was ever
reported, and both are in the build Ali plays from:

- A tempo mark's digits printed at roughly double their engraved size.
  Verovio writes `♩. = 138` as one `<text>` of three runs -- a 720px glyph in
  the music font, then `" = "` and `"138"` at 405px in the text font -- and
  `SVGForSwiftDraw.flattenTextElements` took the size of the FIRST run for the
  whole block. Fixed in 0.8.2: a music glyph gets no vote in the size, though
  it still decides the FAMILY, because taking the family off leaves Core Text
  drawing `.notdef` and the note becomes an empty box.
- Verovio's italics and bolds were ignored outright. Its stylesheet sets
  `g.dir`, `g.dynam`, `g.mNum` italic and `g.ending`, `g.fing`, `g.reh`,
  `g.tempo` bold; SwiftDraw reads neither the stylesheet (its CSS selectors
  stop short of the `#id g.dir` descendant form Verovio emits) nor
  `font-style`, which its DOM has no notion of. Every direction, dynamic,
  expression mark, bass fingering and measure number was drawn upright. Fixed
  by resolving the face into a font NAME, asked of Core Text rather than
  written down: `Times-Italic` is a macOS PostScript name and iOS ships the
  Times New Roman faces instead, so a name chosen by reading a font list
  would have silently fallen back.

`render.py` was never wrong about either -- cairosvg reads per-tspan sizes and
the stylesheet -- so this is a property of the iPad's renderer alone.

**Four more, from step 4 (size, position, move and duplicate in the UI).**

- **The adjust row only ever opened from a lasso.** `retargetAdjustment`
  builds the session the row is drawn from, and it was called from
  `commitSelection` -- the lasso's route alone. `selectBar`, `addToSelection`
  and `dropFromSelection` wrote `selection` directly, so a chord symbol TAPPED
  at 2x selected, highlighted, raised the chip and had no row under it. This
  is why every attempt to test the row went through the lasso, and the lasso
  is the hard gesture. Fixed by routing all three through
  `select(_:mode:path:page:)`, which already documented itself as the one
  writer every route goes through.
- **A mark's hit frame does not follow its size.** `adjust-element --scale 4`
  draws a text mark four times as big and leaves the frame the geometry
  reports at the engraved size, because the size is applied to the rendered
  SVG (`ChordAdjustments.applySizes` rewrites the tspan's font-size) and the
  model is built from the box the parser computes. A reader who makes a chord
  symbol bigger so they can hit it does not get a bigger target. Not fixed
  here; it belongs with 0.8.3's vector work, where the drawn extent is
  something the app computes rather than reads.
- **`strip-notes` has no route through bridge.py.** The engine has the op and
  the CLI reference documents it; the app cannot ask for it. Found while
  building a fixture that wanted a names-only staff. Step 2's territory.
- **A synthetic pinch is not reproducible.** Eight runs of the same code
  reached 1.00, 1.37, 1.61, 2.91, 2.98, 5.42 and 5.53. Any UI test that needs
  a particular zoom -- and a tap means the NOTE only at 2x and above -- has to
  read `score-canvas`'s accessibility value back and pinch again, which is
  what `MarkAdjustShot.zoomIn` does. It is also why that test asserts nothing
  about what it finds.

**Not covered by a photograph.** The refused move -- the sentence and the row
of onset buttons a note-attached mark gets when nothing starts at the chosen
offset -- is asserted in `MoveDestinationTests` against the engine's real
wording, and has not been photographed. Reaching it needs a fermata selected
by a finger, and a fermata is a smaller target than a dynamic.

**Five more, from steps 5 and 6 (chat dispatch against a stub, and export
from the app).**

- **Three chat tools raised NameError on every call.** `chat.py`'s
  `penny_whistle_fingerings`, `guitar_tablature` and `guitar_chord_diagrams`
  call a `_part` helper that exists in `bridge.py` and did not exist beside
  them. Nothing had ever run the agent's own tool functions -- the engine
  checks call `ops.py` directly and the app's checks go through `bridge.py` --
  so the desktop agent had three dead tools and no test could see it. The same
  shape of failure as `scor whistle-fingerings`, one surface over.
  `check_chat.py` now drives every registered tool and fails with those three
  NameErrors the moment the helper is taken away again.
- **Both agents were a build behind their own toolset.** `add-element`,
  `move-element` and `duplicate-element` shipped in the engine, the CLI and
  `bridge.py` in step 1 and were described to neither agent, so nothing a
  reader could ASK produced a mark. `adjust-element`'s description was worse
  than missing: it still called size "an absolute point size (12 is the
  default)" after step 4 made `scale` the interface, which is the one sentence
  standing between "make that dynamic bigger" and a model sending 12.
- **The share sheet describes a file TWO ways, and which one a test sees is a
  race.** The moment it appears the header reads `Sous le ciel
  quartet.musicxml` with nothing under it; a second later the link metadata
  resolves and the same header reads `Sous le ciel quartet` over `MusicXML
  score · 591 KB`. An assertion on the extension passes or fails on timing.
  `ExportFromTheApp` accepts either, and the photographs catch the first
  state. Worth knowing: iOS resolves all three of our types -- "MusicXML
  score", "Audio Recording" (the .mid) and "PDF Document" -- so what the
  reader hands to another program is typed, not a blob.
- **`PopoverDismissRegion` is not one element.** The share sheet raises
  several, so `app.otherElements["PopoverDismissRegion"].tap()` fails with
  "Multiple matching elements found" rather than dismissing anything. The
  sheet's own X is `header.closeButton`, and that is what the test taps.
- **The Export rows' captions are truncated in the panel.** Seen in the
  photograph, not in any assertion: at the score panel's 380pt the value
  column shows "Open in another notation pr…" and "AirDrop, Files, Ma…". The
  caption is the whole reason those rows say what a format is FOR rather than
  what it is called, and the half a reader gets is the half without the point.
  Cosmetic, and it belongs with whoever next touches ScreenRow's two columns.
- **Export does not wait for the page.** Through the whole journey the score
  behind the panel still read "Opening…", and all three files came out right:
  export reads the version artifact, and the PDF is engraved from it by the
  same renderer rather than from what is on screen. Anyone tempted to make
  export use the drawn page would be trading a working path for a slower one.

**What the comparison harness is worth.** These are the first two faults it
found, and it found them by looking rather than by asserting. That is the
argument for 0.8.3's visual regression tests: the output is about to become
vector, which is what can be asserted on.

**Still open from the same family:** a tempo mark's metronome glyph is drawn
by whatever font the system falls back to, which is why the mark cannot also
be bold -- naming a real font takes the fallback away. Drawing the metronome
glyph ourselves, the way the whistle's circles and the chord grids already
are, buys both. Small, and not urgent.

**A chord symbol's "up" arrow moved it down.** MusicXML's `relative-y`
measures up and so does MEI's `@vo`; the `<harm>` translation negated its own
on the belief that harm was the exception. It is not. Fixed in 0.8.2 along
with generalising the translation to the other four kinds, and
`check_adjust.py` now asserts the DIRECTION rather than only that the mark
moved -- which is exactly what the old check was missing.

**`LazyVStack(pinnedViews:)` keeps a stale rendering for a row whose id has
not changed.** The bug behind "a renamed row did not redraw": after a rename
the section header moved from B to R and the row under it still read the old
name. `rowView` was re-evaluated with the new title -- logged, once -- and the
pinned-header stack kept the rendering it had. Renaming WITHIN one letter
always worked, which is why nobody saw it for as long as the lists have
existed. The fix in place is to identify a row by its slug AND its title, so
the id changes when the name does; the underlying SwiftUI behaviour is
unchanged and will bite again anywhere else a pinned-header list shows text
that can be edited in place.

**`LibraryToolbarFits.testEveryActionIsStillReachable` fails at compact
width.** The Import band covers the page, so the controls the test then
reaches for are not hittable. Pre-existing, not introduced by the phone work;
the fix is the same mutually-exclusive-bands rule the test's second half
already asserts for New, applied to Import at compact width. Out of scope for
the 0.8.2 build it was found in.

### 0.8.3 -- the renderer and what stands on it

1. **Direct vector rendering behind a flag**, off by default, compared side by
   side against the bitmap path on Ali's real scores before the flag is
   considered for flipping. Retires the crisp-deep-zoom item outright.
2. **Selection re-based on the vector output.**
3. **Visual/engraving regression tests** -- worth building only once the
   output is vector, which is what can be asserted on.
4. **A real-device lane**: one iPad with a Pencil, run by hand per release
   against a checklist, because the simulator has no Pencil and nothing runs
   on hardware today.
5. **The OMR pipeline through Audiveris**, in its own lane because it needs
   the installed app on the host.
6. **Multi-tenancy: rules, per-user OMR quotas, cost metering.** Firebase
   touches live infrastructure; every deploy waits for Ali's explicit go.

### Tracked as spikes, in neither build

Neither has an acceptance criterion yet, and inventing one to fit a release is
how a research question becomes a missed date. Each needs its go/no-go
question answered first.

- **Generative arrangement (v2)** -- NotaGen or the NeurIPS-2025 unified
  arrangement model behind the same tool interface. Question: what does a
  piano reduction have to get right before Ali would play from it?
- **Portable score-ops kernel (Rust -> iOS/Android/WASM)** -- question: which
  second platform is real enough to pay for the port?

## TypeSafe / Jev as a fast path for the chat (tabled 2026-09-21)

Ali asked to try `jev-1.13.0`, TypeSafe's "System One" model. Investigated,
not built. Tabled here rather than dropped because two places in this codebase
fit it almost exactly.

**What it is, and what it is not.** It does not generate text and does not call
tools. It takes STATE plus a set of QUESTIONS and returns typed answers with
probabilities: `choice` (one of a defined set), `noul` (does this condition
hold), `score` (a position on a described rubric). `POST
https://api.typesafe.ai/v1/systemone`, bearer token, `model: "jev-latest"`.
So it cannot replace the arrangement agent, which plans SEQUENCES of ops.

**The two fits, in order of how ready they are:**

1. **`analyze` adjudication.** `scor analyze` already emits per-bar harmony
   candidates and this file's own CLI reference says "agent adjudicates". That
   is exactly the documented "select instead of generate" pattern: find the
   candidates in code, use one judgment to pick the intended one. Each bar is an
   independent `choice` over the candidates for that bar, and independent
   questions over the same state run in parallel in one request. Today a chat
   model does this in prose, which is the expensive and least reliable way.
2. **Single-operation routing.** Most real requests are one op with closed-set
   arguments -- transpose by an interval, change an instrument, make the chord
   names bigger. TypeSafe's function-calling cookbook does precisely this and
   returns the function, its typed arguments, and a confidence that is *the
   least certain judgement in the call*. That confidence is the useful part: it
   gives a principled place to fall back to the full agent rather than a guess.

**The shape to build, if it is built:** a fast path for single-op requests,
escalating to the current agent when confidence is low or the request needs
sequencing. Ali's hypothesis is that it will be much faster, which is the first
thing to measure and the reason to try it at all.

**Blocked on:** an API key. Nothing on this machine -- not in the environment,
not in `.env`, no SDK installed, nothing in the keychain; the plugin ships only
documentation. `TYPESAFE_API_KEY` in the repo `.env` is the place, matching how
`OPENROUTER_API_KEY` already works.

**Costs to weigh before it ships:** it adds a THIRD PARTY receiving user data,
so `design/privacy-policy.md` and `design/APP_STORE_PRIVACY.md` both need a
paragraph -- and that work was just finished for the App Store submission. Also
worth knowing that Ali first reported this model as being on OpenRouter; it is
not, and a search of their 443-model catalogue found nothing, which is how the
confusion surfaced.

## Deferred to post-prototype

- **Firebase backend** — Auth, Firestore (metadata/jobs/chat), Cloud Storage, Hosting
- **Hosted agent loop** — server-side chat agent calling the Anthropic API with the
  same tool set the CLI exposes; in-app chat UI; API key / billing management
- **PDF ingestion (OMR)** — Audiveris headless container + side-by-side correction UI
  (clean engraved PDFs first; photos/scans via homr later; handwritten never)
- **MIDI ingestion** — MuseScore CLI conversion (music21's basic MIDI import may land
  earlier since it's nearly free)
- **PDF/parts export** — MuseScore CLI in a container (engine currently exports
  MusicXML/MIDI only)
- **Multi-tenancy** — security rules, per-user quotas on OMR/conversion jobs, cost metering
- **Copyright/ToS review** — users uploading publisher PDFs; sharing features need a rights gate
- **Playback** — OSMD cursor + soundfont
- **Generative arrangement (v2)** — piano reduction / orchestration via NotaGen or the
  NeurIPS-2025 unified arrangement model behind the same tool interface
- **In-browser notation editing** — explicitly out of scope for v1

## Prototype polish (nice-to-haves)

- Live reload via websocket instead of manifest polling
- Measure-range support on more ops (transpose, octave shift)
- `merge_scores`, `extract_measures` tools
- Part extraction to separate printable parts (one part per page/file)

## Build 115 — score canvas polish (from Ali, after build 114)

Queued, not started. Verbatim asks with implementation notes:

- **Drop the title and number from the canvas header.** "The title of the piece
  that's on the canvas doesn't need to be there because the title of the piece is
  also written in the score. So remove that title. And also remove the number, so
  I don't want to see 'number four arrangement' or something too."
  → the principal toolbar item added in `ContentView.detailTitle`. Note the
  sidebar and chat header still carry piece / #N, so the hierarchy stays legible
  once the canvas header goes.

- **Annotation toggle icon should read as locked vs editing.** "Change the icon so
  that it goes between a pencil with a line across it (like 'no edit' or locked)
  and a pencil with no line (means you're in edit mode right now)."
  → `pencil.slash` when off, `pencil` when on, in `ScorePagesView`'s toolbar
  (currently `pencil.tip.crop.circle` / `.fill`).

- **Colour selection is not clear enough.** "The color change is not clear enough."
  → the selected swatch in `AnnotationBar` is a thin ring; needs a much stronger
  selected state (size bump, checkmark, or a filled surround), and the active
  colour should probably show on the toggle itself.

- **Two-finger zoom is broken: it does not anchor.** "As I do it the canvas — the
  point in the center of my fingers should not move, that should be the center of
  zooming, but right now the canvas moves as I zoom and that makes for a very
  glitchy experience."
  → `ScorePagesView` applies `MagnifyGesture` magnification to the page *width*
  inside a ScrollView, so content reflows around the scroll origin rather than
  scaling about the gesture anchor. Needs real anchored zoom: scale a container
  about `MagnifyGesture.Value.startAnchor` and adjust the scroll offset to keep
  that point fixed, or move the paged view into a `UIScrollView` with
  `zoomScale`/`viewForZooming`, which gives anchored pinch for free.

## Next major bucket — a selectable vector score (not a page bitmap)

Awaiting Ali's go-ahead: a UI design revamp is being explored in parallel and
may reshape the interaction. Do not start without it.

### The vision, in Ali's framing

The score should be a real vector representation, the way Finale, Sibelius,
Encore and Dorico render engraved music — "almost like a font", where every
note, every bar, every clef, every sign is an individually selectable object.
Today it is a flattened bitmap, which is why nothing on the page can be
pointed at. Lasso selection is not the goal; it is the first thing the
foundation makes possible.

### Why the current pipeline blocks it

`MusicXML -> Verovio SVG -> SwiftDraw -> PDF page bitmap`
(`ios/Scoranger/VerovioRenderer.swift`). Every coordinate and id is discarded
at render, so the app knows only "here is a picture of page 3".

The existing bar selection (`HighlightCaptureOverlay` in
`ios/Scoranger/ScorePagesView.swift`) maps a drag's horizontal span *linearly*
onto the measure count. That is why its chip reads "≈ bars 12–15": it is an
estimate, not hit-testing.

The material is already there before flattening. Page 1 of the sample quartet
carries 74 `g.note`, 19 `g.measure`, 19 `g.harm` (chord symbols), plus
`g.staff`, `g.layer`, `g.tie`, `g.rest`, `g.barLine`, `g.accid`, `g.stem` —
each with an SVG id. CORRECTION (measured in the spike, see
ios/VECTOR_SCORE.md): those ids are NOT stable — a fresh load of the same file
produces entirely different ones, and the source MusicXML carries no xml:id for
Verovio to adopt. Durable addressing must come from joining the SVG to
Verovio's MEI/getElementAttr output, which does expose measure and staff
numbers.

### Foundation: keep the geometry

1. Stop treating the SVG as an intermediate to be thrown away. Retain the
   parsed per-page document alongside (or instead of) the rasterised page.
2. Build a per-page spatial index of musical elements in page coordinates:
   id, kind (note / measure / harm / clef / articulation / spanner), rect,
   and the staff + measure it belongs to.
3. Map view coordinates into page coordinates through the zoom transform
   (`ZoomableScroll` owns it) so hit-testing is correct at every zoom level.
4. Render selection as an overlay keyed on element ids, so it survives zoom,
   scroll and re-render the way the highlight band already does.

Open question worth settling early: keep rasterising for display and use the
SVG purely as a hit-test model, or render the vectors directly and drop the
bitmap. The second is closer to Ali's "like a font" framing and gives crisp
zoom for free, but it is a bigger change to the drawing path and would need
its own performance work on multi-page scores.

### The interaction that rides on it

Decided with Ali: a **selection mode** (like annotation mode) with a **single
one-finger lasso** plus a **notes / bars / other picker**. The earlier
one/two/three-finger scheme is dropped: finger-count switching collides with
pinch zoom (which Ali specifically praised in build 116), with two-finger-tap
undo in annotation mode, and with iPad system three-finger gestures.

Selection then feeds chat as real context — parts and bar numbers rather than
an estimate — extending what `chatContextWithHighlight` already does.

`HighlightCaptureOverlay` is deleted only when this lands. Removing it first
would leave no way to select bars at all.

### Separate research spike — move/duplicate non-note elements

Selecting a fermata, slur or chord symbol falls out of the index above. Editing
one does not, and this should not be scheduled until two questions are answered:

- **No engine ops exist** for relocating or duplicating an expression or a
  spanner. They must be written as deterministic music21 operations (golden
  rule: notation is never hand-edited).
- **Identity does not round-trip.** Verovio's element ids are generated during
  its own MusicXML->MEI conversion and do not map back to music21 objects, so
  "this fermata on screen" cannot currently be resolved to "that fermata in the
  file". Candidate approaches: match on (part, measure, offset, element type)
  derived from SVG ancestry, or have the engine write a stable id into the
  MusicXML that survives Verovio's conversion. Settle this before designing any
  move/duplicate toolbar.

## Next build (collecting — Ali is still listing items)

### ~~Drag to reorder arrangements within a piece~~ — REMOVED in 0.4.2

Struck. Dragging is gone from the app entirely (NAV_MODAL_FREE_0.4.2 §9: "and
**every drag path**"), so there is no gesture left to design. Reordering inside
a piece is `Move up` / `Move down` on the piece screen, which calls the same
`reorder-piece` op the drag would have. The numbering analysis this section
carried was correct and is now moot: `#N` is derived from `piece.arrangements`,
so the badges and the chat refs follow the buttons the way they would have
followed a drop.

Also queued for this build: penny-whistle fingering notation (see below).

## Penny-whistle fingering notation

Requested by Echo, Ali's son, who plays penny whistle: an option to put
penny-whistle fingerings into a staff — ask for a part to be translated into
fingerings and have them render under the notes to play from, the way guitar
tab does. Not started; here is the shape of it.

Three pieces, in order:

1. **Note → fingering.** A standard six-hole D whistle has a well-defined
   mapping, including the second-octave overblown fingerings and the common
   half-holed accidentals. Look for an existing library or published table
   first; the mapping is small enough to encode directly in the engine if
   nothing suitable exists. It belongs in `ops.py` as a deterministic op like
   every other notation change — never generated by a model.
2. **Rendering.** Fingering diagrams (six dots, filled/open/half) aligned under
   the noteheads they belong to. Verovio has no whistle tab, so this is either
   a new layer drawn from the score model's per-note geometry (the Phase A
   address + spatial index already locate every note on the page) or an
   engraved annotation staff written into the MusicXML.
3. **The ask.** A chat tool so "show penny whistle fingerings for the melody"
   maps to the op on a named part, plus whatever the sheet needs to turn it
   off again.

Open questions: which whistle key to assume (D by default, but the part may be
in any key — transposing whistles are the norm), what to do with notes outside
the instrument's range, and whether fingerings live in the notation (versioned,
exportable) or as a view layer (cheap, disposable). The range question overlaps
with `check-range`, which already knows how to report notes an instrument
cannot play.

## Assessed for build 125, deferred with reasons

### ~~Drag to reorder — the numbering shipped, the drag did not~~ — MOOT

Struck. This section proposed a `List` + `.onMove` rewrite, or hoisting the
drop target to the section, to make the drop land. Neither will be built:
dragging was removed in 0.4.2. Kept only as the reason the `reorder-piece` op
is proven end to end.

### Move/duplicate of lasso-selected elements — tractable, but not free

More feasible than when it was first deferred, and worth stating precisely
what changed. Phase A addresses are (staff, measure, layer, kind, ordinal),
which resolve to music21 objects deterministically. The elements split three
ways:

1. **Offset-anchored** (dynamics, text, chord symbols) carry their own offset
   in a measure. Moving or duplicating is a deepcopy and an insert at a new
   (measure, offset) — deterministic, and an engine op could land in an hour.
2. **Note-attached** (fermatas, articulations) live on a note's `expressions`
   or `articulations`. Moving is remove-from-A, append-to-B — also fine once
   both ends are addressed.
3. **Spanners** (slurs, hairpins) reference their endpoints. Re-pointing them
   is deterministic only when the destination has an unambiguous anchor; "move
   this slur four bars later" has no answer when the rhythms differ.

So the *ops* are largely tractable. What is missing is the interaction: move
and duplicate need a destination, and there is no way yet to express one — the
selection has no drag, and the sidebar work above says dragging in this app is
its own problem. Design the destination first (drag the selection? tap a target
bar? a bar-offset stepper?), then the ops follow quickly for classes 1 and 2.

### Phase B, direct vector rendering — a renderer, not a feature

Still the right direction and still large. The current path is Verovio → SVG →
SwiftDraw → PDF → PDFKit raster, re-rasterized at the settled zoom. Drawing the
score directly means owning glyph rendering: Verovio's SVG places SMuFL glyphs
by reference (`<use xlink:href="#E0A4">`), so direct drawing needs the Bravura
font, the codepoint mapping, and path rendering for everything that is not a
glyph — beams, slurs, staff lines, hairpins. `SVGGeometryParser` gives element
*bounds* today, not draw instructions, so this is new work rather than a
rewiring.

It is also the one change that would put the thing Ali reads music from at
risk, and the problem it was meant to solve — pinch redraw — is currently
adequate (the page re-rasterizes at the settled zoom and stays sharp). Worth
doing behind a flag, in a session where it can be compared side by side against
the bitmap path on real scores, and not in a build that also carries features.

## Sequencing decided by Ali (for the build after the whistle build)

1. **Direct vector rendering (Phase B) first.** Promoted from "deferred, not
   recommended yet" to the next major build. Ali's rationale: he wants vector
   rendering to underpin the selection work.
2. **Then re-base the finger+Pencil selection interactions on it.**

Recorded as decided. One technical note for whoever picks this up, because the
plan reads as though selection is blocked on vectors and it is not:

Selection does NOT depend on the drawing path. The hit-test model is built by
parsing Verovio's SVG and MEI at engrave time (`ScoreModelBuilder`), which
yields per-element frames in page coordinates and durable addresses. The lasso
maps its points into those page coordinates and queries that model. How the
pixels reach the screen — PDF raster today, drawn vectors tomorrow — is not
part of that path. Build 124 ships working selection on the bitmap.

What Phase B genuinely adds, in order of real value:

- **Showing what is selected.** Today the page is one flat image, so the only
  feedback is the lasso outline and the chip's "8 elements in bars 1-4". The
  selected noteheads themselves cannot be tinted. Per-element drawing fixes
  that properly. (A halfway option exists: draw highlight boxes over the bitmap
  from the model's frames — the geometry is already there. Boxes, not tinted
  glyphs.)
- **Direct manipulation.** Dragging a selected element wants that element drawn
  on its own. This is the move/duplicate spike's real dependency.
- **Fidelity of odd shapes.** Curved spanners are indexed by bounding box, so a
  slur's "centre" can sit off the curve. Vector geometry would make lasso hits
  on those exact.

What Phase B does NOT fix, and should not be expected to:

- Precision at zoom — hit-testing is already in resolution-independent page
  coordinates.
- Which element kinds are selectable — that is the parser's class list, not the
  renderer.
- Selection on the remote-engine path — the model is built where the engrave
  happens, which is on-device only.

Risk worth pricing in: re-basing the selection interactions means replacing
code that ships and works today with code on an unproven renderer. If Phase B
is done first, keep the bitmap path behind a flag until the vector path renders
every score in the library correctly at every zoom level.

## Shipped in 0.1.2 — dragging, repeat signs, two pages side by side

All three of what were logged as 0.1.2, 0.1.3 and 0.1.4 went out together.
What is worth keeping from the write-ups:

### Dragging — the earlier diagnosis was wrong (SUPERSEDED: drag removed in 0.4.2)

**Read this as history only.** Every drag path described below was deleted in
0.4.2 on Ali's direction ("remove ALL drag-and-drop interactions entirely").
The diagnosis is preserved because it is a good lesson about blaming the wrong
layer, not because any of it still runs.

Three reorder designs were abandoned in build 125 on the conclusion that "a row
carrying `.onDrag` does not receive drops". That was not the cause. **A still
press of a second opens the row's context menu instead of lifting the drag**,
so under XCUITest the drop was never delivered — while dropping on a piece
*heading* worked, which is what made the row look guilty. Driving it with
`press(forDuration: 0.6, thenDragTo:, withVelocity: .slow,
thenHoldForDuration: 1.2)` delivers the drop to a sibling row in the same
piece, and the `List` + `.onMove` rewrite the backlog called for is unnecessary.

Shipped: a piece heading files an arrangement, a row inside a piece takes its
place in the order, a set list heading adds to the running order, the Unfiled
band unfiles. Every one also stays in the context menu.

~~Still open, if anyone wants them as drags: duplicate, and dragging out of a
set list.~~ Struck — there are no drags. Duplicate and Remove from piece are
buttons on the arrangement screen.

### Repeat signs — what the engine now has

`scor set-structure <score> --kind K --measure N [--to-measure M] [--number N]
[--times N] [--remove] [--move-to N]`, wired to the CLI, the app bridge and
both chat tool lists. Kinds: `repeat-start`, `repeat-end`, `repeat-both`,
`volta`, and the navigation marks (`segno`, `coda`, `fine`, `da-capo`,
`da-capo-al-fine`, `da-capo-al-coda`, `dal-segno`, `dal-segno-al-fine`,
`dal-segno-al-coda`). One op with a `kind`, as the write-up recommended, to
keep the chat tool list short.

`engine/scripts/check_structure.py` engraves every mark and looks for it in the
MEI Verovio returns. It caught the one that mattered: **music21 merges the two
staves of a grand staff into a single MusicXML `<part>`, and in that merge the
second staff's barline replaces the first's — taking the volta's `<ending>`
with it.** A volta now goes on every staff of the joined group. Repeats already
went to every part.

`repeat.Expander` is still unused and still the tool for a future "play this
through as written".

**Ali still owes a screenshot and the exact prompt that failed**, to confirm
that specific case reaches the new op.

### Two pages side by side

`SpreadLayout` (in `Scoranger/ScoreModel`, so the unit tests compile it in)
decides page width and which pages share a row; `ScorePagesView` lays out rows
of one or two. Off by default, under a Reading band in Settings.

Decisions taken, against the questions the write-up left open:

- **No automatic fallback when a panel opens.** The pages shrink and zoom is
  the answer. A setting that silently stops applying is worse than a narrow
  spread the user can see and close a panel to fix.
- **A spread is not capped at 1100pt** the way a single page is, or a wide
  display leaves a band of ground down the middle.
- **The odd last page sits alone**, in the left-hand slot.
- No orientation special-casing: the layout is width-driven.
- The pill still says nothing about which pages are showing. Nobody asked.

The flagged risk — a lasso on the right-hand page selecting from its neighbour
— did not materialise: each page carries its own `LassoAnchor` and the
recognizer picks the anchor under the touch.
`testALassoOnTheRightHandPageSelectsFromThatPage` draws on both halves and
checks the right one gives later bars.

## Shipped in 0.1.2 (bug-fix build) — rhythm integrity, single version highlight

### The rhythm bug, and what it actually was

Reported as "a prompt that had nothing to do with durations made an eighth note
dotted and pushed everything after it a sixteenth later". Three wrong suspects
were ruled out by measurement before the real one turned up:

- **Round-trip rounding: no.** Six consecutive parse/serialize cycles over 6/8
  with dotted-eighth + sixteenth pairs and triplets came back identical.
- **The op named in the version history (`pull-part`): no.** Its whole-part
  branch is a `deepcopy`; it tests clean from clean sources. It faithfully
  copies whatever the source holds, which is why the damage *appeared* there.
- **The other ops in the ladder** (`change-instrument`, `whistle-fingerings`,
  `set-chords`, `limit-part`, `rebuild-part`): all clean, tested.

The fault was the **write**, shared by every entry point including
`add-source` — which is how a corrupt source file got into the library in the
first place, before any arrangement op ran.

Two ops were also breaking scores on their own: `absorb_part` read each note's
offset *after* detaching it (music21 reports 0 for a detached element, so the
melody piled onto the downbeat) and assumed the target staff had no voices;
`consolidate_ties` and `_flatten_copy` handed `stripTies` results straight on.

### Worth knowing next time

- **Measure the file, not the intention.** Several hours went into in-memory
  comparisons that showed nothing, because the score was correct in memory and
  the writer was the problem. `check_rhythm.py` writes and reads back.
- **A duration sum is not a length.** Summing a container's durations treats
  simultaneous notes as sequential, which made a collapsed measure look
  correct. Compare each voice's END TIME against the bar.
- **Diffing two event lists by index lies** once an op adds or removes an
  event: every later pair misaligns and reads as "everything moved". Compare by
  position, or compare sets.
- Under-filled bars are legitimate (pickup, partial bar before a repeat, last
  bar of a piece). Only overflow is corruption; an exact-fill assertion would
  refuse honest scores.

### Version highlight

A prompt group's steps include the group's own face version, so with the steps
open both the group row and a step row claimed the highlight. Open groups let
their step rows own it; collapsed groups stand in for whichever version shows.


## Next build — chord symbols shrank (regression, root-caused)

Ali: chord names used to render much bigger and legible; now they are small
and hard to read. **Found: build 128 did it, and it is a coupling in Verovio's
options, not anything to do with the chord op.**

Verovio has exactly one text-size option, `lyricSize` (default 4.5), and it
governs BOTH lyric verses and `<harm>` chord-symbol text. Build 128 ("whistle
diagrams above the staff, at half size") set `lyricSize` to 2.2 to halve the
fingering diagrams -- in `render.py` (`WHISTLE_LYRIC_SIZE`) and in
`VerovioRenderer.swift` (`FingeringDiagrams.lyricSize`) -- and chord symbols
came along for the ride. Measured on a jig with three chord symbols:

    lyricSize 4.5  ->  chord symbol font-size 405
    lyricSize 2.2  ->  chord symbol font-size 198     (less than half)

It applies whenever the score carries fingerings, which is exactly Ali's
Morrison's Jig: whistle fingerings AND chord names, so the names halved. A
score without fingerings still renders them at 405.

There is no independent harm-size option. `harmDist` and `topMarginHarm` move
chord symbols; they do not size them. `fingeringScale` (0.75) applies to `<fing>`
elements, which is not how these fingerings are encoded.

### The fix, and why this one rather than the alternatives

**Stop shrinking `lyricSize`; scale the diagrams ourselves.** Both renderers
already rewrite each tagged verse glyph into circle paths
(`render.py::_fingering_diagrams`, `FingeringDiagrams.swift`), and the circle
radius is a proportion of the verse font-size. Put `lyricSize` back to 4.5 and
apply the ~0.49 factor inside that pass, so the diagrams stay the size Ali
approved in 128 while chord symbols go back to full size. Our own drawn glyph
should not ride on a global text option that also sizes someone else's text.

Watch: Verovio reserves vertical space from `lyricSize`, so at 4.5 there will
be more room above the staff than the small diagrams need. `lyricTopMinMargin`
and `lyricHeightFactor` are the knobs for that; check it visually.

Rejected: scaling `g.harm` font-size back up in our SVG pass (a compensation
layered on the coupling rather than removing it), and re-encoding fingerings as
`<fing>` elements to use `fingeringScale` (a much larger rewrite).

**A check to add with the fix**: chord-symbol font size must not depend on
whether the score has fingerings. That is a one-line assertion over two renders
and it would have caught this.

Ali is resending a screenshot of the small rendering; it may show he wants them
larger than the 4.5 default, in which case the target size changes but the
decoupling above does not.

## Next release — size and position for things added to a score (Ali)

When Ali adds something to a score he wants to change its SIZE and its
LOCATION. Starting with chord symbols, extending to other added text and marks.

This is the other half of the chord-size regression: the reason a global option
could shrink his chord names is that nothing owns the size of an added element.
Per-element size and offset would make that impossible by construction.

### Shape of the work

- **Model.** A chord symbol is a `music21.harmony.ChordSymbol` at an offset in a
  measure. MusicXML `<harmony>` carries `default-x`/`default-y` (and
  `relative-x`/`relative-y`) for position, and MEI has `@ho`/`@vo` offsets --
  so both a size and an offset can be stored in the notation rather than in
  app-side state, which is the rule this project holds to.
- **Ops.** Something like `scor style-element <score> --part X --measure N
  [--kind harmony] [--size 1.4] [--offset-x 0 --offset-y -2]`, and a
  score-or-part-wide default (`chart-style` already exists and is the natural
  home for "all chord symbols this big").
- **Verovio.** Per-element size needs the size to reach the engraving. Check
  early whether Verovio honours `@fontsize` on `<harm>`, or whether it has to
  be a post-pass in `_fingering_diagrams`' neighbour -- the answer decides
  whether this is an op-only change or an op plus renderer change.
- **UI.** This is where it meets the deferred move/duplicate spike. Offset-
  anchored elements (chord symbols, text) are the tractable case: the lasso
  already resolves an element to a `ScoreAddress`, so a drag of a selected
  chord symbol becomes an offset write, and a pinch or a stepper becomes a size
  write. Notes are the hard case and stay out of scope.
- **Chat.** "make the chord names bigger", "move that Em up a bit" should reach
  the same op, so the tool wants a size/offset argument rather than a new verb
  per adjustment.

### Worth deciding before building

- Whether size is absolute (points) or relative (a multiplier on the engraved
  default). Relative survives a page-size change; absolute is what a user
  means when they say "14pt". Lean relative, and say so in the UI.
- Whether an adjustment belongs to the arrangement (versioned, travels with
  the score, which is this project's model) or to the view (per-device, not in
  the notation). Versioned is consistent with everything else here; it does
  mean an adjustment costs a version.
- Reset. Any per-element override needs a way back to the default, or scores
  accumulate nudges nobody can undo.


## Order of work, set by Ali (2026-08-23)

1. **Chord-name fix** — shipped, 0.2.2 build 133, VALID.
2. **Selection rework** — in progress. 0.2.3 carries steps 1–3 (the
   finger+Pencil scheme scratched, two-finger-tap undo restored, hold-then-drag
   lasso); 0.2.4 carries steps 4–5 (Replace/Add/Subtract chip with
   tap-to-drop-one, and sidebar drop targets that show themselves on lift plus
   the reordered menu). Per the confirmed spec in
   `docs/hold-then-drag-spec.md`.
3. **Size and position for added elements** — chord names first, then other
   added text and marks, adjustable by drag/pinch and by chat. Analysis first,
   then TDD. Scoped earlier in this file.
4. **Awaiting Ali's explicit go-ahead — do NOT start without it**: direct vector
   rendering (Phase B), then re-basing selection on it; and move/duplicate of
   non-note elements, which shares the offset/identity problem with item 3 and
   should be tackled alongside it.
5. **The testing push — AFTER the feature work above, not before.**

## Near-term queue after 0.4.2 (set by Ali, 2026-08-27)

In order. Each ships as its own verified increment.

1. **Share & export.** The score's `Share & export` row pushes to a section
   with no `case`, so it lands on a note saying export lives in the engine.
   `scor export --format musicxml|midi|pdf` already exists and is already
   reachable from the app bridge. Wire the row to it and hand the file to the
   system share sheet — Apple's own sheet is exempt from the no-modal rule.
2. **Bar-position counter.** The `bar 21` readout in the score's top bar. No
   `visibleBar`/`barCounter` exists yet. Cheaper since 0.4.2: the paged canvas
   keeps the viewport inside one page's coordinate space, and
   `ScoreModelBuilder` already indexes every measure's frame in page
   coordinates, so this is a visible-rect query against an index that exists.
3. **Size and position for added elements** (chord symbols first). See the
   section above for the model and the ops. **The UI half of that spec is
   stale** — it assumed drag-and-pinch to reposition, and 0.4.2 removed drag
   while pinch means zoom. The engine op and the storage are unaffected and can
   proceed; the interaction is with the designer.
4. **Crisp deep zoom.** 0.4.2 raised the zoom ceiling to 12x but the page is
   still one bitmap capped at `maxRasterWidth` (5200px), so it softens past
   roughly 3-4x. Assess tiling / re-raster-at-depth against simply waiting for
   Phase B vector rendering, which supersedes it.

## Known coverage gap — the chip's adjust row has no end-to-end test

0.4.3 shipped position and size for chord symbols. Everything about the row is
covered EXCEPT driving it through the UI:

- `ChordAdjustSessionTests` -- 28 cases over the step, the clamps counted
  against what the notation already carries, the ladder, pending, revert, reset,
  and what commits.
- `check_adjust_journey.py` -- chords on a score, nudged, resized, exported, and
  the size and offset read back out of the exported file.
- Two UI tests: that the fixture really adds chord symbols, and that the Chord
  symbols screen carries the default and the two-step reset-all.

What is missing is a UI test that lassos a chord symbol and taps the row. Three
attempts were deleted rather than left flaky: the lasso has to land on a small
target whose position depends on the engraving, and a sweep across 6%-46% of the
page caught notes and rests but never an all-chord-symbol selection. A mixed
selection is deliberately not adjustable, which is correct behaviour and also
what makes the target hard to hit.

Worth trying when someone picks this up: seed a score whose chord staff has been
through `strip-notes` AND has its rests hidden (`chart-style` does that), so a
lasso over the staff can only catch chord symbols. `strip-notes` alone was tried
and the staff's rests were still caught.

## After feature work — the dedicated testing push

Queued deliberately at the end. These are the gaps in the honest coverage
audit: everything below is covered by nothing today, and each is a place a
user-visible failure has either already happened or would go unnoticed.

- **Chat / the LLM path.** Zero automated coverage, on a chat-driven app. The
  headless hook exists (`inbox-chat` / `outbox-chat`, `scripts/test_chat_e2e.sh`)
  and needs a network and a key, so the work is deciding what can be asserted
  without one: tool-call dispatch and argument shaping can be tested against a
  stubbed model; only the model's judgement needs the real thing.
- **OMR / Audiveris.** Zero. `PDFPreflightTests` covers the step *before* OMR
  with synthetic PDFs. The pipeline that produced Ali's Morrison's Jig has never
  been exercised by a test.
- **The `scor` CLI binary.** Zero. Every engine check calls Python functions
  directly, never the process. This gap has already cost us:
  `scor whistle-fingerings` was completely dead with a NameError and no test
  noticed — it was found by hand, twice, months apart.
- **`bridge.py`**, the app's dispatch layer: only exercised incidentally through
  UI tests.
- **Apple Pencil, and any real device.** The simulator has no Pencil; annotation
  tests use a finger stand-in. Nothing runs on hardware.
- **Visual/engraving regression.** `check_render.py` measures font sizes and
  radii; nothing asserts the page *looks* right, so a layout could break with
  every test green.
- **Export from the app UI** (the engine-side export is covered).

## Continuous view: follow does not consult pageFollow -- DONE, and this entry
## was stale

Paged view answers a manual page turn with the Sync chip -- the music keeps
playing, the page stays where the reader put it, and following resumes only when
they ask. This said continuous view had no such gate.

**It has had one since 6db130a2 ("The play head's handle can be dragged"), which
shipped in 0.6.19 build 179.** `ContinuousPlayheadLayer.follow()` guards on
`isFollowing`, and `readerScrolled()` -- wired to the canvas's `onUserScroll`,
which carries the continuous strip as well as the paged canvas -- calls
`state.readerTurnedPage()` and forgets the scroller's target. A hand on the
strip during playback yields following and raises the Sync chip, the same state
and the same rule as a paged turn.

Checked before writing a second fix for it, which is the only reason this note
exists: the entry outlived the work, and the next reader would have implemented
it twice.

WHAT IS STILL MISSING is a test, and it is view-level: `PageFollowTests` covers
the model, so `readerTurnedPage()` clearing `isFollowing` is asserted, but
nothing asserts that a scroll of the CONTINUOUS strip reaches it. That wants a
UI test -- scroll the strip mid-performance, assert the Sync chip appears and
the strip stays where it was put.

## CLOSED 2026-09-18: PaginationAfterAnOp's system count compared two different drawings

`PaginationAfterAnOp.testTheSystemCountAgreesWithTheEngine` compares the app's
per-page system count against a hard-coded 25 that the engine reports for the
accordion solo. Measured, three ways, and the results do not agree with each
other:

- **Run alone, it fails 3 times out of 3**, deterministically, in ~22s:
  `pages=5 systems=5,6,6,6,3` -- 26.
- **In the sharded gate it PASSED**, in ~70s: `pages=9 systems=3,3,3,2,3,3,3,3,2`
  -- 25. Same binary, same xctestrun, same simulator UDID.
- **The engine, re-measured**, reports 25 both on the raw `.mxl` (5 pages,
  `5,6,6,6,2`) and on the imported v001 (5 pages, `5,6,6,5,3`).

So the hard-coded 25 is current, and the app produces EITHER 25 or 26 depending
on something the test does not control.

**It is not the viewport, and this is worth writing down because it is the
obvious wrong answer.** `EngravingOptions` fixes every page-setup value --
width 2159, height 2794, scale 45, all four margins -- and `adjustPageHeight`
is true only for the continuous strip. Paged engraving cannot vary with the
window, so 9 pages and 5 pages are not two fits of one engraving. They are two
different engravings, which means **the music differed**: the library state the
test found was not the same in the two runs, despite
`-resetLibrary -seedTestLibrary`.

That makes this a TEST ISOLATION problem before it is a pagination problem, and
the consequence is the part that matters: **the gate's green on this test is not
evidence.** It passed with a pagination nobody expected, on a library nobody
intended, and a run alone fails. A test that passes under load and fails idle is
reporting on the harness.

**Ruled out on the 0.6.21 line (2026-09-08), so nobody spends the time twice:**

- *A leftover fixture from an earlier test.* `-resetLibrary` does a real
  `FileManager.removeItem` on `Documents/workspace` inside
  `PythonEngine.start()`, BEFORE the engine is configured -- so nothing an
  earlier test did to the accordion solo survives into this one. This was the
  leading hypothesis and it is wrong.

Where to look, in order:
1. Whether `-resetLibrary -seedTestLibrary` actually completed before the probe
   was read, or whether the 240s waits let a partially seeded library through.
   The seeding path already has form here: `seedOutcome` exists because a
   `pull-part` that failed was invisible and three preconditions were written
   before one of them noticed.
2. `lyricSize`. `EngravingOptions.json(lyricSize:continuous:)` takes it as a
   parameter and `render.lyric_size_for(fingerings:)` returns a larger value
   when fingerings are present. A bigger lyric size makes every system taller,
   which is exactly how 25 systems land 3-to-a-page over 9 pages instead of
   5-6 over 5. If the two runs engraved at different lyric sizes, that is the
   difference, and the question becomes why.
3. Only then the app's own inference, `BarPosition.systems(of:)`.
   `check_bar_frames.py` records the hazard -- Verovio nests a slur inside the
   measure it starts in and a group's frame is the union of what it contains --
   so one over-wide bar frame straddling two rows would split one system into
   two, which is an over-count of exactly one. The fragility is worse at 5-6
   systems per page than at 3, which fits both observations.

**Lead 2, `lyricSize`, is CROSSED OFF (2026-09-18, on rel/0.10.0). It is not
the cause and nobody should chase it again.**

- In code it cannot vary. `render.lyric_size_for(fingerings:)` ignores its
  argument and returns `DEFAULT_LYRIC_SIZE`; its docstring says so outright
  ("it used to return something smaller for fingered scores, and the whole
  point of the fix is that it no longer does"). On the app side
  `FingeringDiagrams.defaultLyricSize` is a `static let` of 4.5 and ALL THREE
  `VerovioRenderer` call sites pass exactly that -- only `continuous` varies.
- Measured, it cannot produce the passing shape either. Rendering the imported
  accordion solo through the APP's option set and varying only lyricSize
  across Verovio's whole legal range (2.0-8.0; 12.0 is refused and falls back):

      2.2  pages=5  6,6,6,5,3  = 26
      3.0  pages=5  5,6,6,6,3  = 26
      4.5  pages=5  5,6,6,6,3  = 26   <- the app's actual constant
      6.0  pages=5  5,6,6,6,4  = 27
      8.0  pages=6  4,5,6,6,5,2 = 28

  Nothing yields 9 pages or 25.

**And the measurement above answers the question the entry was really asking.**
At 4.5 -- the value the app actually uses -- the app's own option set gives
`pages=5 systems=5,6,6,6,3`, which is the FAILING observation exactly. The app
is not miscounting. It is engraving correctly for its own page setup, and that
page setup breaks this music into 26 systems.

The engine breaks it into 25 because it engraves with a DIFFERENT setup. Same
file, same Verovio, one process:

    render.page_options()   ->  5 pages, 5,6,6,5,3  = 25
    EngravingOptions (4.5)  ->  5 pages, 5,6,6,6,3  = 26

`render.page_options()` sets neither margins, nor scale, nor breaks, nor
lyricSize; `EngravingOptions` sets all four. Different margins and scale mean
different horizontal room, which means a different number of bars per line --
so a different number of LINES.

So the assertion's premise is false. Its comment says "what has to agree is how
many lines the music is broken into, which is the thing the two methods both
measure" -- but the two methods do not measure one drawing with two rulers,
they measure two different drawings. The total system count is not invariant
across page setups, and 25 is not a number the app can be expected to produce.
A number to compare against would have to be measured with the APP's options.

Which makes the GREEN the accident, not the red: 25 was never a number the app
could produce, so every red was correct.

**FIXED, by making it compare like with like.** `ScorePage.drawnSystems` counts
the `<g class="system">` groups Verovio put in the SVG THE APP JUST RENDERED,
the probe reports it as `drawn=`, and
`testTheSystemCountAgreesWithTheEngraving` asserts the app's inference equals
it, per page and in total. Both numbers now come from one drawing, so no page
setup, margin, scale or lyric size can make them differ for a reason that is
not a defect, and there is no constant left to drift with the fixture. What the
test now guards is what its name says: that `BarPosition.systems(of:)` finds
the systems the engraver drew -- the `check_bar_frames.py` hazard, where one
over-wide bar frame straddling two rows over-counts by exactly one.

**The 0.6.21 line's skip, and the reasoning written into `gate.sh` beside it,
were treating a symptom of this.** The test was not flaky-by-load; it was
asserting something that could not be true, and the load only decided which
engraving it happened to measure.

### Still open, and now separated from the test: the app engraves this file
### to 5 pages or to 9

Measured on rel/0.10.0, same commit, same simulator, `-resetLibrary
-seedTestLibrary` both times:

    in the gate pool   pages=5  systems=5,6,6,6,3   (26)
    run alone          pages=9  systems=3,3,3,2,3,3,3,3,2  (25)

and in the second the inference matched `drawn=` exactly, so the app counted
its own drawing correctly BOTH times. The variable is the engraving, not the
counting.

An earlier draft of this entry guessed the 9-page shape was a score carrying an
op left by another test. **That guess is wrong** and is recorded so nobody
repeats it: the 9-page run above was a clean, isolated, single-test launch with
nothing before it.

Three-per-page against five-or-six means the systems are TALLER, so something
added height. The live lead is `FingeringDiagrams.meiWithFingeringsAbove`: the
accordion solo carries fingerings, that transform rewrites the MEI and sets
`reload`, and if it lands before the probe is read in some runs and after it in
others, the two engravings follow. Untested. It is a rendering question, not a
pagination-test question, and it no longer fails a gate.

The 0.6.21 line SKIPPED this test in its gate for the reasons above. The 0.8
line did not: it runs in the pool and passed in the build 196 gate (79s). A
green here is still not evidence until the two engravings are explained.

**Not a 0.6.20 regression.** Every file feeding that number is byte-identical to
`afa0c572`, which is 0.6.19 build 179 and already on the phone:
`ScoreGeometry.swift` (which computes `systemsPerPage`), `ContentView.swift`
(which surfaces the probe), `ScoreBarLayout.swift`, `EngravingOptions.swift`,
and the test itself.

Worth doing because this test is the observable for issue #4 (pagination
collapse). While it can pass for the wrong reason, nothing it says about #4 can
be believed either way.

## The gate's four workers are over-subscribed for engine-backed UI tests

`ENGINE_SERIAL` in `ios/scripts/gate.sh` grew three times on 2026-09-08, and
every addition had the same shape: a UI test that WAITS ON A CALL INTO THE
EMBEDDED PYTHON ENGINE, timing out under four workers and passing solo in
roughly half the time it was allowed.

- the deletion class -- a delete through the engine; 25-32s solo, past 210s
  under load (the original entries)
- `testTheChordSymbolsScreenCarriesTheDefaultAndTheLadder` -- waits for the
  piece screen to list its arrangements, a manifest read; 36s solo, 117s and a
  timeout under load
- `testEachStripsControlsBelongToThePartItNames` -- waits for mixer strips,
  which come from a playback timeline; 27s solo, found ZERO strips under load

**It is one contention class, not three flakes**, and serialising each is a
targeted remedy that works but lengthens the serial tail every time. Two
structural fixes, neither attempted:

1. **An engine-aware scheduler.** Let at most one engine call be in flight
   across the whole gate -- a lock the test host takes around the ops that
   contend -- so everything else stays parallel. This is the right shape,
   because the contended resource is the engine and not the host.
2. **Fewer workers**, which costs every run to fix a subset of tests, and
   would have to be measured against the ~29 minute wall clock before being
   worth it.

Worth doing when the serial phase starts dominating the gate, or the next time
a test is added to `ENGINE_SERIAL`. Not urgent while the tail is six tests.

## The eight rotating UI tests fail only inside the gate (2026-09-10)

`LandscapeFits` (4), `MixerOnAlisCase` (2 landscape), `MixerTwoChannel` (2
landscape) fail in `gate.sh` -- in the four-worker pool and in the serial phase
-- and pass in every configuration tried by hand on the same build: alone on an
idle device (15-25s), under four workers running only those eight (22-205s),
and the serial phase's own 15-test command on the same device with the same
result bundle (13-27s, 15/15, at load 7.2, while the gate's run of it failed at
load 5.4). The failure is always the same: the window never leaves portrait,
for the whole budget, and the tests immediately after rotate fine.

Six causes asserted and disproved by measurement: a dirty pool, the budget
(20 -> 120 -> 240s, re-asking every 8s), foreign booted simulators, load, the
unit-test target running first, `-resultBundlePath`. The seventh candidate --
the phase begins the instant four workers stop -- is untested. Five gates went
into this on 2026-09-09, on tests of the mixer's landscape layout, while the
sharing feature waited.

**Skipped in `gate.sh` with this record beside them.** Not serialised (they
fail serialised too) and not deleted (they pass by hand and assert real
things). To close this: reproduce the failure by hand -- run the pool, then the
serial command within a minute -- and if that reproduces, capture
`simctl io <udid> screenshot` and the SpringBoard orientation at the moment the
budget expires. Until it reproduces by hand, nothing else is worth trying.
