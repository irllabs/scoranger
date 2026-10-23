import Foundation

/// Guitar tablature, drawn on device.
///
/// The notation carries six lyric verses per note — a fret number on the string
/// that is played, a dash on the ones that are not (`ops.guitar_tab`). Verse 1
/// is the HIGHEST string, because a tab staff's top line is the string nearest
/// the floor.
///
/// What is drawn is the staff: six lines running through the dashes, with the
/// numbers standing in gaps cut in them. The DASH is the meaning and the LINE
/// is the drawing — the arrangement the whistle's letters and circles have.
/// Left as text a column of dashes is six loose hyphens under every note.
///
/// Each column's lines reach half way to the neighbouring column, so the six
/// lines are drawn a column at a time and still come out continuous.
///
/// The rows are re-placed here rather than asked of Verovio, for the reason the
/// whistle's are: `lyricSize` is one document-wide text size that also governs
/// chord symbols, so shrinking the tab to fit would shrink every chord name on
/// the page with it.
///
/// Mirrors the tablature half of engine/scoranger_engine/render.py;
/// engine/scripts/check_guitar_tab.py holds the two to one golden fragment.
enum TabStaff {

    /// The engine's marker, mirrored from ops.TAB_LYRIC_TAG. A verse's name is
    /// the tag AND whatever `adjust-element --kind tab` wrote onto it —
    /// `gt`, `gt@1.5`, `gt@1.5,20,-30` — because Verovio carries a lyric's name
    /// through to the page and drops its font-size and its offsets.
    static let tag = "gt"
    /// A string that is not played on this beat.
    static let rest = "-"
    static let rows = 6

    // Mirrors render.py's TAB_* constants.
    static let pitchRatio = 0.62
    static let digitVsPitch = 0.9
    static let lineVsPitch = 0.055
    static let breakVsPitch = 0.42
    static let endAdvance = 1.1
    static let baselineVsPitch = 0.32
    /// MusicXML measures a nudge in TENTHS of a staff space and this pass
    /// places the rows itself, so it needs the two in the same units. Measured
    /// off a real engraving: a staff space is 180 SVG units where the lyric row
    /// pitch is 390.
    static let tenthVsRowPitch = 0.04615

    /// (size ratio, dx, dy) from a tab verse's name, or nil if it is not one.
    static func parseLabel(_ label: String) -> (scale: Double?, dx: Double?, dy: Double?)? {
        guard label.hasPrefix(tag) else { return nil }
        let rest = String(label.dropFirst(tag.count))
        if rest.isEmpty { return (nil, nil, nil) }
        guard rest.hasPrefix("@") else { return nil }
        let fields = rest.dropFirst().components(separatedBy: ",")
        func value(_ index: Int) -> Double? {
            index < fields.count && !fields[index].isEmpty ? Double(fields[index]) : nil
        }
        return (value(0), value(1), value(2))
    }

    /// Python's `%g`, which is what render.py formats every number with.
    private static func g(_ value: Double) -> String { String(format: "%g", value) }

    /// One column of tab: six line segments, and the frets standing in them.
    /// Byte-for-byte what render.py's `tab_column_svg` produces.
    static func columnSVG(texts: [String], x: Double, topY: Double, rowPitch: Double,
                          left: Double, right: Double, scale: Double = 1) -> String {
        let pitch = rowPitch * pitchRatio * scale
        let stroke = pitch * lineVsPitch
        var parts = ""

        func line(_ x1: Double, _ y: Double, _ x2: Double) {
            parts += "<path d=\"M \(g(x1)) \(g(y)) L \(g(x2)) \(g(y))\" "
                + "stroke=\"currentColor\" stroke-width=\"\(g(stroke))\" fill=\"none\"/>"
        }

        for (row, text) in texts.enumerated() {
            let y = topY + Double(row) * pitch
            let fret = text.trimmingCharacters(in: .whitespaces)
            if !fret.isEmpty, fret != rest {
                let gap = pitch * breakVsPitch * (fret.count < 2 ? 1.0 : 1.5)
                for (x1, x2) in [(left, x - gap), (x + gap, right)] where x2 > x1 {
                    line(x1, y, x2)
                }
                parts += "<text text-anchor=\"middle\" font-style=\"normal\" x=\"\(g(x))\" "
                    + "y=\"\(g(y + pitch * baselineVsPitch))\">"
                    + "<tspan font-size=\"\(g(pitch * digitVsPitch))px\">\(fret)</tspan></text>"
            } else {
                line(left, y, right)
            }
        }
        return parts
    }

    /// One verse of a tab column, as it stands in a rendered page.
    private struct Verse {
        let range: NSRange
        let text: String
        let x: Double
        let y: Double
        let scale: Double
        let dx: Double
        let dy: Double
    }

    /// One column: the verses of one note.
    private struct Column {
        var rows: [Verse]
        var pitch: Double
        var top: Double
        var x: Double
        var scale: Double
        var dx: Double
        var dy: Double
    }

    private static func columns(in svg: String) -> [Column] {
        guard let verseRE = RegexCache.regex(
                pattern: "<g[^>]*class=\"verse\">.*?</g>\\s*</g>",
                options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = svg as NSString
        var verses: [Verse] = []
        for m in verseRE.matches(in: svg, range: NSRange(location: 0, length: ns.length)) {
            let block = ns.substring(with: m.range)
            guard let label = value(of: "(?<=<title class=\"labelAttr\">)[^<]*(?=</title>)",
                                    in: block),
                  let adjustment = parseLabel(label),
                  let x = number(of: "<text x=\"([-0-9.]+)\"", in: block),
                  let y = number(of: "<text[^>]*y=\"([-0-9.]+)\"", in: block)
            else { continue }
            let text = value(of: "(?<=>)[^<>]{1,3}(?=</tspan>)", in: block) ?? ""
            verses.append(Verse(range: m.range, text: text, x: x, y: y,
                                scale: adjustment.scale ?? 1,
                                dx: adjustment.dx ?? 0, dy: adjustment.dy ?? 0))
        }

        var out: [Column] = []
        var run: [Verse] = []
        func settle() {
            defer { run = [] }
            guard run.count >= 2 else { return }
            let ys = run.map(\.y)
            let gaps = zip(ys, ys.dropFirst()).map { $1 - $0 }.filter { $0 > 0 }.sorted()
            guard !gaps.isEmpty else { return }
            let middle = gaps.count / 2
            let pitch = gaps.count % 2 == 1
                ? gaps[middle] : (gaps[middle - 1] + gaps[middle]) / 2
            let xs = run.map(\.x).sorted()
            // the whole column moves and resizes together, so its first verse
            // speaks for it
            out.append(Column(rows: run, pitch: pitch, top: ys[0], x: xs[xs.count / 2],
                              scale: run[0].scale, dx: run[0].dx, dy: run[0].dy))
        }
        // Both tests are needed. y must increase, since a column runs down the
        // page — but that alone merges the last column of one system with the
        // first of the next, which is further down the page only because it is
        // further down the page.
        for verse in verses {
            if let last = run.last {
                let tolerance = max(abs(verse.y - last.y) * 0.5, 2.0)
                if !(verse.y > last.y && abs(verse.x - last.x) <= tolerance) { settle() }
            }
            run.append(verse)
        }
        settle()
        return out
    }

    /// Draw the tab staff through every tab column in a page.
    static func draw(in svg: String) -> String {
        guard svg.contains("class=\"verse\"") else { return svg }
        let found = columns(in: svg)
        guard !found.isEmpty else { return svg }

        // Columns of one SYSTEM share their top row, because Verovio lays every
        // verse of a system on the same baseline. That is what lets each
        // column's lines reach half way to its neighbour and meet them.
        var systems: [Int: [Column]] = [:]
        for column in found { systems[Int(column.top.rounded()), default: []].append(column) }

        var drawn: [Int: String] = [:]
        for (_, unsorted) in systems {
            let row = unsorted.sorted { $0.x < $1.x }
            for (index, column) in row.enumerated() {
                let pitch = column.pitch * pitchRatio * column.scale
                let before = index > 0 ? row[index - 1].x : nil
                let after = index + 1 < row.count ? row[index + 1].x : nil
                let left = before.map { ($0 + column.x) / 2 } ?? (column.x - pitch * endAdvance)
                let right = after.map { ($0 + column.x) / 2 } ?? (column.x + pitch * endAdvance)
                // MusicXML measures up; the page measures down
                let unit = column.pitch * tenthVsRowPitch
                let dx = column.dx * unit, dy = -column.dy * unit
                drawn[column.rows[0].range.location] = columnSVG(
                    texts: column.rows.map(\.text), x: column.x + dx,
                    topY: column.top + dy, rowPitch: column.pitch,
                    left: left + dx, right: right + dx, scale: column.scale)
            }
        }

        let ns = svg as NSString
        var out = ""
        var cursor = 0
        for column in found {
            for verse in column.rows {
                out += ns.substring(with: NSRange(location: cursor,
                                                  length: verse.range.location - cursor))
                if let fragment = drawn[verse.range.location] {
                    out += "<g class=\"verse tab\">\(fragment)</g>"
                }
                cursor = verse.range.location + verse.range.length
            }
        }
        out += ns.substring(from: cursor)
        return out
    }

    private static func value(of pattern: String, in text: String) -> String? {
        guard let re = RegexCache.regex(pattern: pattern),
              let m = re.firstMatch(in: text,
                                    range: NSRange(location: 0, length: (text as NSString).length))
        else { return nil }
        return (text as NSString).substring(with: m.range)
    }

    private static func number(of pattern: String, in text: String) -> Double? {
        guard let re = RegexCache.regex(pattern: pattern),
              let m = re.firstMatch(in: text,
                                    range: NSRange(location: 0, length: (text as NSString).length)),
              m.numberOfRanges > 1
        else { return nil }
        return Double((text as NSString).substring(with: m.range(at: 1)))
    }
}
