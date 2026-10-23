import CoreGraphics
import Foundation

/// Turns engraved whistle fingerings into drawn diagrams.
///
/// The fingerings are written into the notation as lyric verses, which is what
/// gets them positioned: Verovio reserves the space under the staff, stacks the
/// six holes in order and centres each column on its notehead. What Verovio
/// cannot do is draw a filled circle — it draws text, and the glyphs for ● and
/// ○ are missing from the fonts the PDF rasterizers fall back to, so they came
/// out as empty boxes. Hence letters in the notation and circles on the page:
/// this replaces each tagged verse glyph with an SVG shape at the coordinates
/// Verovio already chose.
///
/// Two kinds of verse are converted. Ones the engine tagged (`<title>wf</title>`,
/// from `<lyric name="wf">`), and ones that are unmistakably a fingering column
/// even without the tag: five or six verses on the same note, every one of them
/// a single X, O or /. The second rule exists because fingerings written before
/// the tag existed are sitting in people's scores, and a renderer that only
/// understood its own new output would leave those as letters forever.
///
/// A song whose lyric happens to be the word "O" is safe either way: one verse
/// is not a column.
enum FingeringDiagrams {
    /// The engine's marker, mirrored from ops.WHISTLE_LYRIC_TAG.
    static let tag = "wf"

    static let covered = "X"
    static let open = "O"
    static let half = "/"
    /// The overblown-octave mark. It stays text — it is a "+", which every font
    /// has — but it belongs to the column, so a run containing it is still a
    /// fingering. Requiring every verse to be a hole rejected the whole second
    /// octave.
    static let octave = "+"

    // Proportions of the verse's own font size, so the diagram scales with the
    // engraving at any page size.
    private static let centreX: CGFloat = 0.36     // half a glyph advance
    private static let centreY: CGFloat = -0.35    // above the text baseline
    private static let radius: CGFloat = 0.28
    private static let strokeWidth: CGFloat = 0.07

    /// The engraving's one text size, in MEI units. It stays at Verovio's
    /// default because `lyricSize` also sizes `<harm>` chord symbols: shrinking
    /// it to shrink the diagrams halved every chord name on a fingered score.
    static let defaultLyricSize = 4.5
    /// How much smaller the drawn diagram is than the glyph it replaces -- the
    /// same 2.2-in-4.5 the diagrams shipped at, applied here instead.
    static let diagramScale: CGFloat = 2.2 / 4.5

    // --- how big the diagram is, and how tightly it is stacked --------------
    //
    // Circle size and row spacing are set SEPARATELY: the column had to lose
    // about half its footprint while each hole got slightly BIGGER. Both used
    // to come from the verse's font size, so neither could move alone.
    //
    // Everything is measured against the row pitch Verovio itself laid out --
    // the one number on the page that already scales with the staff. Taken off
    // a real engraving at the default size: pitch 400 SVG units, notehead 217
    // wide, drawn circle 111 across.
    //
    // Mirrors engine/scoranger_engine/render.py; keep the two in step, and
    // engine/scripts/check_render.py measures the result.
    static let noteheadPerRowPitch: CGFloat = 217.0 / 400.0
    /// A hole is a little smaller than a notehead -- readable at speed, still
    /// clearly not a note.
    static let holeDiameterVsNotehead: CGFloat = 0.78
    /// Rows at 47.5% of Verovio's pitch: a six-hole column becomes 950 units
    /// where it was 2000.
    static let holePitchRatio: CGFloat = 0.475
    /// The octave "+" stays text but is sized from the circle beside it.
    static let octaveMarkVsDiameter: CGFloat = 0.85

    // centre offsets relative to the RADIUS, so they hold at any circle size
    static let centreXVsRadius = centreX / radius
    static let centreYVsRadius = -centreY / radius
    private static let strokeVsRadius = strokeWidth / radius

    /// (row pitch, circle radius) for a column, from Verovio's own pitch.
    static func holeGeometry(rowPitch: CGFloat) -> (pitch: CGFloat, radius: CGFloat) {
        let notehead = rowPitch * noteheadPerRowPitch
        return (rowPitch * holePitchRatio, notehead * holeDiameterVsNotehead / 2)
    }

    /// The spacing between holes, as the MEDIAN gap.
    ///
    /// Not the average across the column: the octave "+" hangs further below
    /// than the holes are apart, so averaging the whole span stretched the
    /// pitch, and with it the circles.
    static func rowPitch(of ys: [CGFloat]) -> CGFloat {
        let gaps = zip(ys, ys.dropFirst()).map { $1 - $0 }.filter { $0 > 0 }.sorted()
        guard !gaps.isEmpty else { return 0 }
        let middle = gaps.count / 2
        return gaps.count % 2 == 1 ? gaps[middle] : (gaps[middle - 1] + gaps[middle]) / 2
    }

    /// Smallest run of same-note verses that reads as a fingering rather than
    /// as words. Six holes is a full diagram; five allows for an engraver
    /// dropping an empty verse.
    static let columnThreshold = 5

    /// One verse, parsed far enough to decide what it is.
    private struct Verse {
        let range: NSRange
        let block: String
        let tagged: Bool
        let symbol: String?
        /// Whatever the verse actually says, hole or not.
        let text: String?
        /// The verse's own number, which restarts at 1 on each note. Grouping
        /// on this rather than on x: Verovio centres each syllable on its own
        /// width, so an "X" verse and an "O" verse of the SAME note sit at
        /// different x, and a column of mixed holes never grouped.
        let number: Int?
    }

    /// Mark fingering verses `place="above"` in MEI, or nil when there are none.
    ///
    /// Verovio ignores MusicXML's `<lyric placement="above">`, but honours MEI's
    /// `place` on `<verse>` — so the move happens on an MEI round trip rather
    /// than in the notation. The same column rule as the SVG pass decides what
    /// counts, which is what carries fingerings written before the tag existed.
    ///
    /// `rows` is the score's own setting (`StaffSpacing`): how many lyric lines
    /// Verovio reserves for a column's holes. Each column is packed down to
    /// that many verses with the whole pattern in the first one's label -- see
    /// `packColumn` -- and `unpackColumns` puts the rows back before anything
    /// is drawn. Six is the layout every build before 0.13.0 drew.
    static func meiWithFingeringsAbove(_ mei: String,
                                       rows: Int = StaffSpacing.defaultRows) -> String? {
        guard mei.contains("<verse") else { return nil }
        // chord first: a fingered note inside a chord hangs its verses off the
        // chord, and matching the inner <note> separately would miss them
        guard let noteRE = RegexCache.regex(
                pattern: "<(chord|note)\\b[^>]*>.*?</\\1>",
                options: [.dotMatchesLineSeparators]),
              let verseRE = RegexCache.regex(
                pattern: "<verse\\b[^>]*>.*?</verse>",
                options: [.dotMatchesLineSeparators])
        else { return nil }

        let ns = mei as NSString
        var out = ""
        var cursor = 0
        var changed = false
        for match in noteRE.matches(in: mei, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor,
                                              length: match.range.location - cursor))
            let block = ns.substring(with: match.range)
            let blockNS = block as NSString
            let verses = verseRE.matches(
                in: block, range: NSRange(location: 0, length: blockNS.length))
                .map { blockNS.substring(with: $0.range) }
            // The column is the `wf` verses and only them: a SUNG note carries
            // its words as further verses (0.21.0), which stay below. A column
            // is tagged verses that READ as holes; an untagged column, from
            // before the tag, is the whole note or nothing. Mirrors
            // render.mei_with_fingerings_above.
            var column = verses.filter { $0.contains("label=\"\(tag)") }
            if !isFingeringColumn(column) {
                column = isFingeringColumn(verses) ? verses : []
            }
            if !column.isEmpty {
                changed = true
                // Only a verse without a placement gains one -- the same guard
                // render.py applies -- so a placed verse is not given two.
                let above = column.map { verse -> String in
                    let open = verse.components(separatedBy: ">").first ?? verse
                    return open.contains("place=") ? verse
                        : verse.replacingOccurrences(of: "<verse", with: "<verse place=\"above\"",
                                                     options: [], range: verse.range(of: "<verse"))
                }
                let packed = packColumn(above, rows: rows) ?? above
                // the column's verses out, the column back in where its first was
                var stripped = block
                let first = (block as NSString).range(of: column[0]).location
                for verse in column {
                    if let r = stripped.range(of: verse) { stripped.removeSubrange(r) }
                }
                let head = (stripped as NSString).substring(to: first)
                let tail = (stripped as NSString).substring(from: first)
                out += head + packed.joined() + tail
            } else {
                out += block
            }
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return changed ? wordsUnderLiftedColumns(out) : nil
    }

    /// Where a whistle part's WORDS are numbered from: above the column's
    /// seven verses (`ops.WHISTLE_VERSES`). Mirrors
    /// render.WORD_VERSES_AFTER_COLUMN.
    static let wordVersesAfterColumn = 7

    /// On every staff that has a lifted column, number its words from 1 again.
    ///
    /// The engine numbers a whistle part's words above the column so a word
    /// and a hole are never one verse; once the column is above the staff,
    /// those numbers would leave seven empty lines between the staff and the
    /// words. By STAFF across every measure, not by note, so a note out of the
    /// whistle's range lines up with its neighbours. Mirrors
    /// render._words_under_lifted_columns.
    static func wordsUnderLiftedColumns(_ mei: String) -> String {
        guard let staffRE = RegexCache.regex(
                pattern: "<staff\\b[^>]*>.*?</staff>", options: [.dotMatchesLineSeparators]),
              let numberRE = RegexCache.regex(pattern: "^<staff\\b[^>]*?\\bn=\"(\\d+)\""),
              let verseRE = RegexCache.regex(
                pattern: "<verse\\b[^>]*>.*?</verse>", options: [.dotMatchesLineSeparators]),
              let verseNRE = RegexCache.regex(pattern: "(<verse\\b[^>]*?\\bn=\")(\\d+)\"")
        else { return mei }
        let ns = mei as NSString
        let staves = staffRE.matches(in: mei, range: NSRange(location: 0, length: ns.length))
        func number(_ block: String) -> String? {
            let b = block as NSString
            guard let m = numberRE.firstMatch(in: block, range: NSRange(location: 0, length: b.length))
            else { return nil }
            return b.substring(with: m.range(at: 1))
        }
        var lifted = Set<String>()
        for staff in staves {
            let block = ns.substring(with: staff.range)
            if block.contains("label=\"\(tag)"), block.contains("place=\"above\""),
               let n = number(block) {
                lifted.insert(n)
            }
        }
        guard !lifted.isEmpty else { return mei }
        var out = ""
        var cursor = 0
        for staff in staves {
            out += ns.substring(with: NSRange(location: cursor, length: staff.range.location - cursor))
            let block = ns.substring(with: staff.range)
            cursor = staff.range.location + staff.range.length
            guard let n = number(block), lifted.contains(n) else { out += block; continue }
            let b = block as NSString
            var rebuilt = ""
            var at = 0
            for verse in verseRE.matches(in: block, range: NSRange(location: 0, length: b.length)) {
                rebuilt += b.substring(with: NSRange(location: at, length: verse.range.location - at))
                let text = b.substring(with: verse.range)
                at = verse.range.location + verse.range.length
                let t = text as NSString
                guard !text.contains("label=\"\(tag)"),
                      let m = verseNRE.firstMatch(in: text, range: NSRange(location: 0, length: t.length)),
                      let value = Int(t.substring(with: m.range(at: 2))),
                      value > wordVersesAfterColumn else { rebuilt += text; continue }
                rebuilt += t.replacingCharacters(
                    in: m.range,
                    with: t.substring(with: m.range(at: 1)) + "\(value - wordVersesAfterColumn)\"")
            }
            rebuilt += b.substring(from: at)
            out += rebuilt
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// The label a PACKED column carries on its first verse: the tag, a bar,
    /// and every row in order ("wf|XXOOOO+"). Its other verses carry the tag
    /// and the bar alone. Mirrors render.PACKED_PREFIX.
    static let packedPrefix = tag + "|"

    /// The same column, reserving `rows` lyric lines for its holes.
    ///
    /// Verovio gives every verse a full lyric line, and that is the space a
    /// whistle tune loses: six lines reserved for holes the draw pass packs
    /// into half the height. Keeping only `rows` verses shrinks what Verovio
    /// reserves; the pattern rides in the first verse's label so nothing is
    /// lost. The octave "+" keeps a line of its own below the holes on the
    /// notes that carry one, exactly as six-or-seven always has, which keeps
    /// every column's LAST HOLE on one baseline across a system.
    ///
    /// nil when there is nothing to save. Mirrors render._pack_column.
    static func packColumn(_ verses: [String], rows: Int) -> [String]? {
        let texts = verses.map { verse -> String in
            (value(of: "(?<=<syl[^<>]{0,200}>)[^<]*(?=</syl>)", in: verse)
                ?? value(of: "(?<=<syl>)[^<]*(?=</syl>)", in: verse) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let holes = texts.filter { [covered, open, half].contains($0) }
        let hasOctave = texts.last == octave
        guard holes.count == texts.count - (hasOctave ? 1 : 0),
              holes.count > rows else { return nil }
        let keep = rows + (hasOctave ? 1 : 0)
        let pattern = texts.joined()
        return verses.prefix(keep).enumerated().map { index, verse in
            var v = replacingFirst("\\bn=\"\\d+\"", in: verse, with: "n=\"\(index + 1)\"")
            let label = "label=\"\(packedPrefix)\(index == 0 ? pattern : "")\""
            if v.range(of: "\\blabel=\"[^\"]*\"", options: .regularExpression) != nil {
                v = replacingFirst("\\blabel=\"[^\"]*\"", in: v, with: label)
            } else if let r = v.range(of: "<verse") {
                v.replaceSubrange(r, with: "<verse \(label)")
            }
            let text = (hasOctave && index == keep - 1) ? octave : holes[index]
            return replacingFirst("(<syl\\b[^>]*>)[^<]*(</syl>)", in: v, with: "$1\(text)$2")
        }
    }

    /// Put a packed column's rows back, so the draw pass sees today's column.
    ///
    /// Each packed column becomes one verse block per row again: the hole
    /// letter, the plain tag, and the y that row would have had at Verovio's
    /// own pitch, counted up from the LAST HOLE -- the line the draw pass
    /// anchors on. Everything the placement below was tuned against in Ali's
    /// photographs is then untouched; it re-places every row from the anchor
    /// at its own tighter pitch, which is how the column fits the smaller band.
    /// Mirrors render._unpack_fingering_columns.
    static func unpackColumns(in svg: String) -> String {
        guard svg.contains(packedPrefix),
              let verseRE = RegexCache.regex(
                pattern: "<g[^>]*class=\"verse\">.*?</g>\\s*</g>",
                options: [.dotMatchesLineSeparators]),
              let titleRE = RegexCache.regex(
                pattern: "<title class=\"labelAttr\">" +
                    NSRegularExpression.escapedPattern(for: packedPrefix) + "([^<]*)</title>")
        else { return svg }
        let ns = svg as NSString
        let blocks = verseRE.matches(in: svg, range: NSRange(location: 0, length: ns.length))
        func title(_ block: String) -> (whole: String, pattern: String)? {
            let b = block as NSString
            guard let m = titleRE.firstMatch(in: block, range: NSRange(location: 0, length: b.length))
            else { return nil }
            return (b.substring(with: m.range), b.substring(with: m.range(at: 1)))
        }
        var edits: [(range: NSRange, text: String)] = []
        var i = 0
        while i < blocks.count {
            let headBlock = ns.substring(with: blocks[i].range)
            guard let head = title(headBlock), !head.pattern.isEmpty else { i += 1; continue }
            var column = [blocks[i]]
            var j = i + 1
            while j < blocks.count, let pad = title(ns.substring(with: blocks[j].range)),
                  pad.pattern.isEmpty {
                column.append(blocks[j]); j += 1
            }
            i = j
            let ys = column.compactMap { number(of: "<text\\b[^>]*\\by=\"(-?[\\d.]+)\"",
                                                in: ns.substring(with: $0.range)) }
            guard ys.count == column.count, ys.count >= 2 else { continue }
            let gaps = zip(ys, ys.dropFirst()).map { $1 - $0 }.filter { $0 > 0 }.sorted()
            guard !gaps.isEmpty else { continue }
            let pitch = gaps[gaps.count / 2]
            let pattern = Array(head.pattern).map(String.init)
            let hasOctave = pattern.last == octave
            let holeCount = pattern.count - (hasOctave ? 1 : 0)
            let anchor = ys[column.count - (hasOctave ? 2 : 1)]
            var rows = ""
            for (index, glyph) in pattern.enumerated() {
                let y = glyph == octave ? anchor + pitch
                    : anchor - CGFloat(holeCount - 1 - index) * pitch
                var row = headBlock.replacingOccurrences(
                    of: head.whole, with: "<title class=\"labelAttr\">\(tag)</title>")
                row = replacingFirst("(<tspan font-size=\"[\\d.]+px\">)[^<]*(</tspan>)",
                                     in: row, with: "$1\(glyph)$2")
                row = replacingFirst("(<text\\b[^>]*\\by=\")-?[\\d.]+(\")",
                                     in: row, with: "$1\(svgNumber(y))$2")
                // ids stay unique: the rows are copies of one block
                row = (RegexCache.regex(pattern: "\\bid=\"([^\"]+)\""))
                    .map { $0.stringByReplacingMatches(
                        in: row, range: NSRange(row.startIndex..., in: row),
                        withTemplate: "id=\"$1-r\(index)\"") } ?? row
                rows += row
            }
            edits.append((column[0].range, rows))
            for block in column.dropFirst() { edits.append((block.range, "")) }
        }
        // One pass from the front. The edits are distinct matches of one
        // regex, so they never overlap, and splicing them in order is the
        // same text as replacing them one by one from the back -- which copied
        // the whole page once per edit, 157 ms of a dense score's raster.
        let out = NSMutableString(capacity: ns.length)
        var cursor = 0
        for edit in edits.sorted(by: { $0.range.location < $1.range.location }) {
            out.append(ns.substring(with: NSRange(location: cursor,
                                                  length: edit.range.location - cursor)))
            out.append(edit.text)
            cursor = edit.range.location + edit.range.length
        }
        out.append(ns.substring(from: cursor))
        return out as String
    }

    /// A coordinate as SVG text, losslessly: whole numbers bare, the rest to
    /// four places. Mirrors render._svg_number.
    static func svgNumber(_ value: CGFloat) -> String {
        if value == value.rounded() { return String(Int(value)) }
        var text = String(format: "%.4f", Double(value))
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// The first match of `pattern` replaced by `template` ($1-style groups).
    private static func replacingFirst(_ pattern: String, in text: String,
                                       with template: String) -> String {
        guard let re = RegexCache.regex(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(m.range, in: text) else { return text }
        let replacement = re.replacementString(for: m, in: text, offset: 0, template: template)
        var out = text
        out.replaceSubrange(range, with: replacement)
        return out
    }

    /// Five or six single holes on one note, with the octave "+" allowed.
    private static func isFingeringColumn(_ verses: [String]) -> Bool {
        var holes = 0
        for verse in verses {
            guard let syl = value(of: "(?<=<syl[^<>]{0,200}>)[^<]*(?=</syl>)", in: verse)
                    ?? value(of: "(?<=<syl>)[^<]*(?=</syl>)", in: verse) else { return false }
            let text = syl.trimmingCharacters(in: .whitespacesAndNewlines)
            if [covered, open, half].contains(text) { holes += 1 }
            else if text != octave { return false }
        }
        return holes >= columnThreshold
    }

    /// Rewrite every fingering verse in a Verovio SVG page.
    static func draw(in input: String) -> String {
        // a packed column (see packColumn) back into one block per row FIRST,
        // so everything below sees the column it was written for
        let svg = unpackColumns(in: input)
        guard svg.contains("class=\"verse\"") else { return svg }
        guard let verseRE = RegexCache.regex(
                pattern: "<g[^>]*class=\"verse\">.*?</g>\\s*</g>",
                options: [.dotMatchesLineSeparators]) else { return svg }

        let ns = svg as NSString
        let verses = verseRE.matches(in: svg, range: NSRange(location: 0, length: ns.length))
            .map { match -> Verse in
                let block = ns.substring(with: match.range)
                let label = value(of: "(?<=<title class=\"labelAttr\">)[^<]*(?=</title>)",
                                  in: block)
                return Verse(range: match.range,
                             block: block,
                             tagged: label == tag,
                             symbol: fingeringSymbol(in: block),
                             text: value(of: "(?<=>)[^<>]{1,3}(?=</tspan>)", in: block),
                             number: label.flatMap { Int($0) })
            }
        guard !verses.isEmpty else { return svg }

        let convertible = columns(in: verses)
        guard convertible.contains(true) else { return svg }

        // Where each row is REDRAWN. The spacing is not asked of Verovio --
        // its lyric line height also sizes chord symbols, and shrinking that
        // once halved every chord name on the page -- so the rows are simply
        // re-placed here, anchored at the BOTTOM row, the one nearest the
        // staff.
        //
        // It anchored at the top once, and that is what put the big gap in
        // Ali's screenshot: our pitch is about half the one Verovio laid out,
        // so holding the top fixed pulled every row below it upward and the
        // lowest hole floated half a column above the staff it belongs to.
        // Holding the bottom fixed keeps the diagrams against their staff and
        // takes the reclaimed space off the top, which is the safe direction --
        // the column only ever gets shorter, so it cannot reach the system
        // above.
        let allYs = verses.compactMap { verseY($0.block) }
        let typicalPitch = rowPitch(of: allYs.enumerated()
            .filter { $0.offset == 0 || allYs[$0.offset] > allYs[$0.offset - 1] }
            .map(\.element))
        let xTolerance = max(typicalPitch * 0.25, 2.0)

        var placement: [Int: CGFloat] = [:]
        var radii: [Int: CGFloat] = [:]
        // The column's one horizontal AXIS. Verovio centres each verse on its
        // own glyph width, so the rows of one note do not share an x: an "X"
        // row and an "O" row can be ten units apart, and the octave "+" -- a
        // different glyph again -- lands as much as a third of a hole off.
        // Drawn from its own x each row sits on a slightly different axis and
        // the "+" hangs beside the circles rather than under them. A column is
        // one column: it gets ONE x, taken from its holes, since the "+" is the
        // odd glyph and does not get a vote.
        var anchors: [Int: CGFloat] = [:]
        var column: [Int] = []

        func settle() {
            let ys = column.compactMap { verseY(verses[$0].block) }
            guard ys.count == column.count, ys.count >= 2 else { return }
            let pitch = rowPitch(of: ys)
            guard pitch > 0 else { return }
            let geometry = holeGeometry(rowPitch: pitch)
            // The last HOLE, not the last row: a column's last row is the
            // octave "+" when it has one, and anchoring there hung every
            // fingered-octave note a whole lyric pitch below its neighbours.
            // Every verse of a system shares a baseline, so anchoring every
            // column on the same row of itself puts the circle stacks on one
            // line whatever each carries underneath.
            let holeRows = column.enumerated()
                .filter { convertible[$0.element] }
                .map(\.offset)
            let anchor = holeRows.last ?? (column.count - 1)
            let bottom = ys[anchor]
            for (row, index) in column.enumerated() {
                placement[index] = bottom - CGFloat(anchor - row) * geometry.pitch
                radii[index] = geometry.radius
            }
            let holeXs = column
                .filter { convertible[$0] }
                .compactMap { verseX(verses[$0].block) }
                .sorted()
            if !holeXs.isEmpty {
                let axis = holeXs[holeXs.count / 2]
                for index in column { anchors[index] = axis }
            }
        }

        for (index, verse) in verses.enumerated() {
            let isColumnRow = convertible[index] || (verse.tagged && verse.text == octave)
            guard isColumnRow, let y = verseY(verse.block) else {
                settle(); column = []; continue
            }
            _ = y
            if let last = column.last,
               !sameColumn(verses[last].block, verse.block, tolerance: xTolerance) {
                settle(); column = []
            }
            column.append(index)
        }
        settle()

        var out = ""
        var cursor = 0
        for (index, verse) in verses.enumerated() {
            out += ns.substring(with: NSRange(location: cursor,
                                              length: verse.range.location - cursor))
            if convertible[index],
               let drawn = rewrite(verse.block, y: placement[index],
                                   radius: radii[index],
                                   anchorX: anchors[index]) {
                out += drawn
            } else if verse.tagged, verse.text == octave {
                // it belongs to the column, so it moves and shrinks with it --
                // left alone it stands twice as tall as its own holes, in the
                // place the old spacing put it
                out += scaleText(verse.block, y: placement[index],
                                 radius: radii[index],
                                 anchorX: anchors[index]) ?? verse.block
            } else {
                out += verse.block
            }
            cursor = verse.range.location + verse.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// Which verses belong to a fingering: tagged ones, and untagged ones that
    /// sit in a tall column of holes on a single note.
    private static func columns(in verses: [Verse]) -> [Bool] {
        var convert = verses.map { $0.tagged && $0.symbol != nil }
        var runStart = 0
        while runStart < verses.count {
            var runEnd = runStart
            // one note's verses are numbered 1, 2, 3…; the next note starts
            // over, which is where one column ends and the next begins
            while runEnd + 1 < verses.count,
                  let here = verses[runEnd].number,
                  let next = verses[runEnd + 1].number,
                  next > here {
                runEnd += 1
            }
            let run = verses[runStart...runEnd]
            let holes = run.filter { $0.symbol != nil }.count
            let onlyHolesAndOctave = run.allSatisfy {
                $0.symbol != nil || $0.text == octave
            }
            if holes >= columnThreshold, onlyHolesAndOctave {
                for i in runStart...runEnd where verses[i].symbol != nil {
                    convert[i] = true
                }
            }
            runStart = runEnd + 1
        }
        return convert
    }

    /// The hole this verse draws, if it is one.
    private static func fingeringSymbol(in block: String) -> String? {
        guard let symbol = value(of: "(?<=>)[XO/](?=</tspan>)", in: block),
              [covered, open, half].contains(symbol) else { return nil }
        return symbol
    }

    /// One verse group, already judged to be a hole: draw it.
    /// A verse's y, for grouping and re-placing rows.
    private static func verseY(_ block: String) -> CGFloat? {
        number(of: "<text[^>]*y=\"([-0-9.]+)\"", in: block)
    }

    /// ...and its x, which is what pins a column to ONE note.
    private static func verseX(_ block: String) -> CGFloat? {
        number(of: "<text x=\"([-0-9.]+)\"", in: block)
    }

    /// Two consecutive verses in one column.
    ///
    /// Both tests are needed. y must increase, since a column runs down the
    /// page -- but that alone merged the last column of one system with the
    /// first of the next, whose y is larger still simply because it is further
    /// down the page.
    /// How far apart two rows of ONE column may sit horizontally.
    ///
    /// Not zero: Verovio centres each syllable on its own width, so an "X" row
    /// and an "O" row of the same note can be ten units apart. Not generous
    /// either: consecutive notes are a whole note-spacing apart. A quarter of
    /// the row pitch sits between the two and scales with the staff.
    private static func sameColumn(_ a: String, _ b: String,
                                   tolerance: CGFloat) -> Bool {
        guard let ya = verseY(a), let yb = verseY(b),
              let xa = verseX(a), let xb = verseX(b) else { return false }
        return yb > ya && abs(xb - xa) <= tolerance
    }

    private static func rewrite(_ block: String, y: CGFloat? = nil,
                                radius: CGFloat? = nil,
                                anchorX: CGFloat? = nil) -> String? {
        guard let symbol = fingeringSymbol(in: block),
              let x = number(of: "<text x=\"([-0-9.]+)\"", in: block),
              let textY = number(of: "<text[^>]*y=\"([-0-9.]+)\"", in: block),
              // the INNER tspan carries the real size; the enclosing <text> is
              // font-size="0px", and reading that gave every circle a radius of
              // zero — invisible, while the host renderer (which reads the
              // tspan) drew them correctly
              let size = number(of: "<tspan font-size=\"([0-9.]+)px\">", in: block),
              size > 0
        else { return nil }

        // The row's own position and size, from its column. Without them (a
        // lone verse with no column to measure) the old font-derived geometry
        // still applies.
        let cx: CGFloat, cy: CGFloat, r: CGFloat, strokeAt: CGFloat
        if let radius {
            r = radius
            cx = (anchorX ?? x) + centreXVsRadius * r
            cy = (y ?? textY) - centreYVsRadius * r
            strokeAt = strokeVsRadius * r
        } else {
            let drawn = size * diagramScale
            cx = x + centreX * drawn
            cy = textY + centreY * drawn
            r = Self.radius * drawn
            strokeAt = strokeWidth * drawn
        }
        // Paths, not <circle>: SwiftDraw renders the subset Verovio emits, and
        // Verovio emits only paths and glyph <use>s — a <circle> came out of
        // the on-device renderer as nothing at all.
        let ring = Self.circlePath(cx: cx, cy: cy, r: r)
        let shape: String
        switch symbol {
        case covered:
            shape = "<path d=\"\(ring)\" fill=\"currentColor\" stroke=\"none\" />"
        case open:
            shape = "<path d=\"\(ring)\" fill=\"none\" stroke=\"currentColor\" "
                + "stroke-width=\"\(strokeAt)\" />"
        default:
            // half-holed: an open ring with its lower half filled
            shape = "<path d=\"\(ring)\" fill=\"none\" stroke=\"currentColor\" "
                + "stroke-width=\"\(strokeAt)\" />"
                + "<path d=\"M \(cx - r) \(cy) A \(r) \(r) 0 0 0 \(cx + r) \(cy) Z\" "
                + "fill=\"currentColor\" stroke=\"none\" />"
        }
        // keep the group (and its title) so nothing downstream loses its footing
        return replacingText(in: block, with: shape)
    }

    /// Shrink a verse's glyph to the diagram scale, leaving it as text.
    ///
    /// The octave "+" also has to sit UNDER its column rather than beside it.
    /// A hole becomes a circle whose centre is offset from the verse's text
    /// anchor, so a "+" left at that anchor hangs a full offset to one side --
    /// and because Verovio placed it by its own glyph width, its anchor is not
    /// even the holes' anchor. It goes on the COLUMN's axis here, with
    /// `text-anchor="middle"` so the glyph's width stops mattering.
    private static func scaleText(_ block: String, y: CGFloat? = nil,
                                  radius: CGFloat? = nil,
                                  anchorX: CGFloat? = nil) -> String? {
        guard let re = RegexCache.regex(pattern: "<tspan font-size=\"([0-9.]+)px\">"),
              let m = re.firstMatch(in: block,
                                    range: NSRange(location: 0, length: (block as NSString).length)),
              m.numberOfRanges > 1
        else { return nil }
        let ns = block as NSString
        let size = CGFloat(Double(ns.substring(with: m.range(at: 1))) ?? 0)
        guard size > 0 else { return nil }
        let wanted = radius.map { $0 * 2 * octaveMarkVsDiameter } ?? (size * diagramScale)
        var moved = ns.replacingCharacters(
            in: m.range, with: "<tspan font-size=\"\(wanted)px\">") as String
        if let y, let yre = RegexCache.regex(pattern: "(<text[^>]*y=\")[-0-9.]+(\")"),
           let ym = yre.firstMatch(in: moved,
                                   range: NSRange(location: 0, length: (moved as NSString).length)) {
            let mns = moved as NSString
            moved = mns.replacingCharacters(
                in: ym.range,
                with: mns.substring(with: ym.range(at: 1)) + "\(y)"
                    + mns.substring(with: ym.range(at: 2)))
        }
        if let radius, let own = number(of: "<text x=\"([-0-9.]+)\"", in: moved) {
            let centre = (anchorX ?? own) + centreXVsRadius * radius
            if let xre = RegexCache.regex(pattern: "<text x=\"[-0-9.]+\""),
               let xm = xre.firstMatch(
                   in: moved,
                   range: NSRange(location: 0, length: (moved as NSString).length)) {
                moved = (moved as NSString).replacingCharacters(
                    in: xm.range,
                    with: "<text text-anchor=\"middle\" x=\"\(centre)\"")
            }
        }
        return moved
    }

    /// A full circle as two arcs, which every SVG renderer draws.
    static func circlePath(cx: CGFloat, cy: CGFloat, r: CGFloat) -> String {
        "M \(cx - r) \(cy) A \(r) \(r) 0 1 0 \(cx + r) \(cy) "
            + "A \(r) \(r) 0 1 0 \(cx - r) \(cy) Z"
    }

    /// Swap the `<text>…</text>` for the shape, leaving the rest of the group.
    private static func replacingText(in block: String, with shape: String) -> String? {
        guard let re = RegexCache.regex(pattern: "<text.*?</text>",
                                                options: [.dotMatchesLineSeparators])
        else { return nil }
        let ns = block as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard re.firstMatch(in: block, range: range) != nil else { return nil }
        return re.stringByReplacingMatches(in: block, range: range,
                                           withTemplate: shape)
    }

    private static func value(of pattern: String, in text: String) -> String? {
        guard let re = RegexCache.regex(pattern: pattern),
              let m = re.firstMatch(in: text,
                                    range: NSRange(location: 0, length: (text as NSString).length))
        else { return nil }
        return (text as NSString).substring(with: m.range)
    }

    private static func number(of pattern: String, in text: String) -> CGFloat? {
        guard let re = RegexCache.regex(pattern: pattern),
              let m = re.firstMatch(in: text,
                                    range: NSRange(location: 0, length: (text as NSString).length)),
              m.numberOfRanges > 1
        else { return nil }
        return CGFloat(Double((text as NSString).substring(with: m.range(at: 1))) ?? 0)
    }
}
