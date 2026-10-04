import Foundation

/// Guitar chord diagrams, drawn on device.
///
/// The notation carries the shape: `[x,3,2,0,1,0]`, one entry per string from
/// the low E up, `x` for a string that is not sounded. The window of the neck,
/// the nut, the barre and the "5 fr." label all follow from those six numbers
/// by the rules below, so the page cannot say something the notation does not.
///
/// And after them, in parentheses, the FINGERING — when there is one to say.
/// `[3,2,0,0,0,3](3,2,0,0,0,4)` is a G: three fingers where the dots are, and
/// the pinky on the top E. A fingering is a convention rather than an
/// arithmetic, so it comes from the notation and is never worked out here;
/// where the notation carries none, the row above the grid shows the frets,
/// which is what it always showed.
///
/// GLYPHS ARE NOT AN OPTION for the grid, the dots or the bar. That is the
/// lesson the whistle's circles taught: the font the rasteriser falls back to
/// has no filled circle and engraves an empty box. Everything here is paths —
/// and paths rather than `<circle>`, because SwiftDraw draws the subset Verovio
/// emits and a `<circle>` came out of this renderer as nothing at all. Only the
/// fret numbers and the position label are text, being digits.
///
/// Verovio reserves the space; we do the drawing. A one-line `<dir>` reserves
/// one line of text and a diagram is seven rows tall, so `meiWithDiagrams`
/// opens each marker into a block of blank rows and pins them all to one level
/// with `@vgrp` — without which Verovio gives every direction a level of its
/// own and the diagrams climb the page in steps, one per chord.
///
/// Mirrors the chord-diagram half of engine/scoranger_engine/render.py, which
/// draws the same picture for the PDF; engine/scripts/check_chord_diagrams.py
/// holds the two to one golden fragment, so a change made here and not there
/// fails a check rather than the eye.
enum ChordDiagrams {

    // MARK: the shape, and what follows from it

    static let strings = 6
    /// rows of the reserved block: one for the marks, six for the lines that
    /// bound five frets
    static let rows = 7
    static let frets = 5
    /// A shape that fits inside the first five frets is drawn against the nut;
    /// anything higher is a window on the neck, labelled with the fret it
    /// starts at. Mirrors ops.GUITAR_GRID_FRETS.
    static let gridFrets = 5

    /// `[x,3,2,0,1,0]` -> six frets, nil for a string that is not sounded.
    /// A trailing `(...)` is the fingering and is not part of the shape.
    static func parseShape(_ text: String) -> [Int?]? {
        guard let re = try? NSRegularExpression(pattern: "\\[(?:[x\\d]{1,2},){5}[x\\d]{1,2}\\]"),
              let m = re.firstMatch(in: text,
                                    range: NSRange(location: 0, length: (text as NSString).length))
        else { return nil }
        let body = (text as NSString).substring(with: m.range).dropFirst().dropLast()
        let shape = body.split(separator: ",").map { part -> Int? in
            part == "x" ? nil : Int(part)
        }
        return shape.count == strings ? shape : nil
    }

    /// `[3,2,0,0,0,3](3,2,0,0,0,4)` -> the six fingers, nil for a string that
    /// is not stopped. nil for a marker that names no fingering at all, which
    /// is what makes the marks row fall back to the frets.
    static func parseFingering(_ text: String) -> [Int?]? {
        guard let re = try? NSRegularExpression(
                pattern: "\\[(?:[x\\d]{1,2},){5}[x\\d]{1,2}\\]\\(((?:[x\\d],){5}[x\\d])\\)"),
              let m = re.firstMatch(in: text,
                                    range: NSRange(location: 0, length: (text as NSString).length))
        else { return nil }
        let fingers = (text as NSString).substring(with: m.range(at: 1))
            .split(separator: ",").map { part -> Int? in part == "x" ? nil : Int(part) }
        return fingers.count == strings ? fingers : nil
    }

    /// (first fret drawn, is the top line the nut?)
    static func window(_ shape: [Int?]) -> (base: Int, nut: Bool) {
        let stopped = shape.compactMap { $0 }.filter { $0 > 0 }
        guard let highest = stopped.max(), highest > gridFrets else { return (1, true) }
        return (stopped.min() ?? 1, false)
    }

    /// (fret, lowest string, highest string) of the barre, or nil.
    ///
    /// One finger lies across several strings when the lowest stopped fret is
    /// stopped on more than one string AND something is stopped above it in
    /// between — otherwise those are two fingers that happen to share a fret.
    /// And a finger lying across the neck stops every string it crosses, so an
    /// OPEN string inside the span means there is no barre there.
    static func barre(_ shape: [Int?]) -> (fret: Int, first: Int, last: Int)? {
        var stopped: [Int: Int] = [:]
        for (i, f) in shape.enumerated() where (f ?? 0) > 0 { stopped[i] = f }
        guard let low = stopped.values.min() else { return nil }
        let atLow = stopped.filter { $0.value == low }.keys.sorted()
        guard atLow.count >= 2, let first = atLow.first, let last = atLow.last else { return nil }
        guard stopped.contains(where: { $0.key > first && $0.key < last && $0.value > low })
        else { return nil }
        for i in first...last where shape[i] == 0 { return nil }
        return (low, first, last)
    }

    // MARK: geometry
    //
    // All of it is proportional to the string gap, and the string gap is the
    // block's own row pitch, so a diagram scales with the engraving exactly as
    // the whistle's holes do. Mirrors render.py's DIAGRAM_* constants.

    static let gapVsRow = 1.0
    static let dotVsGap = 0.3
    /// the bar is a shade slimmer than a dot is wide, so it does not touch the
    /// fret lines above and below it
    static let barreVsGap = 0.22
    static let lineVsGap = 0.05
    static let nutVsGap = 0.16
    static let markTextVsGap = 0.7
    static let positionTextVsGap = 0.6
    /// The point size a diagram is drawn at when nobody has adjusted it, so an
    /// absolute size from `adjust-element` reads as a ratio of the drawn one —
    /// the same arrangement chord symbols use.
    static let defaultPoints = 12.0
    /// The level every diagram is pinned to.
    static let vgrp = "1"

    struct Geometry {
        let gap, left, width, marksY, top, height: Double
        let dot, barre, line, nut, markText, positionText: Double
    }

    static func geometry(x: Double, topY: Double, rowPitch: Double,
                         scale: Double = 1) -> Geometry {
        let gap = rowPitch * gapVsRow * scale
        return Geometry(gap: gap, left: x, width: gap * Double(strings - 1),
                        marksY: topY, top: topY + rowPitch * 0.5 + gap * 0.25,
                        height: gap * Double(frets),
                        dot: gap * dotVsGap, barre: gap * barreVsGap,
                        line: gap * lineVsGap, nut: gap * nutVsGap,
                        markText: gap * markTextVsGap,
                        positionText: gap * positionTextVsGap)
    }

    /// Python's `%g`, which is what render.py formats every number with.
    private static func g(_ value: Double) -> String { String(format: "%g", value) }

    /// A filled circle as two arcs, which every SVG renderer draws.
    private static func disc(_ cx: Double, _ cy: Double, _ r: Double) -> String {
        "<path d=\"M \(g(cx - r)) \(g(cy)) A \(g(r)) \(g(r)) 0 1 0 \(g(cx + r)) \(g(cy)) "
            + "A \(g(r)) \(g(r)) 0 1 0 \(g(cx - r)) \(g(cy)) Z\" "
            + "fill=\"currentColor\" stroke=\"none\"/>"
    }

    /// One diagram, drawn. Byte-for-byte what render.py's
    /// `chord_diagram_svg` produces for the same arguments.
    static func diagramSVG(shape: [Int?], x: Double, topY: Double,
                           rowPitch: Double, scale: Double = 1,
                           fingers: [Int?]? = nil) -> String {
        let geo = geometry(x: x, topY: topY, rowPitch: rowPitch, scale: scale)
        let (base, nut) = window(shape)
        let bar = barre(shape)
        var parts = ""

        func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ width: Double) {
            parts += "<path d=\"M \(g(x1)) \(g(y1)) L \(g(x2)) \(g(y2))\" "
                + "stroke=\"currentColor\" stroke-width=\"\(g(width))\" fill=\"none\"/>"
        }

        for s in 0..<strings {
            let sx = geo.left + Double(s) * geo.gap
            line(sx, geo.top, sx, geo.top + geo.height, geo.line)
        }
        for f in 0...frets {
            let fy = geo.top + Double(f) * geo.gap
            line(geo.left, fy, geo.left + geo.width, fy, (f == 0 && nut) ? geo.nut : geo.line)
        }

        // the marks row: what each HAND does, low to high — x for a string
        // that is not sounded, 0 for one left open, and otherwise the finger
        // that stops it, falling back to the fret when the notation names no
        // fingering
        for (s, fret) in (fingers ?? shape).enumerated() {
            let mark = fret.map(String.init) ?? "x"
            parts += "<text text-anchor=\"middle\" font-style=\"normal\" "
                + "x=\"\(g(geo.left + Double(s) * geo.gap))\" y=\"\(g(geo.marksY))\">"
                + "<tspan font-size=\"\(g(geo.markText))px\">\(mark)</tspan></text>"
        }

        func cellCentre(_ fret: Int) -> Double {
            geo.top + (Double(fret - base) + 0.5) * geo.gap
        }

        var barred: Set<Int> = []
        if let bar {
            barred = Set((bar.first...bar.last).filter { shape[$0] == bar.fret })
            let y = cellCentre(bar.fret)
            let half = geo.barre
            parts += "<path d=\"M \(g(geo.left + Double(bar.first) * geo.gap)) \(g(y - half)) "
                + "H \(g(geo.left + Double(bar.last) * geo.gap)) V \(g(y + half)) "
                + "H \(g(geo.left + Double(bar.first) * geo.gap)) Z\" "
                + "fill=\"currentColor\" stroke=\"none\"/>"
        }

        for (s, fret) in shape.enumerated() {
            guard let fret, fret > 0, !barred.contains(s) else { continue }
            parts += disc(geo.left + Double(s) * geo.gap, cellCentre(fret), geo.dot)
        }

        if !nut {
            parts += "<text font-style=\"normal\" "
                + "x=\"\(g(geo.left + geo.width + geo.gap * 0.4))\" "
                + "y=\"\(g(geo.top + geo.gap * 0.7))\">"
                + "<tspan font-size=\"\(g(geo.positionText))px\">\(base) fr.</tspan></text>"
        }
        return parts
    }

    // MARK: the adjustment the reader made

    /// A diagram's size and offset, as `adjust-element --kind diagram` wrote
    /// them onto the `<words>` the shape rides in. Verovio drops all three on
    /// the way to MEI, so they are read from the file and matched by document
    /// order — the same join `ChordAdjustments` uses for chord symbols.
    struct Adjustment: Equatable {
        var size: Double?
        var dx: Double?
        var dy: Double?
        var isEmpty: Bool { size == nil && dx == nil && dy == nil }
    }

    static func adjustments(inMusicXML xml: String) -> [Adjustment] {
        guard let re = try? NSRegularExpression(pattern: "<words\\b([^>]*)>([^<]*)</words>")
        else { return [] }
        let ns = xml as NSString
        var out: [Adjustment] = []
        for m in re.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
            let body = ns.substring(with: m.range(at: 2))
            guard parseShape(body) != nil else { continue }
            let tag = ns.substring(with: m.range(at: 1))
            out.append(Adjustment(size: number("font-size", in: tag),
                                  dx: number("relative-x", in: tag),
                                  dy: number("relative-y", in: tag)))
        }
        return out
    }

    private static func number(_ attr: String, in tag: String) -> Double? {
        guard let re = try? NSRegularExpression(pattern: "\(attr)=\"([-0-9.]+)\""),
              let m = re.firstMatch(in: tag,
                                    range: NSRange(location: 0, length: (tag as NSString).length)),
              m.numberOfRanges > 1
        else { return nil }
        return Double((tag as NSString).substring(with: m.range(at: 1)))
    }

    /// MusicXML measures in tenths of a staff space; MEI's @ho/@vo in halves.
    static let tenthsToHalfSpaces = 0.2

    /// Reserve a block for every diagram, and pin them all to one level.
    ///
    /// Returns nil when the score carries no diagram, so the caller can skip a
    /// Verovio reload. The shape moves into `@label`, which Verovio carries to
    /// the SVG as a `<title>`, and the body becomes blank rows: the marker's
    /// own text is not what anyone should read on the page.
    static func meiWithDiagrams(_ mei: String,
                                adjustments: [Adjustment] = []) -> String? {
        guard let re = try? NSRegularExpression(
            pattern: "<dir\\b([^>]*)>\\s*(\\[[x\\d,]+\\](?:\\([x\\d,]+\\))?)\\s*</dir>",
            options: [.dotMatchesLineSeparators]) else { return nil }
        let ns = mei as NSString
        let matches = re.matches(in: mei, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }

        var out = ""
        var cursor = 0
        for (index, m) in matches.enumerated() {
            out += ns.substring(with: NSRange(location: cursor,
                                              length: m.range.location - cursor))
            var attrs = ns.substring(with: m.range(at: 1))
            let shape = ns.substring(with: m.range(at: 2))
            let adjustment = index < adjustments.count ? adjustments[index] : Adjustment()
            let scale = adjustment.size.map { $0 / defaultPoints } ?? 1
            var label = shape
            if adjustment.size != nil { label += "@" + g(scale) }
            // The reserved block grows with the diagram: the rows are what
            // Verovio spaces the system by, and seven of them are seven
            // whatever size the drawing is.
            let blank = Array(repeating: " ",
                              count: Int((Double(rows) * scale).rounded(.up)))
                .joined(separator: "<lb/>")
            // Verovio turns a <words relative-y> into a @vgrp of its own, which
            // would scatter the diagrams up the page; ours replaces it.
            attrs = attrs.replacingOccurrences(of: "\\s+vgrp=\"[^\"]*\"", with: "",
                                               options: .regularExpression)
            if let dx = adjustment.dx { attrs += " ho=\"\(g(dx * tenthsToHalfSpaces))\"" }
            // Both measure UP: MusicXML's relative-y does, and so does @vo on
            // a direction placed ABOVE a staff -- a negative one pushed the
            // block down onto the staff when it was measured.
            if let dy = adjustment.dy { attrs += " vo=\"\(g(dy * tenthsToHalfSpaces))\"" }
            out += "<dir\(attrs) vgrp=\"\(vgrp)\" label=\"\(label)\">\(blank)</dir>"
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// One marker in a rendered page, with the block Verovio gave it.
    struct Block {
        let range: NSRange
        let shape: [Int?]
        let fingers: [Int?]?
        let scale: Double
        let x: Double
        let top: Double
        let pitch: Double
    }

    /// Every diagram marker in a page. The rows are the blank lines the MEI
    /// pass put there; their spacing is the pitch the drawing is built from,
    /// exactly as a whistle column takes its pitch from the verses Verovio
    /// laid out.
    static func blocks(in svg: String) -> [Block] {
        // Nothing below can return a block without matching `labelRE`, which
        // needs this literal. The scan it skips is a dot-matches-newline regex
        // over the whole page, built and run once per page of every score --
        // including the great majority that carry no diagram at all. A filter,
        // not a behaviour change: the two conditions are the same condition.
        guard svg.contains("labelAttr") else { return [] }
        guard let groupRE = try? NSRegularExpression(
                pattern: "<g[^>]*class=\"dir\">.*?</g>",
                options: [.dotMatchesLineSeparators]),
              let labelRE = try? NSRegularExpression(
                pattern: "<title class=\"labelAttr\">(\\[[x\\d,]+\\](?:\\([x\\d,]+\\))?)(?:@([\\d.]+))?</title>"),
              let rowRE = try? NSRegularExpression(
                pattern: "<t(?:ext|span)[^>]*\\bx=\"([-\\d.]+)\"[^>]*\\by=\"([-\\d.]+)\"")
        else { return [] }

        let ns = svg as NSString
        var out: [Block] = []
        for m in groupRE.matches(in: svg, range: NSRange(location: 0, length: ns.length)) {
            let group = ns.substring(with: m.range)
            let groupNS = group as NSString
            let groupRange = NSRange(location: 0, length: groupNS.length)
            guard let label = labelRE.firstMatch(in: group, range: groupRange),
                  let shape = parseShape(groupNS.substring(with: label.range(at: 1)))
            else { continue }
            let fingers = parseFingering(groupNS.substring(with: label.range(at: 1)))
            let scale = label.range(at: 2).location == NSNotFound
                ? 1.0 : Double(groupNS.substring(with: label.range(at: 2))) ?? 1.0
            let rows = rowRE.matches(in: group, range: groupRange).map {
                (Double(groupNS.substring(with: $0.range(at: 1))) ?? 0,
                 Double(groupNS.substring(with: $0.range(at: 2))) ?? 0)
            }
            guard rows.count >= 2 else { continue }
            let ys = rows.map(\.1)
            let gaps = zip(ys, ys.dropFirst()).map { $1 - $0 }.filter { $0 > 0 }
            guard let pitch = gaps.min() else { continue }
            out.append(Block(range: m.range, shape: shape, fingers: fingers,
                             scale: scale, x: rows[0].0, top: ys[0], pitch: pitch))
        }
        return out
    }

    /// A string gap of room left before the next diagram, and the smallest
    /// a diagram is drawn: render.py's DIAGRAM_CLEARANCE_GAPS and
    /// DIAGRAM_MIN_FIT, which say why.
    static let clearanceGaps = 1.0
    static let minFit = 0.5

    /// The factor each block is drawn at so it does not reach the next one on
    /// its line (0.18.2): Verovio reserves a diagram's height but no width, so
    /// two chords a bar apart drew one grid over the other. render.py's
    /// `diagram_fit`, rule for rule; check_chord_diagrams.py holds both.
    static func fit(_ blocks: [(x: Double, top: Double, pitch: Double, scale: Double)]) -> [Double] {
        blocks.enumerated().map { i, block in
            let right = blocks.enumerated().compactMap { j, other -> Double? in
                j != i && other.x > block.x
                    && abs(other.top - block.top) < min(other.pitch, block.pitch)
                    ? other.x : nil
            }
            guard let next = right.min() else { return 1 }
            let room = next - block.x
            let wants = block.pitch * gapVsRow * block.scale
                * (Double(strings - 1) + clearanceGaps)
            return wants > room ? max(minFit, room / wants) : 1
        }
    }

    /// Replace every reserved diagram block with the drawn diagram.
    static func draw(in svg: String) -> String {
        let found = blocks(in: svg)
        guard !found.isEmpty else { return svg }
        let fits = fit(found.map { ($0.x, $0.top, $0.pitch, $0.scale) })
        let ns = svg as NSString
        var out = ""
        var cursor = 0
        for (block, fit) in zip(found, fits) {
            out += ns.substring(with: NSRange(location: cursor,
                                              length: block.range.location - cursor))
            out += "<g class=\"dir chord-diagram\">"
                + diagramSVG(shape: block.shape, x: block.x, topY: block.top,
                             rowPitch: block.pitch, scale: block.scale * fit,
                             fingers: block.fingers)
                + "</g>"
            cursor = block.range.location + block.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }
}
