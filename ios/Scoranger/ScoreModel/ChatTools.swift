import Foundation

/// The tools the on-device agent offers, and what a tool call becomes.
///
/// Lifted out of `LocalChat` for the reason `ChatSteps` was: this bundle's
/// tests have no host app and compile `ScoreModel` in whole, while `LocalChat`
/// itself pulls in the embedded engine, the Keychain and the network. The
/// table and the argument shaping are PURE -- a tool name, the JSON string of
/// arguments a model wrote, and the slug go in; a bridge op and its arguments
/// come out -- so a stubbed model's tool call can be driven all the way to the
/// bridge boundary with neither a network nor a key.
///
/// The table itself is why it is worth testing. An op can exist in the engine,
/// in the CLI, in `bridge.py` and in `chat.py` and still be unreachable from
/// the iPad, which is how `transpose_diatonic` would have shipped CLI-only
/// after Ali asked for it by name, and how `add-element`, `move-element` and
/// `duplicate-element` stood a build without the on-device agent knowing they
/// existed.
enum ChatTools {

    struct Spec {
        let name: String
        let description: String
        let parameters: [String: Any]
        /// bridge op + arg-name remapping (tool arg -> bridge arg)
        let op: String
        let rename: [String: String]
    }

    private static func str(_ d: String) -> [String: Any] { ["type": "string", "description": d] }
    private static func int(_ d: String) -> [String: Any] { ["type": "integer", "description": d] }
    private static func bool(_ d: String) -> [String: Any] { ["type": "boolean", "description": d] }
    /// A fractional number — a point size or a nudge, which integers cannot say.
    private static func num(_ d: String) -> [String: Any] { ["type": "number", "description": d] }
    /// A list of bar numbers. Pagination takes several at once because a
    /// reader says "start a new line at 17 and 33", and one call that lays the
    /// whole score out beats two that each re-flow it.
    private static func intArr(_ d: String) -> [String: Any] {
        ["type": "array", "items": ["type": "integer"], "description": d]
    }
    private static func strArr(_ d: String) -> [String: Any] {
        ["type": "array", "items": ["type": "string"], "description": d]
    }
    private static func params(_ props: [String: Any], required: [String]) -> [String: Any] {
        ["type": "object", "properties": props, "required": required]
    }

    static let all: [Spec] = [
        Spec(name: "get_score_info",
             description: "Parts, instruments, clefs, ranges, measure counts, key and time signatures of the current score.",
             parameters: params([:], required: []), op: "info", rename: [:]),
        Spec(name: "list_versions",
             description: "The score's version history (op + args per version) and its sources (other editions of the piece).",
             parameters: params([:], required: []), op: "versions", rename: [:]),
        Spec(name: "keep_parts",
             description: "Keep only the named parts; remove all others. Part names match case-insensitively; '#N' targets by index.",
             parameters: params(["parts": strArr("part names to keep")], required: ["parts"]),
             op: "keep-parts", rename: [:]),
        Spec(name: "remove_parts",
             description: "Remove the named parts from the score.",
             parameters: params(["parts": strArr("part names to remove")], required: ["parts"]),
             op: "remove-parts", rename: [:]),
        Spec(name: "transpose",
             description: "CHROMATIC transposition: shift by a fixed interval and CHANGE KEY. Use it when the music should end up in a DIFFERENT key — \"put this in D\", \"a whole step up so I can sing it\", \"transpose for B-flat clarinet\". Every pitch moves by the same interval and the key signature is rewritten to match. Do NOT use it for a harmony line: \"a third above\", \"a sixth below\", \"harmonise it\" mean the notes must stay IN THE CURRENT KEY, which this cannot do — use transpose_diatonic. `interval` is a named interval ('M2', 'm-3', 'P8') or a semitone count ('-3'). Set from_measure/to_measure (inclusive) for a measure range.",
             parameters: params(["interval": str("interval or semitone count"),
                                 "parts": strArr("optional part names; omit for all"),
                                 "from_measure": int("optional first measure of the range (inclusive)"),
                                 "to_measure": int("optional last measure of the range (inclusive)")],
                                required: ["interval"]),
             op: "transpose", rename: [:]),
        Spec(name: "transpose_diatonic",
             description: "DIATONIC transposition: move by SCALE DEGREES and STAY IN THE KEY. This is the tool for a harmony line — \"down a sixth\", \"a third above the melody\", \"harmonise this in thirds\", \"a second violin part below\". The key signature does not change and no accidentals appear that were not there before; some of the sixths come out major and some minor, exactly as the key requires, which is what makes it a harmony rather than a modulation. `degrees` is the number a musician says, signed: -6 is down a sixth, 3 up a third, 8 up an octave; 'down a sixth' works too. A unison is 1 and there is no zeroth. It moves the notes of the parts you name — it does not add a staff, so to write the harmony as a NEW part, pull_part the melody from the current version first and run this on the copy. `key` is only needed when the staff carries no key signature (common in scans): the tool refuses rather than guessing, and says so. Relay any note the result reports as OUTSIDE the key.",
             parameters: params(["degrees": str("signed scale steps: -6 is down a sixth, 3 up a third"),
                                 "parts": strArr("optional part names; omit for all"),
                                 "from_measure": int("optional first measure of the range (inclusive)"),
                                 "to_measure": int("optional last measure of the range (inclusive)"),
                                 "key": str("optional key to count degrees in, e.g. 'G', 'e', 'Bb' — only when the staff has no key signature")],
                                required: ["degrees"]),
             op: "transpose-diatonic", rename: [:]),
        Spec(name: "transpose_diatonic_elements",
             description: "Move ONLY the given elements by scale degrees, staying in the key. Use this — never transpose_diatonic with a measure range — whenever the user refers to a selection and the context lists selected element addresses. Pass them unchanged ('s1/m15/l1/note#3').",
             parameters: params(["degrees": str("signed scale steps: -6 is down a sixth"),
                                 "elements": strArr("element addresses from the selection, unchanged"),
                                 "key": str("optional key, when the staff has no key signature")],
                                required: ["degrees", "elements"]),
             op: "transpose-diatonic-elements", rename: [:]),
        Spec(name: "respell",
             description: "Respell accidentals enharmonically: prefer='flats' turns G# into Ab (right for flat keys like F minor); prefer='sharps' does the reverse. Key signatures untouched. Set from_measure/to_measure (inclusive) to respell only that measure range.",
             parameters: params(["prefer": str("'flats' or 'sharps' (default flats)"),
                                 "parts": strArr("optional part names; omit for all"),
                                 "from_measure": int("optional first measure of the range (inclusive)"),
                                 "to_measure": int("optional last measure of the range (inclusive)")],
                                required: []),
             op: "respell", rename: [:]),
        Spec(name: "change_clef",
             description: "Set a part's clef (treble, bass, alto, tenor, treble8vb, bass8vb) from a given measure.",
             parameters: params(["part": str("part name"), "clef": str("clef name"),
                                 "from_measure": int("first measure (default 1)")],
                                required: ["part", "clef"]),
             op: "change-clef", rename: [:]),
        Spec(name: "change_instrument",
             description: "Reassign a part to another instrument: converts transposition, octave-fits the line to the instrument's range, sets the idiomatic clef, and reports remaining out-of-range notes.",
             parameters: params(["part": str("part name"), "to_instrument": str("target instrument")],
                                required: ["part", "to_instrument"]),
             op: "change-instrument", rename: ["to_instrument": "to"]),
        Spec(name: "rename_part",
             description: "Rename a part (label only, no musical change).",
             parameters: params(["part": str("current part name or '#N'"), "name": str("new name"),
                                 "abbreviation": str("optional staff abbreviation")],
                                required: ["part", "name"]),
             op: "rename-part", rename: [:]),
        Spec(name: "check_range",
             description: "List notes outside an instrument's range (the part's own instrument, or the named one). Read-only.",
             parameters: params(["part": str("part name"),
                                 "instrument": str("optional instrument to check against")],
                                required: ["part"]),
             op: "check-range", rename: [:]),
        Spec(name: "octave_shift",
             description: "Shift a part by whole octaves within an inclusive measure range.",
             parameters: params(["part": str("part name"), "octaves": int("e.g. -1"),
                                 "from_measure": int("first measure"), "to_measure": int("last measure")],
                                required: ["part", "octaves", "from_measure", "to_measure"]),
             op: "octave-shift", rename: [:]),
        Spec(name: "merge_parts",
             description: "Merge several parts losslessly into one staff (each source becomes a voice).",
             parameters: params(["parts": strArr("parts to merge, top voice first"),
                                 "new_name": str("name of the merged part"),
                                 "clef": str("clef for the merged staff (default treble)")],
                                required: ["parts", "new_name"]),
             op: "merge-parts", rename: ["new_name": "name"]),
        Spec(name: "split_bass",
             description: "Split a part into a bass staff (lowest pitch per moment, bass clef) and a chords staff (the rest, treble).",
             parameters: params(["part": str("part to split"), "bass_name": str("name for the bass staff"),
                                 "chords_name": str("name for the chords staff"),
                                 "instrument": str("optional instrument for both staves")],
                                required: ["part", "bass_name", "chords_name"]),
             op: "split-bass", rename: [:]),
        Spec(name: "absorb_part",
             description: "Fold a chordal part into a melodic part as a second voice under the melody. Optional rules override: below_melody(bool), drop_doubling(bool), min_pitch(str), max_span(int).",
             parameters: params(["source": str("part to absorb"), "target": str("melodic part"),
                                 "rules": ["type": "object", "description": "optional rule overrides"]],
                                required: ["source", "target"]),
             op: "absorb-part", rename: [:]),
        Spec(name: "flatten_voices",
             description: "Collapse a multi-voice staff into one voice of chords (piano right-hand style).",
             parameters: params(["part": str("part name")], required: ["part"]),
             op: "flatten-voices", rename: [:]),
        Spec(name: "consolidate_ties",
             description: "Merge runs of tied same-pitch notes into single longer notes (notational cleanup).",
             parameters: params(["parts": strArr("part names")], required: ["parts"]),
             op: "consolidate-ties", rename: [:]),
        Spec(name: "limit_part",
             description: "Enforce playability limits on a part, always dropping higher notes: a pitch ceiling and/or monophony.",
             parameters: params(["part": str("part name"), "max_pitch": str("e.g. 'C4'"),
                                 "monophonic": bool("keep only the lowest note per moment")],
                                required: ["part"]),
             op: "limit-part", rename: [:]),
        Spec(name: "simplify_rhythm",
             description: "Make a passage slower to READ. This is the tool for \"I can't play this fast\", \"reduce the 16th notes down to eighth notes\", \"simplify the rhythm\", \"this run is too quick for me\". Never answer that rhythmic augmentation or quantization is unsupported. DO NOT pick a mode silently — the two are different pieces of music. mode='augment': every value doubles and the meter's denominator halves (4/4 becomes 4/2), so every sixteenth is written as an eighth. NOT ONE NOTE IS LOST and no bar is added or renumbered; the passage lasts twice as long, which is to say it sounds at half speed. Right for a SOLO. It changes how long a bar lasts, so it applies to the whole score — naming one part of a multi-part score is refused. mode='thin': attacks are quantized onto the unit grid and the notes between are DROPPED. The passage keeps its place in the bar and its length, so it still fits everything else playing, but it is no longer the same tune. Right for a part in an ensemble. RELAY notes_removed and removed_by_measure — that is someone's music. A third answer needs no tool at all: play it slower, which is exactly what augmenting writes down; offer it before rewriting anything. If the score has one part, offer augment first — it costs nothing. When unsure which the reader wants, ASK. Set from_measure/to_measure to fix just the passage that defeats them. Read the result's `cost` sentence and pass its substance on.",
             parameters: params(["mode": str("'augment' (double the values, lose nothing, twice as long) or 'thin' (drop notes, keep the place and the length)"),
                                 "part": str("required for thin; for augment, only meaningful on a one-part score"),
                                 "unit": str("the fastest value to read: 'eighth' (default), '16th', 'quarter'"),
                                 "from_measure": int("first measure of the passage"),
                                 "to_measure": int("last measure of the passage")],
                                required: ["mode"]),
             op: "simplify-rhythm", rename: [:]),
        Spec(name: "simplify_repeats",
             description: "Collapse measures that only restate one pitch class (octave jumps/repeats) to a downbeat note + rests.",
             parameters: params(["part": str("part name")], required: ["part"]),
             op: "simplify-repeats", rename: [:]),
        Spec(name: "analyze_harmony",
             description: "Per-measure harmony analysis: ranked chord candidates per bar with the downbeat bass note. Read-only; you adjudicate the final chart (prefer functional readings, name secondary dominants literally).",
             parameters: params(["parts": strArr("optional parts to analyze")], required: []),
             op: "analyze", rename: [:]),
        Spec(name: "set_chords",
             description: "Write chord symbols onto a part: [{\"measure\": 1, \"symbol\": \"Fm\"}, ...]. Qualities: '', m, 7, m7, maj7, m7b5, 6, m6, dim, dim7, aug; roots may carry b/#. MEASURE NUMBERS ARE THE ONES ON THE PAGE: the first full bar is 1 (get_score_info's measure list says what the bars are called; a pickup is not bar 1), so a chart \"from the beginning\" starts at the first bar there is. offset puts a chord INSIDE a bar, in quarter notes from its barline: 0 is the downbeat, 2 the second half of a 4/4 bar, 1.5 the second half of a 6/8 bar -- \"E minor in the second half of bar 8\" is {\"measure\": 8, \"symbol\": \"Em\", \"offset\": 2}. Each chord is ADDED to the part's chart, replacing only a chord already at that exact spot, so a single change is a single entry: never resend the whole chart. A chord is always a chord symbol -- never write one with add_element as a text mark, which engraves lower and in italics and is refused.",
             parameters: params(["part": str("part to carry the symbols"),
                                 "chords": ["type": "array", "description": "list of {measure, symbol, offset}",
                                            "items": ["type": "object",
                                                      "properties": ["measure": ["type": "integer"],
                                                                     "symbol": ["type": "string"],
                                                                     "offset": ["type": "number",
                                                                                "description": "quarter notes from the barline; 0 is the downbeat"]],
                                                      "required": ["measure", "symbol"]]]],
                                required: ["part", "chords"]),
             op: "set-chords", rename: [:]),
        Spec(name: "strip_notes",
             description: "Empty a staff of its notes and keep its chord symbols -- a names-only staff, which is what a chart wants: the changes over the bars with nothing engraved under them. Every bar keeps a whole-bar rest, so the meter is intact and the symbols sit where they sat. Pair it with chart_style, which hides those rests and puts the names on the staff.",
             parameters: params(["part": str("the part to empty")], required: ["part"]),
             op: "strip-notes", rename: [:]),
        Spec(name: "chart_style",
             description: "Real Book styling for a chord-symbol staff: hide rests, put the names on the staff.",
             parameters: params(["part": str("part name")], required: ["part"]),
             op: "chart-style", rename: [:]),
        Spec(name: "pull_part",
             description: "Bring a part (or 'A-B' measure range, requires replace) from a source ('src:s01'), a historical version ('v007'), or a sibling arrangement ('arr:<slug>') into the arrangement.",
             parameters: params(["from_ref": str("'src:sNN', 'vNNN', or 'arr:<slug>' (another arrangement of the same piece — see the numbered list in context)"), "part": str("part in the source"),
                                 "as_name": str("optional name for the added part"),
                                 "replace": str("optional part in the arrangement to replace"),
                                 "measures": str("optional 'A-B' inclusive range")],
                                required: ["from_ref", "part"]),
             op: "pull-part", rename: ["from_ref": "from", "as_name": "as"]),
        Spec(name: "staff_spacing",
             description: "Change how much ROOM the page gives. staff is the minimum space between the staves of one system and system the minimum space between systems, both in MEI units (staff 0-48, default 12; system 0-48, default 4). They are MINIMUMS: they open space up and cannot close space the music itself needs, so asking for tighter spacing below what the notes require changes nothing -- say so rather than trying again. fingering_rows is the band a penny-whistle fingering column takes above its staff, in rows (4-6, default 4): raise it for more air around the diagrams, lower it to fit more lines on a page. reset=true puts all three back. Where the LINES break is paginate's business, not this one's.",
             parameters: params(["staff": int("minimum space between staves"),
                                 "system": int("minimum space between systems"),
                                 "fingering_rows": int("rows for a whistle column, 4-6"),
                                 "reset": bool("put the spacing back to the defaults")],
                                required: []),
             op: "staff-spacing", rename: [:]),
        Spec(name: "paginate",
             description: "Decide where the LINES break on the page. measures_per_line lays the whole score out at that many bars a line (\"four bars to a line\"). end_at is a list of bars that must END a line -- \"end the line at bar 12\", \"make bar 8 the last bar of the first line\" -- and is the usual way a reader says it; the bars after move on to the next line. break_at is a list of bars that must START a line (\"start a new line at bar 17\"). remove_at takes a line break off again. clear=true removes every break and hands the layout back to the engraver, which is what \"repaginate this automatically\" or \"put it back how it was\" means. Lines the reader forced are remembered, and every other line is laid out again around them each time: the lines before a forced ending are evened out, a pickup rides in front of the first line, and no line is left holding one bar alone. If the score has no line length yet and none is given, one is CHOSEN from how busy the bars are (preferring 4 or 8, so phrases line up) and the result says measures_per_line_chosen -- tell the reader what was chosen. This changes only where the music is DRAWN; it moves no note and changes no bar number.",
             parameters: params(["measures_per_line": int("how many bars to a line"),
                                 "end_at": intArr("bar numbers that must end a line"),
                                 "break_at": intArr("bar numbers that must start a line"),
                                 "remove_at": intArr("bar numbers whose line break to remove"),
                                 "clear": bool("remove every break and lay it out automatically")],
                                required: []),
             op: "paginate", rename: [:]),
        Spec(name: "measure_numbers",
             description: "Decide which bars carry a MEASURE NUMBER on the page. every=1 numbers every bar (\"add measure numbers\", \"number every measure\"); every=N numbers the bars whose number divides by N (\"every third measure\" is every=3, \"every 4 bars\" every=4); system=true numbers the first bar of each line, which is the engraver's default; none=true takes every number off. Send exactly one of them. reset=true is the same as system. The numbering is stored in the score, so it versions, exports to PDF and travels with a share. It changes only what is drawn: no bar is renumbered. Where a number sits and how big it is are not adjustable.",
             parameters: params(["every": int("number every Nth bar; 1 is every bar"),
                                 "system": bool("number the first bar of each line (the default)"),
                                 "none": bool("no measure numbers at all"),
                                 "reset": bool("back to the default")],
                                required: []),
             op: "measure-numbers", rename: [:]),
        Spec(name: "set_structure",
             description: "Add, remove or move a repeat sign, a volta (1st/2nd ending) or a navigation mark. Kinds: repeat-start, repeat-end, repeat-both, volta, segno, coda, fine, da-capo, da-capo-al-fine, da-capo-al-coda, dal-segno, dal-segno-al-fine, dal-segno-al-coda. A volta needs measure, to_measure and number; repeat-end can take times. remove=true takes one off; move_to shifts it.",
             parameters: params(["kind": str("which mark"),
                                 "measure": int("the measure it goes on"),
                                 "to_measure": int("last measure of a volta"),
                                 "number": int("volta number"),
                                 "times": int("play count on a repeat-end"),
                                 "move_to": int("move the mark to this measure"),
                                 "remove": bool("remove it instead of adding")],
                                required: ["kind"]),
             op: "set-structure", rename: [:]),
        Spec(name: "add_element",
             description: "Put a mark on the page: a dynamic, a text mark, a fermata, an articulation or a word. value is the dynamic (\"mf\"), the words (\"dolce\"), the articulation (accent, staccato, tenuto, marcato...), the fermata's shape (normal, angled, square) or the syllable to sing (\"la\"). THE DESTINATION IS A BAR PLUS AN OFFSET INSIDE IT, in quarter notes from the barline: 0 is the downbeat, 1.5 the second half of beat two in 4/4. A dynamic or a text mark is inserted at that offset; a fermata, an articulation or a lyric is attached to the note that STARTS there, and if nothing does the op refuses and lists the bar's real onsets -- read them and pick one rather than sending the same offset again. Hairpins and slurs are refused: a spanner has two anchors. So are chord symbols (set_chords), diagrams (guitar_chord_diagrams) and tab (guitar_tablature), each of which has its own op. A lyric lands in the lowest verse its note has free and takes no placement: verses are drawn below the staff, so \"above\" is refused rather than written down and ignored. The result says which ORDINAL the mark landed at, which is how adjust_element and move_element address it.",
             parameters: params(["part": str("the part the mark goes on"),
                                 "kind": str("dynamic, text, fermata, articulation or lyric"),
                                 "measure": int("the bar it goes in"),
                                 "value": str("the dynamic, the words, the articulation, the fermata's shape, or the syllable"),
                                 "offset": num("quarter notes from the barline; 0 is the downbeat"),
                                 "placement": str("above or below the staff")],
                                required: ["part", "kind", "measure"]),
             op: "add-element", rename: [:]),
        Spec(name: "adjust_element",
             description: "Change how big an added element is, or where it sits. kind is harm (a chord symbol), diagram (a guitar chord diagram), tab (a tablature column), lyric (a word under a note -- \"make the words bigger\"), or one of the four marks add_element writes: dynamic, text, fermata, articulation. A LYRIC TAKES A SIZE AND NOTHING ELSE: an offset on one is refused by name, because a word is drawn under the note it belongs to and nothing here honours a nudge on it. A word that belongs somewhere else belongs under another NOTE -- that is move_element. SIZE IS RELATIVE: scale is the interface -- 1.0 is the engraved default, 1.5 is half again, 0.75 three quarters -- and \"make it bigger\" is a scale. size is the absolute point value (12 engraves as the default) and is for a caller that already holds one, such as the app's chord-symbol row; pass a scale or a size, never both, because the op refuses both at once. offset_x and offset_y nudge it sideways and up in MusicXML tenths, positive y being up. Address one with measure (plus ordinal when a bar has several), or set all=true for every element of that kind in the part. reset=true puts them back.",
             parameters: params(["part": str("the part the element is on"),
                                 "measure": int("the bar it is in"),
                                 "kind": str("harm, diagram, tab, lyric, dynamic, text, fermata or articulation"),
                                 "ordinal": int("which one, when a bar has several"),
                                 "scale": num("size as a multiple of the engraved default: 1.5 is half again"),
                                 "size": num("absolute point size, when you already hold one"),
                                 "offset_x": num("sideways nudge, in tenths"),
                                 "offset_y": num("upward nudge, in tenths"),
                                 "all": bool("every element of that kind in the part"),
                                 "reset": bool("put it back where it was")],
                                required: ["part"]),
             op: "adjust-element", rename: [:]),
        Spec(name: "move_element",
             description: "Move an added element to another bar. Address the one you mean with measure, plus ordinal when the bar holds several of that kind (counting from 0). The destination is to_measure plus to_offset quarter notes from its barline -- the same destination add_element takes, because this app has no drag. A chord symbol, diagram, dynamic or text mark lands at that offset; a fermata, an articulation or a lyric attaches to the note that STARTS there, and the op refuses and lists the onsets rather than guessing. Re-attaching is the only way a word moves, and it keeps its verse: if the destination note already sings that verse the op names the word in the way instead of stacking two on one notehead. Spanners are refused by name: a spanner has two anchors and a destination names one. A move never touches pitch or rhythm.",
             parameters: params(["part": str("the part the element is on"),
                                 "kind": str("harm, diagram, dynamic, text, fermata, articulation, ornament or lyric"),
                                 "measure": int("the bar it is in now"),
                                 "ordinal": int("which one, when a bar has several"),
                                 "to_measure": int("the bar to move it to"),
                                 "to_offset": num("quarter notes from that barline; 0 is the downbeat")],
                                required: ["part", "kind", "measure", "to_measure"]),
             op: "move-element", rename: [:]),
        Spec(name: "duplicate_element",
             description: "Copy an added element into another bar, leaving the original where it is -- \"put that same accent on bar 9 too\". Addressed and placed exactly as move_element is.",
             parameters: params(["part": str("the part the element is on"),
                                 "kind": str("harm, diagram, dynamic, text, fermata, articulation, ornament or lyric"),
                                 "measure": int("the bar the original is in"),
                                 "ordinal": int("which one, when a bar has several"),
                                 "to_measure": int("the bar to copy it into"),
                                 "to_offset": num("quarter notes from that barline; 0 is the downbeat")],
                                required: ["part", "kind", "measure", "to_measure"]),
             op: "duplicate-element", rename: [:]),
        Spec(name: "remove_element",
             description: "Take an added mark off the page -- \"take the ornament off bar 12\", \"lose that fermata\", \"clear the dynamics from this part\". Addressed as every other element verb is: a bar plus an ordinal in its document order, or all=true for every one of that kind in the part. A word can be removed too -- \"drop that lyric\" takes the verse off the note it is sung on, and takes the sung words only: a whistle's fingerings and a guitar tab's frets are verses as well, and all=true leaves both alone. A tab column is refused by name; guitar_tablature's clear is what takes one of those off.",
             parameters: params(["part": str("the part the mark is on"),
                                 "kind": str("harm, diagram, dynamic, text, fermata, articulation, ornament or lyric"),
                                 "measure": int("the bar it is in"),
                                 "ordinal": int("which one, when a bar has several"),
                                 "all": bool("every mark of that kind in the part")],
                                required: ["part", "kind"]),
             op: "remove-element", rename: [:]),
        Spec(name: "guitar_tablature",
             description: "Write guitar tablature under a part: a fret number per note on a six-line tab staff, at the lowest position that plays it. Notes the tuning cannot play are reported, and so is any bar where a chord forced the hand higher up the neck. Set clear=true to remove it. Size and position are adjust_element's business, with kind=\"tab\".",
             parameters: params(["part": str("the part to write tab under"),
                                 "tuning": str("EADGBE (standard), DADGAD, or DADGBE (drop D)"),
                                 "capo": num("the fret the capo sits on"),
                                 "clear": bool("remove the tab instead")],
                                required: ["part"]),
             op: "guitar-tab", rename: [:]),
        Spec(name: "guitar_chord_diagrams",
             description: "Draw a guitar chord diagram above every chord symbol already on a part: the grid, the finger dots, a barre as one bar, the nut at first position and a \"5 fr.\" label above it. Chords with no playable shape are reported, not faked. Set clear=true to remove them. Size and position are adjust_element's business, with kind=\"diagram\".",
             parameters: params(["part": str("the part whose chord symbols get diagrams"),
                                 "tuning": str("EADGBE (standard), DADGAD, or DADGBE (drop D)"),
                                 "clear": bool("remove the diagrams instead")],
                                required: ["part"]),
             op: "chord-diagrams", rename: [:]),
        Spec(name: "penny_whistle_fingerings",
             description: "Write penny-whistle fingerings under every note of a part, engraved in the notation as stacked hole diagrams (X covered, O open, / half-hole, + overblown octave). A whistle's range is two octaves and the tonic again at the top (a D whistle: D4 to D6), and EVERY note in it gets a diagram whatever its accidental is spelled as. Notes above or below that range get none and are listed in the result as out of range, with their bar numbers — relay those to the user rather than re-running, because running it again will not change them. Set clear=true to remove them.",
             parameters: params(["part": str("the part to fingerings"),
                                 "whistle": str("the whistle's key, D by default"),
                                 "clear": bool("remove the fingerings instead")],
                                required: ["part"]),
             op: "whistle-fingerings", rename: [:]),
        Spec(name: "set_metadata",
             description: "Set the arrangement's title (the title engraved at the top of the page AND its name in the library — they are one value), its composer or its arranger. An empty string clears a credit.",
             parameters: params(["title": str("the arrangement's title"),
                                 "composer": str("composer credit"),
                                 "arranger": str("arranger credit")],
                                required: []),
             op: "set-metadata", rename: [:]),
        Spec(name: "assign_to_piece",
             description: "File this arrangement under a piece, creating it if needed.",
             parameters: params(["piece_name": str("name of the piece to file under")],
                                required: ["piece_name"]),
             op: "assign-piece", rename: ["piece_name": "piece"]),
    ]

    /// The tool list as the model receives it.
    static var json: [[String: Any]] {
        all.map { t in
            ["type": "function",
             "function": ["name": t.name, "description": t.description,
                          "parameters": t.parameters]]
        }
    }

    /// One tool call, shaped for the bridge.
    ///
    /// Three things happen here and nowhere else: the name is looked up (an
    /// invented one is `nil`, never a guess), the model's argument names are
    /// remapped to the bridge's, and the SCORE is added -- the model is never
    /// told which arrangement it is working on, so it cannot name the wrong
    /// one.
    struct Call {
        let op: String
        let args: [String: Any]
    }

    static func call(named name: String, argsJSON: String, slug: String) -> Call? {
        guard let spec = all.first(where: { $0.name == name }) else { return nil }
        var args: [String: Any] =
            (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8)) as? [String: Any]) ?? [:]
        for (from, to) in spec.rename {
            if let v = args.removeValue(forKey: from) { args[to] = v }
        }
        args["score"] = slug
        return Call(op: spec.op, args: args)
    }

    /// The tool calls in one assistant message, as OpenAI-style providers
    /// write them: an id, a function name, and the arguments as a STRING of
    /// JSON rather than an object.
    static func toolCalls(in assistant: [String: Any]) -> [(id: String, name: String, argsJSON: String)] {
        (assistant["tool_calls"] as? [[String: Any]] ?? []).map { call in
            let fn = call["function"] as? [String: Any]
            return (id: call["id"] as? String ?? UUID().uuidString,
                    name: fn?["name"] as? String ?? "",
                    argsJSON: fn?["arguments"] as? String ?? "{}")
        }
    }
}
