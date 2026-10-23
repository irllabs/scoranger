import CoreGraphics
import Foundation

/// Carries an added element's size and position from the notation onto the page.
///
/// The user's adjustment lives in the MusicXML — `font-size`, `relative-x` and
/// `relative-y` — because that is standard, portable, and travels with the
/// score. What it does not do is reach Verovio: its MusicXML importer drops all
/// three, measured, so they have to be carried across here.
///
/// Position becomes MEI `@ho`/`@vo`, which Verovio honours per element. Size is
/// applied to the rendered SVG afterwards, because Verovio has no per-element
/// text size at all — `@fontsize` is ignored as a percentage and as a keyword.
///
/// ## Five kinds, not one
///
/// This carried CHORD SYMBOLS alone for as long as `adjust-element` reached
/// only chord symbols. 0.8.2 generalised the op past them and the values then
/// went into the file correctly and reached neither engraver: a dynamic, a text
/// mark, a fermata and an articulation each carry the same three attributes and
/// Verovio drops every one of them the same way.
///
/// ## Which way is up
///
/// MusicXML's `relative-y` measures UP and so does MEI's `@vo`, on all five.
/// That was measured -- the same bar engraved with and without an offset, with
/// the rendered y read back -- and `check_adjust.py` asserts it rather than
/// describing it. This file used to NEGATE its `@vo`, on the belief that
/// `<harm>` was the exception; it is not, and the consequence was that the
/// adjust row's "up" arrow moved a chord symbol down the page.
///
/// It lives in `ScoreModel/` because it is pure string work over Verovio's
/// output and belongs where the host-less suite can reach it.
///
/// Mirrors engine/scoranger_engine/render.py; keep the two in step.
enum ChordAdjustments {
    /// One element's adjustment, or nothing where the user left it alone.
    struct Adjustment: Equatable {
        var size: CGFloat?
        var dx: CGFloat?
        var dy: CGFloat?

        var isEmpty: Bool { size == nil && dx == nil && dy == nil }
    }

    /// What an adjustment can be written onto, and how each renderer finds it.
    ///
    /// `diagram` is deliberately absent: a chord diagram is drawn by US rather
    /// than by Verovio, so its three numbers ride in the label
    /// `ChordDiagrams.meiWithDiagrams` writes, and `ChordDiagrams` places it.
    enum Kind: String, CaseIterable {
        case harm, dynamic, text, fermata, articulation

        /// The MEI element Verovio writes it as.
        var meiTag: String {
            switch self {
            case .harm: return "harm"
            case .dynamic: return "dynam"
            case .text: return "dir"
            case .fermata: return "fermata"
            case .articulation: return "artic"
            }
        }

        /// The class of the SVG group it is drawn in.
        var svgClass: String { meiTag }

        /// Whether Verovio draws it as TEXT (a `<tspan font-size>`) or as a
        /// GLYPH (a `<use>` with a scale in its transform). There is no other
        /// handle on a glyph's size at all.
        var drawnAsText: Bool { self == .harm || self == .text }
    }

    /// The point size an added element engraves at untouched, so a stored
    /// absolute size can be expressed as a ratio of the drawn glyph.
    /// Mirrors ops.DEFAULT_ELEMENT_POINTS and render.DEFAULT_CHORD_POINTS.
    static let defaultChordPoints: CGFloat = 12
    /// MEI counts half-spaces; MusicXML counts tenths of a staff space.
    static let tenthsToHalfSpaces: CGFloat = 0.2

    // MARK: - Reading the notation

    /// Every chord symbol's adjustment, in document order — the order the MEI
    /// and the SVG present them in, which is what lets them be matched up
    /// without inventing an identity scheme.
    static func adjustments(inMusicXML xml: String) -> [Adjustment] {
        adjustments(inMusicXML: xml, kind: .harm)
    }

    /// Every element of one kind, with its adjustment, in document order.
    static func adjustments(inMusicXML xml: String, kind: Kind) -> [Adjustment] {
        tags(inMusicXML: xml, kind: kind).map {
            Adjustment(size: number("font-size", in: $0),
                       dx: number("relative-x", in: $0),
                       dy: number("relative-y", in: $0))
        }
    }

    /// Every kind at once, which is what a render pass needs.
    static func allAdjustments(inMusicXML xml: String) -> [Kind: [Adjustment]] {
        var out: [Kind: [Adjustment]] = [:]
        for kind in Kind.allCases {
            out[kind] = adjustments(inMusicXML: xml, kind: kind)
        }
        return out
    }

    /// The open tags of one kind of adjustable element, in document order.
    private static func tags(inMusicXML xml: String, kind: Kind) -> [String] {
        let ns = xml as NSString
        let whole = NSRange(location: 0, length: ns.length)
        func all(_ pattern: String) -> [String] {
            guard let re = RegexCache.regex(pattern: pattern) else { return [] }
            return re.matches(in: xml, range: whole).map { ns.substring(with: $0.range) }
        }
        switch kind {
        case .harm: return all("<harmony\\b[^>]*>")
        case .dynamic: return all("<dynamics\\b[^>]*>")
        case .fermata: return all("<fermata\\b[^>]*>")
        case .text:
            // a chord DIAGRAM rides in a <words> too, and ChordDiagrams carries
            // its three numbers -- we draw diagrams, Verovio does not
            guard let re = RegexCache.regex(
                pattern: "<words\\b([^>]*)>([^<]*)</words>") else { return [] }
            return re.matches(in: xml, range: whole).compactMap { m in
                ChordDiagrams.parseShape(ns.substring(with: m.range(at: 2))) == nil
                    ? "<words" + ns.substring(with: m.range(at: 1)) + ">" : nil
            }
        case .articulation:
            guard let blockRE = RegexCache.regex(
                    pattern: "<articulations\\b[^>]*>(.*?)</articulations>",
                    options: [.dotMatchesLineSeparators]),
                  let childRE = RegexCache.regex(pattern: "<[a-z-]+\\b[^>]*/?>")
            else { return [] }
            return blockRE.matches(in: xml, range: whole).flatMap { m -> [String] in
                let block = ns.substring(with: m.range(at: 1))
                let inner = block as NSString
                return childRE.matches(
                    in: block, range: NSRange(location: 0, length: inner.length)
                ).map { inner.substring(with: $0.range) }
            }
        }
    }

    // MARK: - Position, into the MEI

    /// Put each chord symbol's offset into the MEI, or nil when none has one.
    static func meiWithAdjustments(_ mei: String, adjustments: [Adjustment]) -> String? {
        meiWithAdjustments(mei, byKind: [.harm: adjustments])
    }

    /// Put every element's offset into the MEI, or nil when none has one.
    static func meiWithAdjustments(_ mei: String,
                                   byKind: [Kind: [Adjustment]]) -> String? {
        var out = mei
        var touched = false
        for kind in Kind.allCases {
            let adjustments = byKind[kind] ?? []
            guard adjustments.contains(where: { $0.dx != nil || $0.dy != nil })
            else { continue }
            out = placed(out, kind: kind, adjustments: adjustments)
            touched = true
        }
        return touched ? out : nil
    }

    private static func placed(_ mei: String, kind: Kind,
                               adjustments: [Adjustment]) -> String {
        // A <dir> is matched WITH its body, because a chord diagram is a <dir>
        // too and ChordDiagrams places those -- matching them here would move
        // them twice.
        let pattern = kind == .text ? "<dir\\b[^>]*>([^<]*)" : "<\(kind.meiTag)\\b"
        guard let re = RegexCache.regex(pattern: pattern) else { return mei }

        let ns = mei as NSString
        var out = ""
        var cursor = 0
        var index = 0
        for match in re.matches(in: mei, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor,
                                              length: match.range.location - cursor))
            cursor = match.range.location + match.range.length
            let whole = ns.substring(with: match.range)
            if kind == .text, match.numberOfRanges > 1,
               ChordDiagrams.parseShape(ns.substring(with: match.range(at: 1))) != nil {
                out += whole                    // a diagram marker: not ours
                continue
            }
            var attributes = ""
            if index < adjustments.count {
                let adjustment = adjustments[index]
                if let dx = adjustment.dx {
                    attributes += " ho=\"\(dx * tenthsToHalfSpaces)\""
                }
                if let dy = adjustment.dy {
                    attributes += " vo=\"\(dy * tenthsToHalfSpaces)\""
                }
            }
            index += 1
            if attributes.isEmpty {
                out += whole
            } else if kind == .text, let close = whole.firstIndex(of: ">") {
                out += whole[whole.startIndex..<close] + attributes
                    + whole[close...]
            } else {
                out += whole + attributes
            }
        }
        out += ns.substring(from: cursor)
        return out
    }

    // MARK: - Size, into the drawn page

    /// Rescale each adjusted chord symbol in the rendered SVG.
    static func applySizes(_ svg: String, adjustments: [Adjustment]) -> String {
        applySizes(svg, byKind: [.harm: adjustments])
    }

    /// Rescale every adjusted element in the rendered SVG.
    ///
    /// A chord symbol's size lives on the INNER tspan, and that tspan carries x
    /// and y AFTER its font-size — the enclosing `<text>` is `font-size="0px"`.
    /// Reading the wrong one is what once drew every fingering circle with a
    /// radius of zero.
    static func applySizes(_ svg: String, byKind: [Kind: [Adjustment]]) -> String {
        var out = svg
        for kind in Kind.allCases {
            let adjustments = byKind[kind] ?? []
            guard adjustments.contains(where: { $0.size != nil }) else { continue }
            out = sized(out, kind: kind, adjustments: adjustments)
        }
        return out
    }

    private static func sized(_ svg: String, kind: Kind,
                              adjustments: [Adjustment]) -> String {
        // A TEXT block is two groups deep (<g class><text><tspan>); a GLYPH
        // block is a LEAF -- one <g> holding one <use>. Reading a leaf with the
        // text pattern runs past its own </g> into the next element's drawing,
        // which is how a resized dynamic would have scaled the notehead beside
        // it.
        let pattern = kind.drawnAsText
            ? "<g[^>]*class=\"\(kind.svgClass)\".*?</g>\\s*</g>"
            : "<g[^>]*class=\"\(kind.svgClass)\"[^>]*>(?:(?!<g\\b).)*?</g>"
        guard let blockRE = RegexCache.regex(
                pattern: pattern, options: [.dotMatchesLineSeparators]),
              let sizeRE = RegexCache.regex(
                pattern: "(<tspan[^>]*font-size=\")([0-9.]+)(px\")"),
              let scaleRE = RegexCache.regex(
                pattern: "(transform=\"translate\\([^)]*\\)\\s*scale\\()([0-9.]+),\\s*([0-9.]+)(\\))")
        else { return svg }

        let ns = svg as NSString
        var out = ""
        var cursor = 0
        var index = 0
        for match in blockRE.matches(in: svg, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor,
                                              length: match.range.location - cursor))
            cursor = match.range.location + match.range.length
            var block = ns.substring(with: match.range)
            // a chord DIAGRAM is a <dir> too, and its size rides in its label
            if kind == .text, ChordDiagrams.parseShape(block) != nil {
                out += block
                continue
            }
            if index < adjustments.count, let wanted = adjustments[index].size {
                let ratio = wanted / defaultChordPoints
                block = kind.drawnAsText
                    ? resizedText(block, ratio: ratio, sizeRE)
                    : resizedGlyph(block, ratio: ratio, scaleRE)
            }
            index += 1
            out += block
        }
        out += ns.substring(from: cursor)
        return out
    }

    private static func resizedText(_ block: String, ratio: CGFloat,
                                    _ sizeRE: NSRegularExpression) -> String {
        let ns = block as NSString
        guard let hit = sizeRE.firstMatch(
                in: block, range: NSRange(location: 0, length: ns.length)),
              hit.numberOfRanges > 3,
              let drawn = Double(ns.substring(with: hit.range(at: 2))), drawn > 0
        else { return block }
        let replacement = ns.substring(with: hit.range(at: 1))
            + "\(CGFloat(drawn) * ratio)"
            + ns.substring(with: hit.range(at: 3))
        return ns.replacingCharacters(in: hit.range, with: replacement)
    }

    /// Grow or shrink a drawn glyph, ABOUT ITS OWN ORIGIN.
    ///
    /// A `<use>` carries `translate(x, y) scale(k, k)`, and the translate is
    /// the glyph's anchor — the note it hangs off, the baseline it sits on.
    /// Scaling the k's and leaving the translate alone grows the mark without
    /// moving the point it is attached to, which is the only behaviour that
    /// keeps a resized fermata over its note.
    private static func resizedGlyph(_ block: String, ratio: CGFloat,
                                     _ scaleRE: NSRegularExpression) -> String {
        let ns = block as NSString
        var out = block
        for hit in scaleRE.matches(
            in: block, range: NSRange(location: 0, length: ns.length)).reversed()
        where hit.numberOfRanges > 4 {
            guard let x = Double(ns.substring(with: hit.range(at: 2))),
                  let y = Double(ns.substring(with: hit.range(at: 3))) else { continue }
            let replacement = ns.substring(with: hit.range(at: 1))
                + "\(CGFloat(x) * ratio), \(CGFloat(y) * ratio)"
                + ns.substring(with: hit.range(at: 4))
            out = (out as NSString).replacingCharacters(in: hit.range, with: replacement)
        }
        return out
    }

    private static func number(_ attribute: String, in tag: String) -> CGFloat? {
        guard let re = RegexCache.regex(pattern: "\(attribute)=\"([-0-9.]+)\""),
              let m = re.firstMatch(in: tag,
                                    range: NSRange(location: 0, length: (tag as NSString).length)),
              m.numberOfRanges > 1,
              let value = Double((tag as NSString).substring(with: m.range(at: 1)))
        else { return nil }
        return CGFloat(value)
    }
}
