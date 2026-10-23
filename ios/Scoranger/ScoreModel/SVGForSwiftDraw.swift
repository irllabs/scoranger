import CoreText
import Foundation

/// Verovio's SVG, rewritten into the subset SwiftDraw can actually draw.
///
/// This is regex surgery on generated markup, and it lived inside the renderer
/// where no test could reach it — which is how a score that Verovio drew
/// perfectly could fail to reach the page with the renderer reporting "Verovio
/// rendered an empty page". It is pure string work, so it belongs here in the
/// host-less bundle where its behaviour can be pinned to real engravings.
///
/// Three things happen, and each is a place this can go wrong:
///
/// 1. fingerings become drawn circles and chord diagrams drawn grids, and
    ///    SMuFL accidentals become ASCII —
///    the rasteriser's fallback font has neither
/// 2. the inner `<svg class="definition-scale">` is flattened into a `<g>`,
///    hoisting its viewBox onto the root, which has only px width/height
/// 3. nested `<tspan>` runs are flattened into positioned `<text>` elements
/// 4. the FACE Verovio asks for in its own stylesheet is pushed down onto the
///    text as a font-family, because SwiftDraw reads neither the stylesheet
///    nor `font-style`
enum SVGForSwiftDraw {
    static let accidentalSubs: [(String, String)] = [
        ("\u{E260}", "b"), ("\u{E262}", "#"), ("\u{E261}", ""),
        ("\u{EA64}", "b"), ("\u{EA66}", "#"), ("\u{EA65}", ""),
        ("\u{266D}", "b"), ("\u{266F}", "#"), ("\u{266E}", ""),
    ]

    static func prepare(_ svg: String) -> String {
        // fingerings become drawn circles before anything else looks at the
        // text: they are shapes from here on, not glyphs
        var s = TabStaff.draw(in: ChordDiagrams.draw(in: FingeringDiagrams.draw(in: svg)))
        // UTF-8 in one piece, once, for the byte searches below
        s.makeContiguousUTF8()
        // Looked for literally before replacing: Foundation's default search
        // compares grapheme clusters, a third of a dense score's raster time,
        // and most pages carry none of these glyphs. None of them has a
        // canonically equivalent spelling, so a page with no literal
        // occurrence has none at all, and a page with one is replaced exactly
        // as before. Looked for in the bytes (`TextSearch`): even a literal
        // Foundation search of a dense page cost 20 ms.
        for (glyph, ascii) in accidentalSubs where TextSearch.contains(s, glyph) {
            s = s.replacingOccurrences(of: glyph, with: ascii)
        }
        if TextSearch.contains(s, "currentColor") {
            s = s.replacingOccurrences(of: "currentColor", with: "black")
        }

        // flatten <svg class="definition-scale" viewBox="..."> into a <g>,
        // hoisting its viewBox onto the root svg (which has only px width/height)
        if let inner = s.range(of: #"<svg class="definition-scale"[^>]*>"#,
                               options: .regularExpression) {
            let tag = String(s[inner])
            var viewBox = ""
            if let vb = tag.range(of: #"viewBox="[^"]*""#, options: .regularExpression) {
                viewBox = String(tag[vb])
            }
            s.replaceSubrange(inner, with: #"<g stroke="black" color="black">"#)
            if let close = TextSearch.range(of: "</svg>", in: s) {
                s.replaceSubrange(close, with: "</g>")
            }
            if !viewBox.isEmpty, let root = TextSearch.range(of: "<svg ", in: s) {
                s.replaceSubrange(root, with: "<svg \(viewBox) ")
            }
        }

        // Both passes build in NSString's UTF-16 and hand back a bridged
        // string; SwiftDraw is given its UTF-8, which is transcoded here in
        // one go rather than a scalar at a time by the `Data` it is read into.
        var prepared = flattenTextElements(applyElementFaces(s))
        prepared.makeContiguousUTF8()
        return prepared
    }

    // MARK: - The face Verovio asks for

    /// Verovio ships its own stylesheet inside every page it draws:
    ///
    ///     #ID g.ending, #ID g.fing, #ID g.reh, #ID g.tempo {font-weight:bold;}
    ///     #ID g.dir,    #ID g.dynam, #ID g.mNum            {font-style:italic;}
    ///
    /// SwiftDraw reads none of it. Its CSS support stops at plain `.class` and
    /// `#id` selectors, so Verovio's descendant selectors never match; and its
    /// DOM has no `font-style` and no `font-weight` AT ALL, so even a matched
    /// rule would carry nothing. The only lever it has is `font-family`, which
    /// it hands to `CTFontCreateWithName`.
    ///
    /// So the face is resolved here and delivered as a font NAME. Until this
    /// existed every direction, dynamic, expression mark, bass fingering and
    /// measure number in the app was drawn upright, and the tempo mark was
    /// drawn light -- on every page, for as long as the app has had this path.
    static let italicClasses: Set<String> = ["dir", "dynam", "mNum"]
    static let boldClasses: Set<String> = ["ending", "fing", "reh", "tempo"]

    /// Stamp `font-style`/`font-weight` onto the `<text>` tags inside the
    /// groups Verovio's stylesheet names, so the flattener below can see them.
    ///
    /// It is done as a separate pass because the flattener works one `<text>`
    /// block at a time and a block does not know what encloses it.
    static func applyElementFaces(_ svg: String) -> String {
        guard let tagRe = RegexCache.regex(pattern: "<[^>]+>") else { return svg }
        let ns = svg as NSString
        // Appended as NSStrings and asked about as NSStrings: a dense page has
        // tens of thousands of tags, and turning each into a Swift String to
        // test its first two characters cost more than the matching.
        let out = NSMutableString(capacity: ns.length + 1024)
        var cursor = 0
        // one entry per OPEN <g>, so the face lifts again at its </g>
        var stack: [(italic: Bool, bold: Bool)] = []
        var italicDepth = 0
        var boldDepth = 0
        for match in tagRe.matches(in: svg, range: NSRange(location: 0, length: ns.length)) {
            out.append(ns.substring(with: NSRange(location: cursor,
                                                  length: match.range.location - cursor)))
            cursor = match.range.location + match.range.length
            let tag = ns.substring(with: match.range) as NSString
            if tag.hasPrefix("<g"), !tag.hasSuffix("/>") {
                let classes = Set(classes(of: tag as String))
                let italic = !classes.isDisjoint(with: italicClasses)
                let bold = !classes.isDisjoint(with: boldClasses)
                stack.append((italic, bold))
                if italic { italicDepth += 1 }
                if bold { boldDepth += 1 }
                out.append(tag as String)
            } else if tag.hasPrefix("</g"), let top = stack.popLast() {
                if top.italic { italicDepth -= 1 }
                if top.bold { boldDepth -= 1 }
                out.append(tag as String)
            } else if tag.hasPrefix("<text"), italicDepth > 0 || boldDepth > 0 {
                var stamped = tag as String
                if italicDepth > 0, !stamped.contains("font-style=") {
                    stamped = insert(#"font-style="italic""#, into: stamped)
                }
                if boldDepth > 0, !(tag as String).contains("font-weight=") {
                    stamped = insert(#"font-weight="bold""#, into: stamped)
                }
                out.append(stamped)
            } else {
                out.append(tag as String)
            }
        }
        out.append(ns.substring(from: cursor))
        return out as String
    }

    private static func classes(of tag: String) -> [String] {
        // cached: a `.regularExpression` search compiles its pattern per call,
        // and this is asked of every <g> on the page
        guard let re = RegexCache.regex(pattern: #"class="[^"]*""#),
              let m = re.firstMatch(in: tag, range: NSRange(location: 0,
                                                            length: (tag as NSString).length))
        else { return [] }
        return (tag as NSString).substring(with: m.range).dropFirst(7).dropLast()
            .split(separator: " ").map(String.init)
    }

    /// Put one more attribute inside an open tag, before its `>` or `/>`.
    private static func insert(_ attribute: String, into tag: String) -> String {
        guard tag.hasSuffix(">") else { return tag }
        let close = tag.hasSuffix("/>") ? "/>" : ">"
        return String(tag.dropLast(close.count)) + " " + attribute + close
    }

    /// Whether SwiftDraw will accept this font name.
    ///
    /// Its rule, copied here rather than guessed at: ask Core Text for the
    /// name, and take the font only if the PostScript name it hands back is
    /// the name that was asked for (or the family name is). Anything else
    /// falls back to plain Times WITHOUT SAYING SO -- which is how a face
    /// written correctly into the SVG can still be drawn upright.
    static func resolves(_ name: String) -> Bool {
        let font = CTFontCreateWithName(name as CFString, 12, nil)
        if (CTFontCopyPostScriptName(font) as String)
            .caseInsensitiveCompare(name) == .orderedSame { return true }
        return (CTFontCopyFamilyName(font) as String) == name
    }

    /// The candidates for each face, most specific first, and the reason there
    /// is more than one: `Times-Italic` is a macOS PostScript name and iOS does
    /// not have it -- iOS ships the Times New Roman faces instead. Writing the
    /// macOS name into the page produced no error and no italics, just the
    /// fallback. Whichever name the platform actually has is found once, here.
    static let faceCandidates: [String: [String]] = [
        "serif-italic": ["Times-Italic", "TimesNewRomanPS-ItalicMT"],
        "serif-bold": ["Times-Bold", "TimesNewRomanPS-BoldMT"],
        "serif-bolditalic": ["Times-BoldItalic", "TimesNewRomanPS-BoldItalicMT"],
        "sans-italic": ["Helvetica-Oblique", "ArialMT-Italic", "Arial-ItalicMT"],
        "sans-bold": ["Helvetica-Bold", "Arial-BoldMT"],
        "sans-bolditalic": ["Helvetica-BoldOblique", "Arial-BoldItalicMT"],
    ]

    /// The resolved name per face, computed once per process.
    static let faces: [String: String] = faceCandidates.compactMapValues { names in
        names.first(where: resolves)
    }

    /// The font name of the face, for the families whose faces we know.
    ///
    /// A family we do not know -- Leipzig, say -- is left exactly as it is
    /// rather than guessed at: an invented name costs nothing but also buys
    /// nothing, and a music font has no italic.
    static func face(for family: String?, italic: Bool, bold: Bool) -> String? {
        guard italic || bold else { return nil }
        let first = (family ?? "Times")
            .split(separator: ",").first.map(String.init)?
            .trimmingCharacters(in: CharacterSet(charactersIn: " '\"")) ?? "Times"
        let group: String
        switch first.lowercased() {
        case "times", "times-roman", "times new roman", "serif", "":
            group = "serif"
        case "helvetica", "arial", "sans-serif":
            group = "sans"
        default:
            return nil
        }
        let weight = italic && bold ? "bolditalic" : (italic ? "italic" : "bold")
        return faces["\(group)-\(weight)"]
    }

    // MARK: - Flattening

    /// Rewrite every <text> block (arbitrarily nested tspans) into flat
    /// <text> elements: one per positioned tspan, style attrs inherited from
    /// the tspan stack, unpositioned runs (chord accidentals) appended to the
    /// preceding positioned run.
    ///
    /// Verovio positions text two ways. Chord symbols repeat x/y on the inner
    /// tspan; staff labels, tuplet numbers and page numbers carry x/y on the
    /// enclosing <text> and leave every tspan unpositioned. Grouping only on a
    /// positioned tspan therefore discarded the whole second category -- which
    /// is why instrument names never reached the page. So a block opens with a
    /// group seeded from the <text> element itself, and a positioned tspan
    /// still starts a fresh one.
    ///
    /// Only x/y/text-anchor come from <text>: it also carries font-size="0px"
    /// (the real size lives on the inner tspan), and seeding that would emit
    /// correctly placed but invisible zero-height text.
    ///
    /// ONE GROUP IS ONE `<text>` AND SO CARRIES ONE SIZE. Which size that is
    /// is the question `dominant` answers, and answering it "the first run's"
    /// was a live bug: a tempo mark engraves as three runs -- a 720px glyph in
    /// the MUSIC font, then " = " and "138" at 405px in the text font -- so
    /// `♩. = 138` printed its digits at not far off double the size Verovio
    /// drew them, on every page that carried a tempo, for as long as this path
    /// has existed.
    ///
    /// The rule: A MUSIC GLYPH DOES NOT GET A VOTE. The size Verovio sets a
    /// Leipzig glyph in is the size of that glyph, not of the words beside it,
    /// and the same is true of a chord symbol's accidental. So the attributes
    /// come from the text runs, and only from the glyph runs when there is
    /// nothing else; among them the value the most characters carry wins, and
    /// a tie goes to the earlier run.
    static func flattenTextElements(_ svg: String) -> String {
        // TEMPERED: the span may not cross another <text opening.
        //
        // `<text[^>]*>.*?</text>` looks safe because it is non-greedy, but it
        // is only safe while every <text is closed. An UNCLOSED or self-closing
        // one -- OMR output has them -- makes the match start there and run to
        // the NEXT block's </text>, swallowing every <g>, <use> and <path>
        // between the two. Those elements are then dropped by the rewrite: on
        // the score that exposed this, 77 <use>, 127 <path> and 282 <g>
        // vanished, 43KB of drawing, and what was left would not parse. The
        // renderer reported it as "Verovio rendered an empty page", which is
        // how it stayed hidden -- the page was fine until we rewrote it.
        //
        // `(?:(?!<text[^>]*>).)*?` is the same non-greedy body that additionally
        // refuses to step over another opening tag.
        guard let blockRe = RegexCache.regex(
            pattern: "<text[^>]*[^/]>(?:(?!<text[^>]*>).)*?</text>",
            options: [.dotMatchesLineSeparators]),
            let tokenRe = RegexCache.regex(pattern: "<[^>]+>|[^<]+"),
            let attrRe = RegexCache.regex(pattern: #"([a-zA-Z-]+)="([^"]*)""#),
            let titleRe = RegexCache.regex(
                pattern: "<title[^>]*>.*?</title>", options: [.dotMatchesLineSeparators])
        else { return svg }

        let ns = svg as NSString
        // one buffer of the page's own UTF-16: the stretches between blocks
        // are most of the page, and transcoding each onto a Swift String was
        // the larger half of this pass
        let result = NSMutableString(capacity: ns.length)
        var cursor = 0
        for match in blockRe.matches(in: svg, range: NSRange(location: 0, length: ns.length)) {
            result.append(ns.substring(with: NSRange(location: cursor,
                                                     length: match.range.location - cursor)))
            var block = ns.substring(with: match.range)
            block = titleRe.stringByReplacingMatches(
                in: block, range: NSRange(location: 0, length: (block as NSString).length),
                withTemplate: "")

            var stack: [[String: String]] = []
            var out = ""
            var groupAttrs: [String: String]? = nil
            /// The runs of the open group: the text, and the font attributes
            /// in force where it was found. Resolved into ONE set at close.
            var runs: [(text: String, attrs: [String: String])] = []
            /// The face the enclosing element asks for (applyElementFaces).
            var blockFace: [String: String] = [:]

            func attrs(of tag: String) -> [String: String] {
                var d: [String: String] = [:]
                let t = tag as NSString
                for m in attrRe.matches(in: tag, range: NSRange(location: 0, length: t.length)) {
                    d[t.substring(with: m.range(at: 1))] = t.substring(with: m.range(at: 2))
                }
                return d
            }

            /// The value of `key` that the most CHARACTERS of the group are
            /// set in, ignoring the music-font runs. Runs carrying no value
            /// for it are counted too, and win by saying so: the family of
            /// `♩. = 138` is whatever the page inherits, not the Leipzig of
            /// its glyph.
            func dominant(_ key: String) -> (value: String?, chosen: Bool) {
                let words = runs.filter { !isMusicFont($0.attrs["font-family"]) }
                let voting = words.isEmpty ? runs : words
                var weight: [String: Int] = [:]
                var order: [String: Int] = [:]
                var absent = 0
                for (index, run) in voting.enumerated() {
                    let n = run.text.count
                    guard let v = run.attrs[key] else { absent += n; continue }
                    weight[v, default: 0] += n
                    if order[v] == nil { order[v] = index }
                }
                guard let best = weight.keys.max(by: {
                    (weight[$0]!, -order[$0]!) < (weight[$1]!, -order[$1]!)
                }) else { return (nil, false) }
                if absent > weight[best]! { return (nil, false) }
                return (best, true)
            }

            func closeGroup() {
                defer { groupAttrs = nil; runs = [] }
                guard var attributes = groupAttrs else { return }
                let text = runs.map(\.text).joined()
                guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                // THE SIZE FOLLOWS THE WORDS; THE FAMILY FOLLOWS THE GLYPHS.
                //
                // A notation glyph is a character in the private-use area and
                // only a music font has it. Take the family off the words and
                // the glyph is drawn as `.notdef` -- an empty box where the
                // note of a tempo mark should be, which is the shape the
                // accidental substitution above was written for. So a group
                // holding one keeps the family its glyph run asked for, and
                // takes its SIZE from the words all the same.
                let glyphs = text.unicodeScalars.contains { (0xE000...0xF8FF).contains($0.value) }
                for key in ["font-size", "font-weight", "font-style"] {
                    let resolved = dominant(key)
                    if resolved.chosen { attributes[key] = resolved.value }
                }
                if glyphs, let glyphRun = runs.first(where: {
                    isMusicFont($0.attrs["font-family"])
                }) {
                    attributes["font-family"] = glyphRun.attrs["font-family"]
                } else {
                    let resolved = dominant("font-family")
                    if resolved.chosen { attributes["font-family"] = resolved.value }
                }
                // the enclosing element's own face, where no run had one
                for (key, value) in blockFace where attributes[key] == nil {
                    attributes[key] = value
                }
                // ...and the face SwiftDraw can actually act on. Never over a
                // glyph: the weight of a tempo mark is worth less than its
                // note, and only the font that has the note may be named.
                // Drawing the metronome glyph ourselves -- the way the whistle
                // circles and the chord grids already are -- is what would buy
                // both.
                if !glyphs,
                   let named = face(for: attributes["font-family"],
                                    italic: attributes["font-style"] == "italic"
                                        || attributes["font-style"] == "oblique",
                                    bold: isBold(attributes["font-weight"])) {
                    attributes["font-family"] = named
                }
                let rendered = attributes.map { " \($0.key)=\"\($0.value)\"" }.sorted().joined()
                out += "<text\(rendered)>\(text)</text>"
            }

            let blockNS = block as NSString

            // seed from the <text> open tag, so text that never meets a
            // positioned tspan still has somewhere to land
            if let openRe = RegexCache.regex(pattern: "<text[^>]*>"),
               let openTag = openRe.firstMatch(in: block, range: NSRange(location: 0,
                                                                         length: blockNS.length)) {
                let a = attrs(of: blockNS.substring(with: openTag.range))
                for key in ["font-style", "font-weight"] { blockFace[key] = a[key] }
                blockFace = blockFace.compactMapValues { $0 }
                if a["x"] != nil {
                    var g: [String: String] = [:]
                    for key in ["x", "y", "text-anchor"] { g[key] = a[key] }
                    groupAttrs = g.compactMapValues { $0 }
                }
            }

            for tok in tokenRe.matches(in: block,
                                       range: NSRange(location: 0, length: blockNS.length)) {
                let token = blockNS.substring(with: tok.range)
                if token.hasPrefix("<tspan") {
                    let a = attrs(of: token)
                    stack.append(a)
                    if a["x"] != nil {
                        closeGroup()
                        var g: [String: String] = [:]
                        for key in ["x", "y", "text-anchor"] { g[key] = a[key] }
                        groupAttrs = g.compactMapValues { $0 }
                    }
                } else if token.hasPrefix("</tspan") {
                    if !stack.isEmpty { stack.removeLast() }
                } else if !token.hasPrefix("<") {
                    let text = token.replacingOccurrences(of: "\n", with: " ")
                        .trimmingCharacters(in: .whitespaces)
                    if !text.isEmpty, groupAttrs != nil {
                        var inherited: [String: String] = [:]
                        for key in ["font-size", "font-family", "font-weight", "font-style"] {
                            for level in stack.reversed() {
                                if let v = level[key],
                                   !(key == "font-size" && (v == "0px" || v == "0")) {
                                    inherited[key] = v
                                    break
                                }
                            }
                        }
                        runs.append((text, inherited))
                    }
                }
            }
            closeGroup()
            result.append(out)
            cursor = match.range.location + match.range.length
        }
        result.append(ns.substring(from: cursor))
        return result as String
    }

    /// The fonts Verovio sets NOTATION in. A run in one of them is a glyph
    /// rather than a word, so it does not decide how the words around it are
    /// sized -- see `flattenTextElements`.
    static let musicFonts: Set<String> = ["leipzig", "veroviotext", "bravura",
                                          "bravuratext", "smufl", "gootville",
                                          "gootvilletext", "petaluma",
                                          "petalumatext", "leland", "lelandtext"]

    static func isMusicFont(_ family: String?) -> Bool {
        guard let family else { return false }
        return family.split(separator: ",").contains {
            musicFonts.contains($0.trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
                .lowercased())
        }
    }

    /// SVG allows a weight as a keyword or a number; 600 and up is bold.
    private static func isBold(_ weight: String?) -> Bool {
        guard let weight else { return false }
        if weight == "bold" || weight == "bolder" { return true }
        return (Int(weight) ?? 0) >= 600
    }
}
