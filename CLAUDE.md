# Scoranger

Prototype of a chat-driven musical score arrangement tool. **Claude Code is the
arrangement agent**: the user asks for arrangements in natural language, and you
execute them by calling the score engine CLI. A local React viewer renders the
result live.

Design rationale and product plan: `ARCHITECTURE.md`. Deferred features: `BACKLOG.md`.

## Golden rule

**Never edit MusicXML files by hand or generate notation as text.** All score
mutations go through the engine CLI (deterministic music21 operations). LLMs
editing raw notation corrupt scores; tool calls don't. If an operation you need
doesn't exist, add it to the engine (`engine/scoranger_engine/ops.py`) rather
than hand-editing a score file.

**Rhythm is preserved by making the transformations correct, not by refusing
to save.** `workspace._write_musicxml` splits notes at the barline (`makeTies`)
before writing, because music21's MusicXML writer emits a note running past its
barline *and* the bars it swallows, duplicating time. It then reads the file
back and RETURNS whatever odd bars it finds as `rhythm_warnings`, recorded on
the version. It never refuses.

A refusal lived here once and was removed: it blocked importing a scanned score
whose bars were imperfect, then blocked adding a repeat to a score that had
inherited such a bar -- a bar the repeat never touched. Detect-and-refuse is a
band-aid over transformations that should not damage anything.

So:

- **Correctness belongs in the op.** An op that cannot rewrite a part without
  changing its rhythm should leave the part alone and say so in its report
  (`consolidate-ties` and `flatten-voices` rehearse `stripTies` on a copy and
  decline if the result would not hold its meter).
- **Material arriving from outside is accepted as it is.** OMR is imperfect by
  nature and the user brings a score in *so they can fix it*.
- **Proof belongs in the checks, which run before a release, not in front of a
  user.** `engine/scripts/run_checks.sh` runs every one of them, and every fix
  in them was reverted in turn to confirm the check fails without it:
  `check_rhythm.py` (ops preserve rhythm; structural
  marks move no note), `check_import.py` (release gate: every source imports to
  a usable v001), `check_workflows.py` (ten end-to-end user journeys),
  `check_structure.py` and `check_whistle.py` (notation),
  `check_addresses.py` (a selection-scoped op touches only what was selected),
  `check_diatonic.py` (a harmony line stays in the key, and the chromatic
  transposition beside it still modulates -- the contrast is the check),
  `check_chord_diagrams.py` and `check_guitar_tab.py` (the guitar work: the
  shapes against a published chart, the tab against the open strings, and both
  renderers against one golden fragment),
  `check_privacy_manifests.py` (every embedded framework that links OpenSSL
  carries an accurate PrivacyInfo.xcprivacy -- Apple refused EXTERNAL
  TestFlight distribution of 0.6.15 with ITMS-91061 for _hashlib and _ssl, and
  a warning only becomes a rejection at beta App Review, which internal
  testing never reaches),
  `check_playback.py` (the MIDI and the bar map describe the same performance),
  `check_measure_numbers.py` (the bars numbered are the bars the reader asked
  for, on both renderers),
  `check_pagination.py` (a line break the op writes is a line the page draws --
  both renderers ask Verovio for `line` breaks, which `auto` ignores, and a
  paginated score longer than a page turns its pages),
  `check_staff_spacing.py` (the whistle band is smaller and every hole is
  exactly where it was; nothing but the whistle verses changes in the MEI),
  `check_bar_frames.py` (the rectangle the geometry reports for measure N
  IS the Nth bar -- Verovio nests a slur inside the measure it starts in, and a
  group's frame is the union of what it contains, so an unclipped bar can be
  four bars wide and a playhead lands two bars late),
  `check_library_sync.py` (two devices signed in to one account converge on
one library -- the whole library arrives, edits come back, a delete stays
deleted, a second device's own library merges in),
`check_identity.py` (an existing library survives the id migration with
  every reference intact, a rename changes nothing but the slug, and two
  offline devices allocate versions that do not collide), `check_sync.py`
  (a signed-out device pays nothing for sync, and a delete outlives the row it
  deleted), `check_signed_out.py` (no login gates the app: the default
  repository journals nothing, the library's own id costs nothing, and the
  engine the app ships imports no network client -- design/FIREBASE.md §0.2),
  and `check_book_split.py` (a book's tunes are found from bookmarks, page
  titles or Vision's lines by one rule, its contents and index belong to no
  tune, and a page taken out of it carries only the images it draws -- one
  tune out of a jsPDF tunebook was 28 MB).

## Releases and version numbers

**The rule Ali set on 2026-09-18, and it binds whoever is doing the release,
not just the session it was said in:**

- **A substantive feature bumps the MINOR.** 0.10.0 -> 0.11.0.
- **A bug fix bumps the PATCH.** 0.11.0 -> 0.11.1.
- **A build carrying both is a FEATURE build** -- the minor bumps and the
  patch goes back to 0. A release does not get two numbers for carrying two
  kinds of change.
- **Two features in one build still bump the minor ONCE.** 0.11.0 carried the
  ABC decorations and the OMR text pass and is one minor, not two.

`MARKETING_VERSION` lives in `ios/project.yml` and is edited BY HAND when the
feature starts -- before the work, not after it. `CURRENT_PROJECT_VERSION`
counts builds, never goes backwards whatever the marketing version does, and
is bumped by `ios/scripts/bump_build.sh` from the deploy script. **Leave the
build number alone when you bump the version**; the deploy run takes it.

**The scope comment comes first.** Above the version in `ios/project.yml`,
every release since 0.6.9 carries a block saying what the build HAS and, under
`NOT in this build, and said before it starts:`, what it does NOT -- written
before the work, so a feature cannot quietly grow or quietly shrink. Match
that form. A gap the build is knowingly shipping with belongs there AND in
`BACKLOG.md`; one that is only in a commit message is one nobody finds.

## The engine CLI

Always use the venv binary: `engine/.venv/bin/scor` (from the repo root).
Every command prints JSON. Every mutating command creates a **new immutable
version** — nothing is edited in place, so operations are always safe to try.

```
scor import <file> [--name NAME]        # .musicxml/.xml/.mxl/.mid/.abc → arrangements
  # ONE FILE CAN BE SEVERAL ARRANGEMENTS, and the report says which happened:
  # "38 tunes found, imported as 38 arrangements of 1 piece". Read it and relay
  # it -- a reader who drops in a collection and gets one, or forty, has to be
  # told. `tunes_found`, `arrangements` and `pieces_created` are in the JSON;
  # `score`/`name`/`version`/`info` still describe the FIRST one.
  # EVERY ARRANGEMENT GETS A PIECE. An import that arrives without one is filed
  # under a piece named after itself, and the name is matched before it is
  # created -- so tunes that share a title share a piece. Not an ABC rule: it
  # applies to MusicXML, MIDI and scans on every import path.
scor list                               # all scores + versions
scor info <score> [--version vNNN]      # parts, instruments, clefs, ranges, keys, meters
scor versions <score>                   # version history with the op that made each
scor keep-parts <score> --parts "Violin I,Viola"
scor remove-parts <score> --parts "Piano"
scor transpose <score> --interval M2 [--parts "..."]     # m2/M2/P4/P5/-M2/P8...
scor transpose-diatonic <score> --degrees -6 [--parts "..."] [--from-measure N] [--to-measure M] [--key G]
scor transpose-diatonic-elements <score> --degrees -6 --elements "s1/m15/l1/note#0"
  # move by SCALE DEGREES and stay in the key: -6 is down a sixth, 3 up a third.
  # This is a HARMONY LINE. `transpose` above is chromatic -- it shifts every
  # pitch by the same interval and rewrites the key signature, so a G major tune
  # a sixth down comes back in B-flat major. Asked for a violin line a sixth
  # below the tune the arrangement agent answered that diatonic scale-degree
  # transposition was "not supported by the notation toolset", and it was right.
  # The sixths come out major or minor as the key requires (three of one and
  # four of the other across an octave), and no accidental appears that was not
  # already there.
  # Three decisions it makes, all in check_diatonic.py:
  #   - WHICH KEY, per staff and tracked measure by measure, so a key change
  #     partway through counts degrees in the new key from that bar on. A
  #     signature carries no mode and does not need to: a natural minor holds
  #     the same seven pitches as its relative major. A staff with NO signature
  #     is refused by name -- `--key G` is the fix -- rather than guessed as C.
  #   - NOTES OUTSIDE THE KEY have no scale degree. music21 carries the
  #     alteration and hands back F## in G major, which is exact and unwritable,
  #     so a double accidental is respelled to its enharmonic and every such
  #     note is REPORTED with its bar. The op made a choice there; the reader is
  #     who can judge it.
  #   - SCOPE: the -elements form exists for the same reason transpose-elements
  #     does. A selection degraded to a measure range moves the whole bar.
  # It moves notes; it does not add a staff. To write a harmony line as a new
  # part, `pull-part` the melody from the current version first, then run this
  # on the copy.
scor transpose-elements <score> --interval M2 --elements "s1/m15/l1/note#0,s1/m15/l1/note#1"
  # transpose ONLY those elements. An address is staff/measure/layer/kind#ordinal,
  # as the iPad's lasso produces it from Verovio's MEI. Use this, never a measure
  # range, when the user means a selection: a range moves every note in the bar.
  # The MEI->music21 join is proven in engine/scripts/check_addresses.py, which
  # engraves fixtures with the real Verovio and asserts each address resolves to
  # the pitch the MEI names (226/226). The subtle part: MEI counts a chord's
  # notes individually, music21 holds a chord as ONE object -- resolving by
  # stream position lands on the wrong pitch from the first chord onwards.
scor merge-parts <score> --parts "Viola,Violoncello" --name "Accordion L.H." --clef bass
scor split-bass <score> --part "Accordion L.H." --bass-name "Acc. Bass" --chords-name "Acc. Chords" [--instrument Accordion]
scor consolidate-ties <score> --parts "Acc. Bass,Acc. Chords"
scor limit-part <score> --part "Acc. Bass" --max-pitch C4 --monophonic
scor absorb-part <score> --source X --target Y [--rules '{...}'] [--from-version vNNN]
  # rule-governed voice-2 merge; default rules: below_melody, drop_doubling, min_pitch G3, max_span 12
scor strip-notes <score> --part X         # empty a staff of notes, keep chord symbols (names-only staff)
scor octave-shift <score> --part X --octaves -1 --from-measure 55 --to-measure 69
scor rebuild-part <score> --part X --source-version vNNN --base "Violin II" [--overlay Viola] [--rules ...]
scor simplify-repeats <score> --part "Acc. Bass"   # 1-pitch-class measures -> downbeat quarter + rests
scor simplify-rhythm <score> --mode augment|thin [--part X] [--unit eighth]
                     [--from-measure N] [--to-measure M]
  # "Make this easier to play by reducing the 16th notes down to reasonable
  # eighth notes I can't play this fast." The agent answered that it had no tool
  # for rhythmic augmentation or quantization and offered a transposition
  # instead, which was CORRECT -- it refused to invent notation. The gap was an
  # op, and the ask is two different pieces of music, so `--mode` names which
  # one and the report says what it cost. The op does not choose; neither should
  # the agent, silently.
  #   AUGMENT  every value doubles and the meter's denominator halves: 4/4 ->
  #            4/2, every sixteenth written as an eighth. NOT ONE NOTE IS LOST,
  #            no bar is added and nothing is renumbered, so every repeat, volta
  #            and rehearsal mark still points where it did. The cost is TIME:
  #            the passage lasts twice as long, which is to say it sounds at
  #            half speed. That is the third answer nobody raises -- just play
  #            it slower -- written into the notation, and the report says so,
  #            because a reader who only wants relief should not be handed a
  #            rewritten score. Doubling the tempo mark back would undo it
  #            entirely. How long a bar lasts is not a property of one staff, so
  #            this applies to the WHOLE score: naming one part of a multi-part
  #            score is refused by name. 4/4 doubles to 4/2 and no further --
  #            4/1 is not a meter to hand a reader -- so a passage carrying
  #            32nds reaches 16ths in one pass and the report names thinning as
  #            what is left rather than suggesting a second pass that would be
  #            refused.
  #   THIN     attacks are quantized onto the --unit grid and what falls between
  #            them is DROPPED. The passage keeps its place in the bar and its
  #            length, so it still fits whatever else is playing; it is no
  #            longer the same tune. `notes_removed` and `removed_by_measure`
  #            are in the report and must be relayed -- that is someone's music.
  # WHICH NOTES THINNING KEEPS is the metrical judgement: an attack survives if
  # it lands ON the grid, counted from the bar's metrical start so a pickup's
  # paddingLeft is in the sum, and each survivor stretches to the next. Four
  # sixteenths keep the first and third; a dotted eighth plus a sixteenth keeps
  # the dotted eighth as a quarter and loses the pickup sixteenth; an
  # eighth-note syncopation is on the grid and is untouched. A note ALREADY as
  # long as the unit is kept wherever it starts, or three quarter-note triplets
  # -- longer than an eighth, and not what anyone means by too fast -- are
  # two-thirds deleted for landing between the lines. Nothing is ever MOVED: a
  # dropped note is honest and a displaced one lies about when the music sounds.
  # A bar attacked entirely off the grid is left exactly as written and
  # REPORTED, rather than emptied.
  # Two things point AT a note and have to be repaired when it goes. A Spanner
  # does not live on the staff, and a slur whose end was removed is handed to
  # the note that swallowed it (a slur left with one end is dropped and
  # counted); a Beam describes a group, so a thinned bar is re-beamed from the
  # meter. The first render of real music came back with one slur arcing across
  # a whole system and 11 beamspans Verovio could not close.
  # Proof: engine/scripts/check_rhythm_simplify.py, which drives the BINARY --
  # argparse wiring, flag mapping, JSON on stdout, refusals on stderr -- and
  # asserts the judgement bar by bar against fixtures.sax_study. check_rhythm.py
  # holds thinning to the part's LENGTH and augmentation to its factor.
scor analyze <score> [--parts ...]        # per-bar harmony candidates (read-only) — agent adjudicates
scor set-chords <score> --part X --json chart.json   # [{"measure":1,"symbol":"Fm"},...] -> <harmony> symbols
scor clean-accidentals <score> [--parts "..."]
  # hide accidentals the key signature already implies. Display only -- no
  # pitch, no spelling, no key changes. Each part is judged by the key ON ITS
  # OWN STAFF, so an E-flat alto is judged by its WRITTEN key, not concert.
  # Every op that changes pitches runs this already (see below); this is for
  # material that arrived cluttered.
scor set-accidental <score> --elements "s1/m15/l1/note#0" [--add sharp|flat|natural]
                   [--remove] [--show] [--hide] [--color "#CC4125"|none]
  # the manual override. --add/--remove change the PITCH; --show/--hide/--color
  # change only what is drawn. Colour reaches the page: MusicXML
  # <accidental color=..> -> MEI @color -> the SVG glyph.
scor change-clef <score> --part Viola --clef alto [--from-measure N]
scor change-instrument <score> --part Violoncello --to Viola
scor rename-part <score> --part '#0' --name "Violin I" [--abbreviation "Vln. I"]
scor piece-combine --pieces "A,B,C" [--into B] [--name "New name"]
  # fold several pieces into one. The curation step that makes "every import
  # mints a piece" safe: two pieces for one tune become one. The FIRST named
  # survives (slug and uid, so setlists and shares still resolve); its
  # arrangements keep their numbers and the absorbed ones append; a credit the
  # survivor lacks is taken from the first that has one; tags are unioned.
  # THERE IS NO UNDO -- the app confirms on its own screen before calling it.
scor add-element <score> --part X --kind dynamic|text|fermata|articulation|ornament|lyric
                  --measure N [--value V] [--offset QUARTERS] [--placement above|below]
  # put a mark on the page. --value is the dynamic (mf), the words ("dolce"),
  # the articulation (accent, staccato, tenuto, marcato...), the ORNAMENT
  # (roll|turn|inverted-turn|trill|mordent|lower-mordent|inverted-mordent|
  # upper-mordent|pralltriller|slide|schleifer), the fermata's
  # shape (normal|angled|square), or the syllable to sing ("la").
  # AN ORNAMENT IS ITS OWN KIND, not a value of `fermata`: music21 keeps
  # ornaments in a note's `expressions` beside the Fermata but under
  # `expressions.Ornament`, which a Fermata is not -- so the two finders never
  # see each other's marks and "take the roll off bar 12" does not also take
  # the fermata. Most of them arrive from ABC (see enrich.DECORATIONS); this
  # is how one is added, and every verb below addresses it the same way a
  # fermata is addressed. A `roll` and a `turn` draw the SAME mark, which is
  # the Irish-roll decision recorded in `enrich.DECORATIONS`.
  # TREMOLO IS ABSENT ON PURPOSE: music21 writes a <tremolo> with its
  # font-size and relative-x/y and reads it back without them, so a resized
  # one would lose its size at the next op -- an adjustment that appears to
  # work and quietly expires. The same is true of <fermata>, which is a
  # PRE-EXISTING gap in `adjust-element --kind fermata`, not a new one.
  # A LYRIC hangs off the note at the offset, like a fermata, and lands in the
  # lowest verse that note has free; it takes no --placement, because verses
  # are drawn below the staff and "above" would be written down and ignored.
  # The destination is the same one move-element
  # takes -- a BAR plus an offset in quarter notes from its barline -- and the
  # two element classes land by the same two mechanics: offset-anchored marks
  # are inserted at the offset, note-attached ones are attached to the note
  # that STARTS there, and the op refuses and lists the bar's onsets rather
  # than guessing. The report carries the ORDINAL it landed at, which is what
  # adjust-element and move-element address it by.
  # It refuses what the rest of the family refuses: spanners by name, and the
  # three kinds that already have a creating op -- `harm` is `set-chords`,
  # `diagram` is `chord-diagrams`, `tab` is `guitar-tab`. A second way to make
  # a chord symbol is how two things that look alike start behaving
  # differently. An invented dynamic or articulation is refused with the list,
  # because music21 will build a Dynamic out of any string and give it a
  # loudness that then gets PLAYED.
scor adjust-element <score> --part X
                    [--kind harm|diagram|dynamic|text|fermata|articulation|ornament|lyric|tab]
                    [--measure N] [--ordinal N] [--all] [--scale RATIO]
                    [--size PT] [--offset-x TENTHS] [--offset-y TENTHS] [--reset]
  # how big an added element is and where it sits, stored in the notation
  # (MusicXML font-size / relative-x / relative-y) so it travels with the
  # score. `harm` is a chord symbol, `diagram` a chord diagram, `tab` a tab
  # column, and dynamic/text/fermata/articulation are what they say --
  # addressed by the same measure + ordinal, because the reader is pointing at
  # one thing on the page. --scale is RELATIVE to the engraved default (1.0
  # leaves it, 1.5 is half again); --size is the absolute point value for a
  # caller that already holds one, and the two together are refused. Verovio
  # honours none of the three fields, so each renderer carries them across
  # itself.
  # A LYRIC takes a size and refuses an offset by name: a word is drawn under
  # the note it belongs to and nothing here honours a nudge on one. Its size
  # rides in the verse NAME (`ly@1.5`), because MusicXML puts no font on a
  # <lyric> and music21 drops one written on the <text> inside it -- the same
  # reason a tab column's size rides in `gt@...`. Words only: a whistle's
  # fingerings and a tab's frets are verses too and are addressed by
  # --kind tab, not by --kind lyric.
scor move-element <score> --part X --kind K --measure N [--ordinal N]
                  [--to-measure N] [--to-offset QUARTERS]
scor duplicate-element <score> --part X --kind K --measure N [--ordinal N]
                       [--to-measure N] [--to-offset QUARTERS]
scor remove-element <score> --part X --kind K [--measure N] [--ordinal N] [--all]
  # take an added mark off. The verb the family was missing: a mark could be
  # added, moved and resized and the only way back from one was to undo to the
  # version before it, losing everything done since. Addressed like every
  # other verb here -- a bar plus an ordinal in its document order, or --all
  # for the whole part. A TAB COLUMN is refused by name: its anchor is the
  # NOTE, so removing it would mean removing music, and `guitar-tab --clear`
  # is what taking one off means.
  # A WORD is removed -- `--kind lyric` drops that verse from the note, by the
  # same note-attached path a fermata comes off by, and it has no branch of
  # its own because that IS the whole meaning of removing a word. It takes the
  # sung words only: a whistle fingering and a tab fret are verses too, and
  # `--all` leaves both. The verses left are NOT renumbered -- take verse 1 off
  # a note singing two and verse 2 stays on the second line of text, because
  # closing the gap would pull that one word up out of step with its own line.
  # the destination is a BAR plus an offset inside it (0 is the downbeat) --
  # this app has no drag. Offset-anchored elements (harm, diagram, dynamic,
  # text) are copied in at that offset; note-attached ones (fermata,
  # articulation, lyric) are attached to the note that STARTS there, and the
  # op refuses rather than guess if nothing does. Re-attaching is the ONLY way
  # a word moves, and it keeps its verse -- if the destination note already
  # sings that verse the op names the word in the way. SPANNERS (slurs, hairpins) are
  # refused by name: a spanner has two anchors and a destination names one.
scor whistle-fingerings <score> --part X [--whistle D] [--clear]
  # penny-whistle fingerings carried BY the part as stacked lyric verses and
  # ENGRAVED ABOVE its staff: six holes top to bottom, a 7th verse "+" for the
  # overblown octave. Both halves of that matter and this file said only the
  # first, which reads as "below the staff" and is where lyric verses otherwise
  # go. They are lifted by `render.mei_with_fingerings_above`, which marks every
  # fingering verse `place="above"`, and its twin in FingeringDiagrams.swift.
  # A whistle's range is two octaves and its tonic again at the top -- a D
  # whistle plays D4 to D6 -- and EVERY note in it gets a diagram whatever its
  # accidental is spelled as. Both halves of that were bugs Ali photographed as
  # "missing tablature": the chart was keyed by the pitch's NAME, so a D# found
  # no entry while the E-flat it is played identically to found one (and every
  # other enharmonic failed the same way, which OMR and transposition produce
  # freely); and the top D was treated as out of range, which is the top note
  # of a great many tunes. A fingering is a fact about a SOUNDING pitch -- one
  # hole pattern per semitone, twelve of them -- so that is how it is looked up
  # (WHISTLE_D_BY_SEMITONE, derived from the published chart, not retyped).
  # Notes genuinely outside the range are REPORTED with their bars, not faked
  # and not silently dropped; nothing is drawn on the page for them.
  # The notation stores letters (X covered, O open, / half) and both renderers
  # draw them as circles — filled, hollow, half-filled — keyed on the `wf` lyric
  # tag: render.py::_fingering_diagrams and ios/Scoranger/FingeringDiagrams.swift,
  # which must stay in step. Circle GLYPHS are not an option: the rasterizers'
  # fallback font has none and engraves empty boxes.
  # Chart: engine/scripts/check_whistle.py asserts it against the published one,
  # and asserts where the fingerings LAND: not on chord symbols (a ChordSymbol
  # is a Chord in music21, so `recurse().notes` hands the op the chart along
  # with the music), and not silently over a guitar tab -- a whistle owns
  # verses 1-7 and a tab owns 1-6, so one note cannot carry both. Whichever op
  # runs last takes those verses and says how many notes it took them from;
  # CLEARING one leaves the other alone.
scor guitar-tab <score> --part X [--tuning EADGBE] [--capo N] [--position N] [--clear]
  # guitar tablature under a part: a fret number per note on a six-line tab
  # staff, chosen for the LINE rather than one note at a time. The hand covers
  # four frets, stretches one more, crosses strings freely and SHIFTS only
  # where the music leaves its reach -- a small shortest path over (position,
  # layout), because the lowest fret for every note is always the one on the
  # thinnest string, and that writes a melody as one line climbing the top
  # string to the twelfth fret when a player would never have moved. Every
  # shift is in the report with the bar it lands in; --position pins the fret
  # the hand starts at, and left alone the line settles as low as it can.
  # A chord is laid out whole (one string per note, inside four frets), so it
  # can force the hand higher than any of its notes would alone, and the report
  # says which bar that happened in. Notes the tuning cannot play are
  # reported, never transposed into range and never dropped.
  # Engraved the way the whistle's fingerings are: six lyric verses per note,
  # tagged `gt`, verse 1 the HIGHEST string, because a tab staff's top line is
  # the string nearest the floor. A fret number where a string is played, a
  # DASH where it is not -- and the dash is the meaning while the LINE is the
  # drawing: render.py::_tab_staff and ios/Scoranger/ScoreModel/TabStaff.swift
  # run the six lines through the dashes and leave the numbers standing in gaps
  # cut in them. Left as text a column of dashes is six loose hyphens per note.
  # Tunings: EADGBE, DADGAD, DADGBE (drop D). A capo shortens every string by
  # its own number of frets; nothing under it can be played at all.
  # Size and position are adjust-element's business, with --kind tab.
scor chord-diagrams <score> --part X [--tuning EADGBE] [--clear]
                    [--shape "A7=x02020"]
  # a guitar chord diagram over every chord symbol the part ALREADY carries --
  # `set-chords` writes them and `chart_style` places them, and a second notion
  # of where a chord sits would fall out of step with the first one the moment
  # either moved.
  # What goes in the notation is the shape, in the shorthand a player writes:
  # [x,3,2,0,1,0], one entry per string from the low E up, `x` for a string not
  # sounded. The window of the neck, the thick NUT line, the barre and the
  # "5 fr." label all follow from those six numbers, by rules both renderers
  # apply and neither invents.
  # And after them, when there is one to say, the FINGERING:
  # [3,2,0,0,0,3](3,2,0,0,0,4) is a G. The row above the grid is the HAND, not
  # the frets -- ring and middle low and the PINKY on the top E -- and no
  # arithmetic over six fret numbers produces that, which is why it is a table
  # (ops.OPEN_FINGERINGS) and rides in the notation. A movable shape derives
  # from the open one it is a barre of, by the rule a method book teaches: the
  # index bars the fret the nut used to be and every other finger steps up one,
  # so E 023100 becomes F 134211. Where neither knows the hand, the row shows
  # the frets, as it always did -- an invented fingering would be a lie.
  # It rides as a <direction><words> at the symbol's own offset, and that is a
  # deliberate second choice: MusicXML's <frame> is where a diagram belongs and
  # music21 WRITES one, but it drops the frame notes on the way back in, so a
  # diagram would survive exactly one op -- every version is written and read
  # back. The shorthand survives, and exports as a line a player can read.
  # GLYPHS ARE NOT AN OPTION for the grid, the dots or the barre, the same
  # lesson the whistle's circles taught: render.py::_chord_diagrams and
  # ios/Scoranger/ScoreModel/ChordDiagrams.swift draw them as paths, and must
  # stay in step -- check_chord_diagrams.py holds both to one golden fragment.
  # A curated chart of CONVENTIONAL shapes first, a search up the neck second:
  # the search finds a voicing for anything, but it does not know that x32010
  # is *the* C. The two rules disagree, and the chart wins: A7 and Dm7 can both
  # be played open and are both written as fifth-fret barres, so that is what
  # the op draws. --shape "A7=x02020" pins any chord to a shape of your own,
  # ahead of both. Chords with no playable shape are reported, not faked.
  # Transposing the music CLEARS the diagrams (six frets are one chord, and a C
  # grid over a D is worse than nothing); run the op again after.
  # Size and position are adjust-element's business, with --kind diagram.
scor paginate <score> [--measures-per-line N] [--break-at "17,33"]
              [--end-at "12"] [--remove-at "17"] [--clear]
  # WHERE THE LINES BREAK, written into the notation as MusicXML
  # <print new-system="yes"/> so it travels with the score. Changes only where
  # the music is DRAWN -- no note moves and no bar is renumbered.
  #   --measures-per-line 4   lay the whole score out four bars to a line
  #   --break-at 17           bar 17 must START a line
  #   --end-at 12             bar 12 must END a line (how a reader says it)
  #   --remove-at 17          take that break off again
  #   --clear                 remove every break; the engraver lays it out
  # IT ALWAYS WRITES A COMPLETE LAYOUT, and that is forced by Verovio rather
  # than chosen. `breaks=encoded` breaks ONLY where the notation says and
  # NOWHERE else, so a single break on a sixty-bar piece means one short line
  # and then fifty-odd bars crushed onto one system -- which Verovio reports as
  # "Justification is highly compressed" and a reader sees as a garbled page.
  # So the stretches between forced breaks are filled at the score's own line
  # length. FORCED lines are remembered (<miscellaneous-field
  # name="scoranger-pagination-forced">per=4;starts=11;joins=9) and every other
  # break is derived again around them each call: the lines before a forced
  # ending are EVENED OUT (end at bar 10 at four a line gives 4, 3, 3, not
  # 4, 4, 2), no last line holds one bar alone, and a pickup rides in front of
  # the first line without counting toward it. With no length written or given
  # one is CHOSEN (0.17.0; it used to refuse) -- `natural_measures_per_line`,
  # from notes per bar against NOTES_PER_LINE, rounded down to 8, 4, 3 or 2 so
  # phrases line up -- and `measures_per_line_chosen` says so. Relay it.
  # ONLY THE READER'S BREAKS ARE HONOURED. `auto` ignores encoded breaks, so a
  # paginated score is drawn `line` -- encoded LINE breaks, Verovio's own page
  # turns. It was `encoded` through 0.16.0, which breaks pages only where the
  # notation says, and pagination writes none: a paginated score longer than a
  # page was one page running off its foot. But a file from MuseScore, Finale,
  # Sibelius or Audiveris carries its SOURCE EDITION's breaks, made for another
  # page, and honouring the notation unconditionally took the quartet fixture
  # from 8 pages to its publisher's 4 (the 0.13.0 gate caught it). So this op
  # MARKS the score (<miscellaneous-field name="scoranger-pagination">reader),
  # and `render.breaks_for` / `EngravingOptions.breaks(continuous:readerPaginated:)`
  # ask for `line` only on a marked score; every other one lays out as it
  # always has. Paginating replaces the source's page breaks as well as its
  # lines, and never inherits the source's line length. --clear removes the
  # mark. The strip stays `none`. Proof: check_pagination.py, on the real
  # quartet fixture.
scor measure-numbers <score> (--every N | --system | --none | --reset)
  # which bars carry a number: --every 1 is every bar, --every 3 the bars whose
  # number divides by 3, --system the first bar of each line (the engraver's
  # default, and what --reset means), --none nothing. Stored as
  # <miscellaneous-field name="scoranger-measure-numbers">every=3</...>; the
  # renderers carry it to Verovio's `mnumInterval`, named in EVERY option set
  # because setOptions merges, and --none is MEI's `mnum.visible="false"`
  # (render.mei_with_measure_numbers_hidden, MeasureNumbers.meiHidingNumbers --
  # Verovio has no option for it). Position and size are not adjustable.
  # Proof: engine/scripts/check_measure_numbers.py counts the numbers drawn.
scor staff-spacing <score> [--staff N] [--system N] [--fingering-rows N] [--reset]
  # HOW MUCH ROOM the page gives: --staff and --system are the minimum space
  # between staves and between systems in MEI units (0-48; defaults 12 and 4,
  # Verovio's own), and --fingering-rows is the band a whistle column takes
  # above its staff (4-6, default 4). Where the LINES break is `paginate`.
  # STAFF AND SYSTEM ARE MINIMUMS: they open space up and cannot take back
  # space the music claims -- a staff with a whistle column above it is as tall
  # as the column. Relay that when a reader asks for "tighter" and sees nothing.
  # Stored as <miscellaneous-field name="scoranger-spacing"> so it versions and
  # travels. NOT MusicXML's own <staff-layout>/<system-layout>: music21 writes
  # those correctly and Verovio ignores them at every value, measured. The
  # renderers carry the field to Verovio as options -- render.spacing_options
  # and EngravingOptions.json, which name both keys in EVERY option set because
  # setOptions MERGES on a shared toolkit and one score's wide staves would
  # otherwise be the next score's. Only values that differ from a default are
  # written; --reset leaves no field at all.
  # THE FINGERING BAND is the fix for Ali's "too much space above penny whistle
  # tablatures, so scores that have it end up fitting very few lines on a page".
  # Verovio reserves one lyric line per verse -- six for a column's holes -- and
  # the draw pass then stacks the holes at 47.5% of that pitch, so the top half
  # of the band was empty. `render._pack_column` hands Verovio only
  # --fingering-rows verses, the whole pattern riding in the first verse's
  # label ("wf|XXOOOO+"), and `_unpack_fingering_columns` puts the rows back
  # before the draw pass, which is otherwise UNTOUCHED -- every hole, fill and
  # octave mark lands at exactly the height above its staff it always had.
  # FingeringDiagrams.packColumn/unpackColumns are the Swift twins.
  # `lyricSize` would also shrink the band and is the wrong lever: it is
  # document-wide, so it shrinks every chord name and compresses a guitar tab
  # on the OTHER staff. FOUR is the floor, by measurement: at three the top
  # hole reaches into the margin toward the system above, which check_render.py
  # refuses. Proof: engine/scripts/check_staff_spacing.py (fewer pages, same
  # holes, MEI byte-identical outside the whistle verses, both renderers' constants)
  # and FingeringDiagramTests, which draws check_staff_spacing's golden page
  # (Fixtures/fingering-packed-*) and must get render.py's 420 circles.
scor set-structure <score> --kind KIND --measure N [--to-measure M] [--number N]
                   [--times N] [--remove] [--move-to N]
  # repeats, voltas and navigation marks. KIND is repeat-start / repeat-end /
  # repeat-both / volta / segno / coda / fine / da-capo[-al-fine|-al-coda] /
  # dal-segno[-al-fine|-al-coda]. A repeat barline goes on every part, and a
  # volta on every staff of a grand staff -- music21's grand-staff merge drops
  # a volta written to the top staff alone. --move-to is remove-then-add.
  # engine/scripts/check_structure.py engraves each mark and checks the MEI.
scor set-rehearsal <score> [--measure N] [--mark A] [--remove] [--move-to M] [--reletter]
  # rehearsal marks, written to EVERY part -- the workflow is parts-first and a
  # mark on the top staff alone is missing from every part but the first. The
  # cost: Verovio anchors one direction per part to the SAME staff of a
  # combined score, so the render dedupes them (render.mei_with_deduped_rehearsals
  # and ios/Scoranger/ScoreModel/RehearsalMarks.swift, which must stay in step).
  # No --mark takes the next free letter; --reletter re-labels in bar order,
  # A-Z then AA, BB, CC. Size and position are adjust-element's business.
scor set-metadata <score> [--title T] [--composer C] [--arranger A]
  # the ONE title: the arrangement's name in the library and the title engraved
  # at the top of the page are the same value. Versioned, like any notation
  # change. `rename-score` is the same op under its older name.
scor repair-titles [--apply]
  # the other half of the v001.mxl fix. `set-metadata` and the import guard
  # protect the way IN; they cannot touch a title already written into the
  # notation of versions on disk, and a library OMR'd before the guard existed
  # engraves the workspace's own file name at the top of every page. This lists
  # those arrangements, and with --apply gives each a corrected NEW version
  # through set-metadata -- no history rewritten, nothing edited in place,
  # undoable like any version. The replacement is the arrangement's own name
  # (or the piece's), spelled out; an arrangement nothing can name is REPORTED,
  # never given an invented title. A scan whose latest version is still a PDF
  # is left alone: there is no notation to correct.
  # The app offers the same op in Settings, and only while the scan finds
  # something -- derived from the library, never a per-device flag, which would
  # fan out and re-run on the next iPad.
scor check-range <score> --part "Violin I" [--instrument Viola]
scor export <score> --format musicxml|midi|pdf --out <path> [--version vNNN] [--parts "..."]
  # PDF rendering: Verovio + cairosvg + pypdf, all in the venv (engine/scoranger_engine/render.py).
  # Also via API: GET /api/export?score=..&version=..&format=pdf&parts=.. (viewer's checkbox export)
scor playback <score> --out <path.mid> [--version vNNN]
  # the score AS PERFORMED, plus the map from its beats back to the page. NOT
  # a version: playback is a reading of the arrangement, like `info`.
  # The performed score differs from the engraved one three ways, and both the
  # MIDI and the map come from ONE object so they cannot drift apart:
  #   - repeats and voltas are PLAYED OUT, so the beat->bar map is one-to-MANY
  #     (bar 1 sounds at beat 0 and again at beat 8) -- which is why the map is
  #     a list of spans and never a dict keyed by bar;
  #   - written pitch becomes SOUNDING pitch, or a B-flat clarinet plays a tone
  #     sharp against every other part;
  #   - the click grid is emitted, not the rule for it: 6/8 gets two clicks a
  #     bar, and a pickup's click is not a downbeat.
  # Beats are quarter notes, the unit iOS's AVAudioSequencer reports its play
  # head in. Proof: engine/scripts/check_playback.py.
```

### Accidentals are normalised by the ops, not patched afterwards

Any op that changes pitches or spelling recomputes which accidentals PRINT,
against each part's own written key (`ops.normalize_accidentals`, wired into
transpose, transpose-elements, respell, change-instrument, octave-shift,
merge/split/absorb/pull/rebuild/limit/flatten/simplify). The report carries
`redundant_accidentals_hidden`.

This exists because a user was handed an alto sax part full of sharps that were
already in its key signature. Two music21 behaviours combine to cause it: a
respelled pitch gets a NEW `Accidental` whose `displayStatus` is None, and None
prints; and music21 runs `makeAccidentals` at most once per stream
(`streamStatus`), so a score that has been written and read back -- which is
every version in the workspace -- is never normalised again. `overrideStatus=True`
is what makes it recompute. A fixture built in memory cannot show the bug, so
`check_accidentals.py` round-trips every fixture through a real write first.

### Adding to the toolset

**A tool that CREATES an element ships with the tools that MANIPULATE it** --
adjust, move, resize, remove -- and with the agent's description of them. A
create-only op leaves the user asking for something the agent then cannot undo
or nudge, which is worse than not having offered it. `set-structure` is the
shape to copy: one op that adds a mark also takes `--remove` and `--move-to`.

The same rule governs replacing an affordance: **keep the current access path
until its replacement exists.** Do not remove the old way of reaching a feature
in the build that introduces the new one; never drop the feature.

Part names match case-insensitively, exact first then substring; `#N` targets a
part by index (essential when OMR leaves several parts with the same name). On a
bad name the error lists the available parts — read it and retry.

## Books (a collection tunes are read or taken out of)

A BOOK is one PDF holding many tunes -- a fake book, a session tunebook. It
is not a piece and not an arrangement.

```
scor import-book <file.pdf> [--name NAME]
scor book-detect <book> [--ocr lines.json]   # PROPOSE the tunes; writes nothing
scor book-contents <book> --plan plan.json   # keep them: the book stays ONE book
scor book-contents <book> --clear
scor book-split <book> --plan plan.json      # take them out: an arrangement each,
                                             # under a piece of its name (joined by name)
scor book-extract <book> --from-page N --to-page M --name X [--piece P]  # one, by hand
```

`book-detect` prints `{entries: [{id, title, from, to, evidence}], matter,
unassigned, needs_ocr}`, and `--plan` takes that output as it is, edited or
not. Evidence, strongest first: the PDF's BOOKMARKS; the largest line at the
top of the page on its TEXT LAYER, running headers and page numbers excluded;
for a scan, Vision lines the app supplies for the pages in `needs_ocr`, judged
by POSITION (topmost real words), because Vision's heights are ink boxes. A
page with no title continues the tune before it; a contents or index page
belongs to none. **Relay the proposal before committing it** -- how many tunes,
from what evidence, which pages belong to none -- and say which of the two
commits the reader asked for: contents keep the book whole, split makes pieces.
`booksplit.py` has the rules; BACKLOG has what they get wrong.

## Sources (other found editions of a piece)

A score owns *versions* (its arrangement history) and *sources* (other editions/
tabs of the same piece, imported for reference and cherry-picking):

```
scor add-source <score> <file> --name "MuseScore tab version"
scor info <score>                       # the arrangement
scor pull-part <score> --from src:s01 --part "Violin II" [--as NAME]      # add as new staff
scor pull-part <score> --from src:s01 --part X --replace Y                # swap a whole part
scor pull-part <score> --from src:s01 --part X --replace Y --measures 21-36  # just a passage
scor pull-part <score> --from v007 --part Piano                           # history works too
```

When the user says "bring X from that other score in": add it as a source if it
isn't one, inspect it (parse `workspace/<slug>/sources/sNN.musicxml` or read its
parts snapshot in the manifest), compare against the arrangement, then pull.
Watch for key mismatches — sources may be in a different key than the
arrangement; transpose the pulled material to match (pull, then transpose the
target part/measures). Sources are read-only; pulls only mutate the arrangement.

## ABC (thesession.org)

thesession.org publishes Irish traditional music as ABC, and `scor import`
takes `.abc` like any other notation. What matters about it:

- **Modal keys work.** `K: Edor` is E dorian with two sharps, `K: Amix` A
  mixolydian. This repertoire is full of them and reading them as major would
  make the feature useless rather than merely lossy.
- **A tune's page is many SETTINGS of one tune.** `/tunes/27/abc` downloads 38
  settings of "Drowsy Maggie", each its own `X:` block and all carrying the
  same `T:`. They import as 38 arrangements of ONE piece, because the piece
  rule matches an existing name before creating.
- **A set is ONE `X:` block** holding several tunes joined by a mid-body
  `T:`/`K:`. music21 reads it as one continuous score with a key change, which
  is what a set is, so it stays one arrangement. A file of several `X:` blocks
  with different titles is several pieces.
- **What survives**: repeats, first and second endings, pickup bars, triplets,
  grace notes, slurs, staccato, chord symbols, `Q:` tempo, `C:` composer,
  unicode titles. All of it proven to the written FILE in
  `engine/scripts/check_abc_import.py`.
- **Decorations are CARRIED, and they did not used to be.** music21's ABC
  reader drops `~`, `T`, `!trill!` and the rest -- and for `H`, the fermata,
  it drops THE NOTE: `HA2 B2 c2 d2` parsed as three notes, so every tune
  imported with a fermata in it was quietly a note short.
  `scoranger_engine/enrich.py` is the stage that fixes both halves: it reads
  the ABC, strips the marks before the parse, and attaches the music21
  objects afterwards. It is written as a NAMED STAGE, not a branch inside
  `read_notation`, because every importer loses something and this is where
  the next one is put back.
  A mark finds its note by COUNTING note events, so the restore checks the
  tune's event total against the stream's AND each mark's ABC note letter
  against the note it is about to hang on, and attaches nothing to a tune
  where either disagrees. A mark on the wrong note is worse than a mark
  reported as missing. Proven over 540 real thesession.org tunes: 2098
  carried, 0 misplaced.
  **THE ROLL IS A JUDGEMENT.** An Irish roll (`~`) is its own idiom with no
  glyph of its own in MusicXML or SMuFL, and it is engraved here as a TURN
  (`<turn/>`, the ∾ above the notehead) -- the standard sign whose shape the
  roll's five notes describe. `~` and `!turn!` therefore look identical on
  the page. One line in `enrich.DECORATIONS` changes it.
- **What does not survive**: `R:` (reel/jig/hornpipe) has nowhere to live in
  MusicXML, and `!...!` spellings with no music21 object. Both are in the
  import report's `abc` key beside `decorations_carried`. **Relay them.**
- **Ornaments are editable like any other mark**: `--kind ornament` on
  `add-element`, `move-element`, `duplicate-element` and `adjust-element`.
- **There is no ABC export.** music21 reads ABC and cannot write it
  (`ConverterABC.registerOutputExtensions` is empty). Export is MusicXML, MIDI
  or PDF.
- `.abc` is not a free extension: the system tags it `public.alembic` (Pixar's
  3D scene cache), which is why the app claims that type too.

## PDF ingestion (OMR)

Audiveris 5.11 is installed at `~/Applications/Audiveris.app`. Pipeline for a PDF:
1. If the PDF bundles score + parts, extract the score pages first (pymupdf is in
   the engine venv): `insert_pdf(doc, from_page, to_page)`.
2. `~/Applications/Audiveris.app/Contents/MacOS/Audiveris -batch -export -output <dir> <pdf>`
   → writes `<name>.mxl`.
3. `scor import <name>.mxl --name "..."` then `scor info` and **verify against the
   source pages** (part count, clefs, measure count, meter, key). Unlabeled staves
   come in as "Voice" — fix with `change-instrument --part '#N'` + `rename-part`.
4. OMR output is a draft: expect missing/wrong dynamics, articulations, ties.
   Keep source page images in `intake/<piece>/` for comparison.

`change-instrument` is the flagship compound op: it swaps the instrument,
converts written/sounding pitch for transposing instruments, octave-shifts the
line to best fit the new instrument's range, picks the idiomatic clef, and
reports any notes still out of range. **Always relay its report to the user**
(octave shift applied, remaining out-of-range notes with the bar each is in).

### A report names a bar the page has

Every report that says where something is carries `bar` — a STRING, and the
pickup's is `"pickup"`. It used to carry `measure`, straight from music21,
which numbers a pickup 0: a whistle range report read "3 notes (B3 in bars 0,
3, and 11)" on Ali's iPad for a tune whose bar 0 is its two-note upbeat. No
page prints a bar 0, and `--from-measure` starts at 1, so the reader was sent
to a bar that is not there. `ops.bar_label` is the one place that decides it
and `check_whistle.py` holds it. Op ARGUMENTS are the other surface and keep
their integers — an element address may still say `m0`.

## How to behave as the arrangement agent

1. **Orient first**: run `scor info <score>` before planning any arrangement.
2. **State your plan** in one or two sentences before executing ("I'll extract
   Violin I and Viola, then move the viola line to alto clef").
3. **Verify after**: check the JSON output of each op; after instrument changes,
   confirm the range report is clean or tell the user which measures need attention.
4. **Musical judgment is your job**: choose sensible clefs, octaves, and keys;
   flag musically questionable requests (e.g. a flute line moved to tuba) rather
   than silently producing garbage.
5. The viewer auto-refreshes to the **latest version** of the selected score
   within ~2s of any engine command. Tell the user what they should now see.

## Data model (local SQLite, document-shaped)

Source of truth: `workspace/scoranger.db` via `scoranger_engine/db.py`.
- `scores/{slug}` — score document (name, title, composer, latest version id)
- `scores/{slug}/versions/{id}` — immutable version documents: the op + args
  that produced it, parent version, timestamp, and a **parts snapshot**
  (name/instrument/clef/range/notes per part)
- Artifacts (`workspace/<slug>/<version-id>.musicxml`) stay outside the DB,
  referenced by filename
- `workspace/manifest.json` is a projection of the DB for the app and the
  viewer; it's rebuilt after every mutation

Never write meta files by hand; the DB is authoritative.

### Two names per thing: `slug` and `uid`

- **slug** is the local handle: the directory on disk, what the CLI takes, what
  chat means by `arr:<slug>`. Derived from the title, so `rename_slug` MOVES it
  and rewrites every local reference. Local to one device.
- **uid** is the identity: an opaque `ids.new_id()`, assigned once, never
  rewritten, unique with no coordination. Every score, piece, setlist, book and
  source has one. Sharing and sync address this, never the slug.

A **version** has no slug. Its key is an opaque id, and `vNNN` is a *display
label* on the document (`workspace.version_label`). Both resolve:
`--version v012` and `--version <id>` reach the same version, so everything in
this file that says `vNNN` is still true. Show the label, key on the id.

This replaced two identifiers that were computed from things that move: a
score's key was `slugify(title)`, and a version's was `v{row count + 1}`, which
two devices working offline both resolve to the same value. Rationale and the
plan this belongs to: `design/FIREBASE.md` §3. **The engine does not get a
`FirestoreRepository`** — it runs on-device and a shipped client cannot hold
service-account credentials, so sync belongs beside it in Swift (§2).

### Sync is a decorator, and only when someone signs in

`scoranger_engine/sync.py` wraps the repository through
`workspace.repository_factory` and records what this device owes a server: a
`rev` on each document, and a per-document journal that survives the row it
describes -- which is what stops a swept-away delete coming back from another
device. **It is installed at first sign-in** (`librarysync.bind`, 0.16.0) and
stays on, signed in or out, once `workspace/sync.db` exists. Never signed in
there is no journal file, no `rev`, and no Firebase anywhere in the app; that
is a product decision
(design/FIREBASE.md §2, §9.1), not an accident, and `check_sync.py` asserts it
first. The Swift half that consumes it -- `VersionGraph`, `SyncMerge`,
`ArtifactHolding` in `ios/Scoranger/ScoreModel/` -- decides forks, per-field
merges and what may be evicted, and is pure logic under `ScorangerTests`.

**Library sync (0.16.0)**: `scoranger_engine/librarysync.py` turns the library
into RECORDS named by uid (translating the slugs documents point at each other
by) and applies records back; `ios/Scoranger/Account/LibrarySync.swift` carries
them to `libraries/{libraryId}/{collection}/{uid}` in Firestore (the engine's
fields as one JSON `payload` string) and their bytes to Storage under
`libraries/{libraryId}/files/`. Its pull state lives in
`workspace/.library-sync/`, beside the journal, so it dies with the library.
After changing engine code, **re-run `ios/scripts/vendor_engine.sh`**: a new
engine module the bridge imports is absent from the app until you do, and the
engine then fails to start at all.

**Titles and credits**: a score has exactly one title. It lives in the notation
(MusicXML `<work-title>` *and* `<movement-title>` — Verovio engraves the
movement title, so both are written to the same value) and the score document's
`title`/`composer`/`arranger` are a *projection* of the latest version's
notation, never independent fields. Edit through `set-metadata`; never set a
title by writing the document. Two music21 behaviours the op exists to contain:
it seeds the movement title with the source *file name* when a file carries no
title (which then engraves as "my-score.mxl"), and it stamps itself in as the
composer on every export when none is set (stripped in `workspace._write_version`).

Extra commands: `scor delete-score <slug>` (irreversible),
`scor serve` (local API on :8765 — powers the viewer's New… upload; keep it
running alongside the viewer).

## The viewer

```
engine/.venv/bin/scor serve &      # engine API (for New… uploads)
cd viewer && npm run dev           # → http://localhost:5173
```

React + OpenSheetMusicDisplay. Polls `/manifest.json` every 1.5s; renders the
selected score/version; shows the parts of the displayed version; "New…"
uploads MusicXML/MIDI through the engine API (`/api/import`, proxied by Vite).

## Layout

```
engine/            Python: music21 ops + CLI + local API (venv at engine/.venv)
viewer/            Vite + React + OSMD
workspace/         scoranger.db + <slug>/<version-id>.musicxml + manifest.json
```

Setup from scratch: `python3 -m venv engine/.venv && engine/.venv/bin/pip install -e engine`
then `engine/.venv/bin/python engine/scripts/make_demo.py` for a demo score,
and `cd viewer && npm install`.
