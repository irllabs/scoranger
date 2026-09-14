import CoreGraphics
import Foundation

/// Verovio's SVG for one page, read as DRAW INSTRUCTIONS.
///
/// `SVGGeometryParser` reads the same document for BOUNDS: it folds every
/// primitive into the box of the group holding it and keeps no outlines, which
/// is all hit-testing needs. Nothing here replaces that. The two are separate
/// passes over the same string because they want different things from it, and
/// merging them would make the hit-test model carry a megabyte of `CGPath` it
/// never asks a question of.
///
/// ## The subset this has to cover
///
/// Measured over every page of both sample scores with the app's own engraving
/// options (`EngravingOptions.json`), the entire drawable vocabulary is:
///
///     <defs><g id="E050-…"><path transform="scale(1,-1)" d="…"/></g></defs>
///     <svg class="definition-scale" viewBox="0 0 21590 27940" color="black">
///     <g class=… id=… [transform=…] [visibility=visible]>
///     <path d=… stroke-width=… [stroke-linecap=…] [stroke-linejoin=…]>
///     <polygon points=…>                       beams
///     <polyline points=… stroke-width=… [fill="none"]>   hairpins
///     <ellipse cx cy rx ry>                    augmentation dots
///     <use xlink:href="#E050-…" transform=…>   every SMuFL glyph
///     <text x y [text-anchor] font-size><tspan …>…</tspan></text>
///
/// and one `<style>` block carrying `stroke:currentColor` plus four font rules.
///
/// Two findings from that survey matter more than the rest, and both cut work
/// the backlog had budgeted for:
///
/// 1. **Every `<use>` resolves inside its own page.** Verovio embeds the
///    outline of each glyph the page uses in that page's `<defs>` -- twelve to
///    twenty of them, shared by hundreds of `<use>` references. The glyphs are
///    Leipzig (Verovio's default face), not Bravura, and no font file is read
///    at draw time.
/// 2. **`stroke:currentColor` with `color="black"` is the whole colour model.**
///    There is no fill or stroke attribute anywhere except nine `fill="none"`
///    on hairpins.
enum VectorPageParser {

    enum ParseError: Error, LocalizedError {
        case malformed(String)
        var errorDescription: String? {
            if case .malformed(let why) = self { return "Malformed SVG: \(why)" }
            return nil
        }
    }

    static func parse(_ svg: String) throws -> VectorPage {
        let delegate = Delegate()
        let parser = XMLParser(data: Data(svg.utf8))
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse() else {
            throw ParseError.malformed(parser.parserError?.localizedDescription ?? "unknown")
        }
        guard let size = delegate.rootSize, size.width > 0, size.height > 0 else {
            throw ParseError.malformed("no size on the root <svg>")
        }
        return VectorPage(size: size, items: delegate.items,
                          undrawn: delegate.undrawnReport())
    }

    // MARK: -

    private final class Delegate: NSObject, XMLParserDelegate {

        var rootSize: CGSize?
        var items: [VectorPage.Item] = []

        /// One element's contribution to what its children inherit.
        private struct Frame {
            var transform: CGAffineTransform
            /// The nearest enclosing classed `<g>`, for the report.
            var owner: String
            /// The class tokens this element itself carried, for the CSS rules.
            var classes: [String]
            /// Text position and style, when this element supplied any.
            var x: Double?
            var y: Double?
            var fontSize: Double?
            var anchor: String?
            var family: String?
            var bold: Bool?
            var italic: Bool?
        }
        private var stack: [Frame] = []

        /// Glyph outlines from `<defs>`, by the id a `<use>` names.
        private var glyphs: [String: CGPath] = [:]
        private var inDefs = false
        private var defsID: String?
        private var defsPath = CGMutablePath()

        /// Characters gathered inside the innermost `<text>`/`<tspan>`.
        private var pendingText = ""
        private var inText = 0
        /// `<title>` also holds characters, is nested INSIDE `<text>`, and is
        /// a tooltip rather than notation. Verovio puts one on every page
        /// number.
        private var inTitle = 0

        /// One styled run of a text chunk.
        private struct Run {
            let text: String
            let family: String
            let size: Double
            let bold: Bool
            let italic: Bool
        }

        /// SVG text FLOWS, and an anchor applies to the WHOLE flow.
        ///
        /// Two sibling tspans with no x of their own are one line: Verovio
        /// writes the composer and the arranger that way, and a page number as
        /// "–", "2", "–" under one `text-anchor="middle"`. Drawing each run at
        /// the `<text>` element's own x stacks them on top of each other, and
        /// anchoring only the first run puts the rest off centre. So runs are
        /// banked until the chunk ends, measured together, and then placed.
        private var chunk: [Run] = []
        private var chunkOrigin: CGPoint?
        private var chunkAnchor: SVGTextPath.Anchor = .start

        private var undrawn: [String: Int] = [:]
        private var missingCharacters: Set<Character> = []

        private func record(_ reason: String) { undrawn[reason, default: 0] += 1 }

        func undrawnReport() -> [VectorPage.Undrawn] {
            var out = undrawn.map { VectorPage.Undrawn(reason: $0.key, count: $0.value) }
            if !missingCharacters.isEmpty {
                // Named one by one: "a character is missing" is not actionable,
                // and U+ECA5 in Leipzig is a specific, fixable gap.
                let names = missingCharacters.sorted()
                    .map { String(format: "U+%04X", $0.unicodeScalars.first?.value ?? 0) }
                out.append(VectorPage.Undrawn(
                    reason: "characters with no glyph in the chosen face (\(names.joined(separator: " ")))",
                    count: missingCharacters.count))
            }
            return out.sorted { $0.reason < $1.reason }
        }

        private var ctm: CGAffineTransform { stack.last?.transform ?? .identity }
        private var owner: String { stack.last?.owner ?? "" }

        // MARK: element start

        func parser(_ parser: XMLParser, didStartElement name: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes attrs: [String: String]) {
            switch name {
            case "svg":
                startSVG(attrs); return
            case "defs":
                inDefs = true
                push(attrs, local: .identity)
                return
            case "g" where inDefs:
                defsID = attrs["id"]
                defsPath = CGMutablePath()
                push(attrs, local: .identity)
                return
            case "path" where inDefs:
                if let d = attrs["d"], let built = SVGPathData.path(from: d) {
                    defsPath.addPath(built.path,
                                     transform: SVGTransform.parse(attrs["transform"]))
                    for kind in built.unsupported { record("SVG path command \(kind.rawValue)") }
                }
                push(attrs, local: .identity)
                return
            default:
                break
            }

            switch name {
            case "g":
                push(attrs, local: SVGTransform.parse(attrs["transform"]))

            case "path":
                push(attrs, local: .identity)
                guard let d = attrs["d"], let built = SVGPathData.path(from: d) else { return }
                for kind in built.unsupported { record("SVG path command \(kind.rawValue)") }
                emit(built.path, attrs: attrs, local: SVGTransform.parse(attrs["transform"]))

            case "polygon", "polyline":
                push(attrs, local: .identity)
                guard let path = Self.polyPath(attrs["points"], closed: name == "polygon")
                else { return }
                emit(path, attrs: attrs, local: SVGTransform.parse(attrs["transform"]))

            case "ellipse":
                push(attrs, local: .identity)
                guard let cx = Double(attrs["cx"] ?? ""), let cy = Double(attrs["cy"] ?? ""),
                      let rx = Double(attrs["rx"] ?? ""), let ry = Double(attrs["ry"] ?? ""),
                      rx > 0, ry > 0 else { return }
                let box = CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)
                emit(CGPath(ellipseIn: box, transform: nil), attrs: attrs,
                     local: SVGTransform.parse(attrs["transform"]))

            case "rect":
                push(attrs, local: .identity)
                guard let x = Double(attrs["x"] ?? ""), let y = Double(attrs["y"] ?? ""),
                      let w = Double(attrs["width"] ?? ""), let h = Double(attrs["height"] ?? ""),
                      w > 0, h > 0 else { return }
                emit(CGPath(rect: CGRect(x: x, y: y, width: w, height: h), transform: nil),
                     attrs: attrs, local: SVGTransform.parse(attrs["transform"]))

            case "use":
                push(attrs, local: .identity)
                let href = (attrs["xlink:href"] ?? attrs["href"] ?? "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                guard let glyph = glyphs[href] else {
                    record("glyph reference with no definition on this page")
                    return
                }
                // `<use x y>` is `<g transform="{transform} translate(x,y)">`,
                // so the translate applies FIRST. Verovio never emits both, but
                // the order is free to get right and expensive to discover.
                var local = CGAffineTransform.identity
                if let x = Double(attrs["x"] ?? ""), let y = Double(attrs["y"] ?? "") {
                    local = CGAffineTransform(translationX: x, y: y)
                }
                local = local.concatenating(SVGTransform.parse(attrs["transform"]))
                var t = local.concatenating(ctm)
                guard let placed = glyph.copy(using: &t) else { return }
                items.append(VectorPage.Item(path: placed, paint: .fill, owner: owner))

            case "text":
                pendingText = ""
                inText += 1
                push(attrs, local: .identity)

            case "tspan":
                bankRun()
                // A tspan that carries its own x starts a new chunk.
                if attrs["x"] != nil { drawChunk() }
                push(attrs, local: .identity)

            case "title", "desc":
                inTitle += 1
                push(attrs, local: .identity)

            case "style":
                // The stylesheet is READ FROM THE SURVEY, not parsed: Verovio
                // emits one fixed block, and a CSS parser here would be a
                // second thing to keep in step with it. See `isBold`/`isItalic`.
                push(attrs, local: .identity)

            default:
                push(attrs, local: .identity)
            }
        }

        // MARK: element end

        func parser(_ parser: XMLParser, didEndElement name: String,
                    namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "defs":
                inDefs = false
            case "g" where inDefs:
                if let id = defsID, !defsPath.isEmpty {
                    glyphs[id] = defsPath.copy() ?? defsPath
                }
                defsID = nil
                defsPath = CGMutablePath()
            case "text":
                bankRun()
                drawChunk()
                inText = max(inText - 1, 0)
            case "tspan":
                bankRun()
            case "title", "desc":
                // Whatever it held is a label, not notation.
                pendingText = ""
                inTitle = max(inTitle - 1, 0)
            default:
                break
            }
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard inText > 0, inTitle == 0 else { return }
            pendingText += string
        }

        // MARK: -

        private func push(_ attrs: [String: String], local: CGAffineTransform) {
            let classes = (attrs["class"] ?? "").split(separator: " ").map(String.init)
            let inherited = stack.last
            stack.append(Frame(
                transform: local.concatenating(inherited?.transform ?? .identity),
                owner: classes.first ?? inherited?.owner ?? "",
                classes: classes,
                x: Double(attrs["x"] ?? ""),
                y: Double(attrs["y"] ?? ""),
                fontSize: Self.pixels(attrs["font-size"]),
                anchor: attrs["text-anchor"],
                family: attrs["font-family"],
                bold: attrs["font-weight"].map { $0 == "bold" },
                italic: attrs["font-style"].map { $0 == "italic" }))
        }

        private func startSVG(_ attrs: [String: String]) {
            guard rootSize != nil else {
                // The root carries px width/height and no viewBox, so its user
                // space IS its pixel size.
                rootSize = Self.rootSize(attrs)
                push(attrs, local: .identity)
                return
            }
            // A nested `<svg viewBox>` with no width/height fills its parent's
            // viewport. Verovio uses exactly one, `class="definition-scale"`,
            // to put the page into its own tenths-of-a-millimetre grid; the
            // default `preserveAspectRatio` is xMidYMid meet, so the scale is
            // uniform and the remainder is split as margin.
            guard let viewBox = Self.viewBox(attrs), let viewport = rootSize,
                  viewBox.width > 0, viewBox.height > 0 else {
                push(attrs, local: .identity)
                return
            }
            let scale = min(viewport.width / viewBox.width, viewport.height / viewBox.height)
            let local = CGAffineTransform(translationX: -viewBox.minX, y: -viewBox.minY)
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(
                    translationX: (viewport.width - viewBox.width * scale) / 2,
                    y: (viewport.height - viewBox.height * scale) / 2))
            push(attrs, local: local)
        }

        /// Place one primitive, with the paint its attributes imply.
        private func emit(_ path: CGPath, attrs: [String: String],
                          local: CGAffineTransform) {
            var t = local.concatenating(ctm)
            guard let placed = path.copy(using: &t) else { return }
            let fills = attrs["fill"] != "none"
            let width = Self.pixels(attrs["stroke-width"]) ?? 0
            // Stroke width is in USER units and the page is scaled by about
            // 0.045, so it is scaled here rather than set on the context: a
            // context line width is in the context's own space and would have
            // to be undone by every caller drawing at a different zoom.
            let scaled = width * sqrt(abs(t.a * t.d - t.b * t.c))
            let paint: VectorPage.Paint
            switch (fills, scaled > 0) {
            case (true, true):
                paint = .fillAndStroke(width: scaled,
                                       cap: Self.cap(attrs["stroke-linecap"]),
                                       join: Self.join(attrs["stroke-linejoin"]))
            case (false, true):
                paint = .stroke(width: scaled,
                                cap: Self.cap(attrs["stroke-linecap"]),
                                join: Self.join(attrs["stroke-linejoin"]))
            case (true, false):
                paint = .fill
            case (false, false):
                return   // neither filled nor stroked: nothing to draw
            }
            items.append(VectorPage.Item(path: placed, paint: paint, owner: owner))
        }

        /// Bank the characters gathered so far as one run of the open chunk.
        private func bankRun() {
            defer { pendingText = "" }
            let text = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            var x: Double?, y: Double?, size: Double?, anchor: String?, family: String?
            for frame in stack.reversed() {
                if x == nil { x = frame.x }
                if y == nil { y = frame.y }
                // The outer <text> carries font-size="0px" and the real size
                // sits on an inner tspan, so a zero is not an answer.
                if size == nil, let s = frame.fontSize, s > 0 { size = s }
                if anchor == nil { anchor = frame.anchor }
                if family == nil { family = frame.family }
            }
            guard let x, let y, let size, size > 0 else {
                record("text with no position or size")
                return
            }
            if chunkOrigin == nil {
                chunkOrigin = CGPoint(x: x, y: y)
                chunkAnchor = SVGTextPath.Anchor(rawValue: anchor ?? "start") ?? .start
            }
            chunk.append(Run(text: text, family: family ?? "Times, serif",
                             size: size, bold: isBold, italic: isItalic))
        }

        /// Measure the banked runs together, then lay them out left to right.
        private func drawChunk() {
            defer { chunk = []; chunkOrigin = nil; chunkAnchor = .start }
            guard let origin = chunkOrigin, !chunk.isEmpty else { return }
            let total = chunk.reduce(CGFloat.zero) {
                $0 + SVGTextPath.advance(of: $1.text, family: $1.family,
                                         size: $1.size, bold: $1.bold, italic: $1.italic)
            }
            var pen = origin.x
            switch chunkAnchor {
            case .start:  break
            case .middle: pen -= total / 2
            case .end:    pen -= total
            }
            var t = ctm
            for run in chunk {
                guard let built = SVGTextPath.outline(
                    run.text, family: run.family, size: run.size,
                    bold: run.bold, italic: run.italic,
                    origin: CGPoint(x: pen, y: origin.y), anchor: .start)
                else { continue }
                missingCharacters.formUnion(built.missing)
                pen += built.advance
                guard let placed = built.path.copy(using: &t), !placed.isEmpty else { continue }
                items.append(VectorPage.Item(path: placed, paint: .fill, owner: owner))
            }
        }

        /// Verovio's stylesheet, applied from the class chain.
        ///
        /// The block it emits is fixed:
        ///
        ///     g.ending, g.fing, g.reh, g.tempo  { font-weight: bold }
        ///     g.dir,    g.dynam, g.mNum         { font-style: italic }
        ///     g.label                           { font-weight: normal }
        private var isBold: Bool {
            for frame in stack.reversed() {
                if let bold = frame.bold { return bold }
                if frame.classes.contains("label") { return false }
                if frame.classes.contains(where: {
                    ["ending", "fing", "reh", "tempo"].contains($0)
                }) { return true }
            }
            return false
        }

        private var isItalic: Bool {
            for frame in stack.reversed() {
                if let italic = frame.italic { return italic }
                if frame.classes.contains(where: {
                    ["dir", "dynam", "mNum"].contains($0)
                }) { return true }
            }
            return false
        }

        // MARK: attribute helpers

        private static func polyPath(_ points: String?, closed: Bool) -> CGPath? {
            guard let points else { return nil }
            let numbers = points.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" })
                .compactMap { Double($0) }
            guard numbers.count >= 4 else { return nil }
            let path = CGMutablePath()
            path.move(to: CGPoint(x: numbers[0], y: numbers[1]))
            var i = 2
            while i + 1 < numbers.count {
                path.addLine(to: CGPoint(x: numbers[i], y: numbers[i + 1]))
                i += 2
            }
            if closed { path.closeSubpath() }
            return path.copy()
        }

        private static func cap(_ value: String?) -> CGLineCap {
            switch value {
            case "round":  return .round
            case "square": return .square
            default:       return .butt
            }
        }

        private static func join(_ value: String?) -> CGLineJoin {
            switch value {
            case "round": return .round
            case "bevel": return .bevel
            default:      return .miter
            }
        }

        /// "405px" -> 405
        private static func pixels(_ value: String?) -> Double? {
            guard let value else { return nil }
            return Double(value.replacingOccurrences(of: "px", with: ""))
        }

        private static func rootSize(_ attrs: [String: String]) -> CGSize? {
            if let w = pixels(attrs["width"]), let h = pixels(attrs["height"]),
               w > 0, h > 0 {
                return CGSize(width: w, height: h)
            }
            if let box = viewBox(attrs) { return box.size }
            return nil
        }

        private static func viewBox(_ attrs: [String: String]) -> CGRect? {
            guard let box = attrs["viewBox"] else { return nil }
            let n = box.split(whereSeparator: { $0 == " " || $0 == "," })
                .compactMap { Double($0) }
            guard n.count == 4 else { return nil }
            return CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
        }
    }
}
