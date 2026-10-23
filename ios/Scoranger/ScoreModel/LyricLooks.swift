import CoreGraphics
import Foundation

/// How big a sung word is drawn and how it is set, carried from its verse name
/// onto the iPad's own pages (0.21.0).
///
/// `adjust-element --kind lyric` writes a word's size and style into its verse
/// NAME -- `ly@1.5`, `ly~i`, `ly@1.5~bi` -- because MusicXML has no font on a
/// `<lyric>` that music21 round-trips (ops.LYRIC_LABEL_TAG). Verovio carries the
/// name onto the page as the verse group's labelAttr title, so the size and
/// style arrive WITH the word: nothing is counted or matched by order, which is
/// what makes this safe for the kind that runs to hundreds per score.
///
/// Before this a resized word was resized in a PDF export and nowhere else
/// (BACKLOG, "Deferred from 0.11.0"). Mirrors render.apply_lyric_sizes.
enum LyricLooks {

    struct Look: Equatable {
        /// Size as a multiple of the engraved default; nil leaves it.
        var scale: CGFloat?
        var italic = false
        var bold = false

        var isPlain: Bool { scale == nil && !italic && !bold }
    }

    /// What a verse name says about its word, or nil when it is not a word's
    /// name or says nothing -- a plain verse number, a whistle's `wf`, a
    /// tab's `gt@...`.
    static func look(label: String) -> Look? {
        guard label.hasPrefix("ly") else { return nil }
        let parts = label.split(separator: "~", maxSplits: 1, omittingEmptySubsequences: false)
        let head = String(parts[0])
        let style = parts.count > 1 ? String(parts[1]) : ""
        var look = Look()
        if head.hasPrefix("ly@") {
            let first = head.dropFirst(3).split(separator: ",", omittingEmptySubsequences: false).first
            if let first, let value = Double(first), value > 0 { look.scale = CGFloat(value) }
        } else if head != "ly" {
            return nil
        }
        look.italic = style.contains("i")
        look.bold = style.contains("b")
        return look.isPlain ? nil : look
    }

    private static let verseRE = RegexCache.regex(
        pattern: #"<g[^>]*class="verse">.*?</g>\s*</g>"#, options: [.dotMatchesLineSeparators])
    private static let labelRE = RegexCache.regex(
        pattern: #"<title class="labelAttr">([^<]*)</title>"#)
    private static let sizeRE = RegexCache.regex(
        pattern: #"(<tspan[^>]*font-size=")([\d.]+)(px")"#)
    private static let textRE = RegexCache.regex(pattern: #"<text\b[^>]*>"#)

    /// Every word on a page drawn at its own size and in its own style.
    static func apply(to svg: String) -> String {
        // A look needs a verse name starting "ly" (`look(label:)`), and Verovio
        // writes the name as the verse's labelAttr title -- so a page without
        // that literal has nothing to restyle. "ly" alone is in every page's
        // `font-family`.
        guard TextSearch.contains(svg, "<title class=\"labelAttr\">ly"),
              let verseRE, let labelRE else { return svg }
        let ns = svg as NSString
        var out = ""
        var cursor = 0
        for match in verseRE.matches(in: svg, range: NSRange(location: 0, length: ns.length)) {
            let block = ns.substring(with: match.range)
            let b = block as NSString
            guard let title = labelRE.firstMatch(in: block, range: NSRange(location: 0, length: b.length)),
                  let look = look(label: b.substring(with: title.range(at: 1))) else { continue }
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            out += restyled(block, look: look)
            cursor = match.range.location + match.range.length
        }
        guard cursor > 0 else { return svg }
        out += ns.substring(from: cursor)
        return out
    }

    private static func restyled(_ block: String, look: Look) -> String {
        var out = block
        if let scale = look.scale, let sizeRE {
            let o = out as NSString
            if let size = sizeRE.firstMatch(in: out, range: NSRange(location: 0, length: o.length)),
               let base = Double(o.substring(with: size.range(at: 2))), base > 0 {
                out = o.replacingCharacters(
                    in: size.range,
                    with: o.substring(with: size.range(at: 1))
                        + String(format: "%g", base * Double(scale))
                        + o.substring(with: size.range(at: 3)))
            }
        }
        if look.italic || look.bold, let textRE {
            let o = out as NSString
            if let text = textRE.firstMatch(in: out, range: NSRange(location: 0, length: o.length)) {
                var tag = o.substring(with: text.range)
                let close = tag.hasSuffix("/>") ? "/>" : ">"
                tag.removeLast(close.count)
                if look.italic, !tag.contains("font-style=") { tag += #" font-style="italic""# }
                if look.bold, !tag.contains("font-weight=") { tag += #" font-weight="bold""# }
                out = o.replacingCharacters(in: text.range, with: tag + close)
            }
        }
        return out
    }

    /// Each word's stored size, by its MEI id, so the adjust row starts from
    /// the size the word already has rather than from the default.
    static func scales(inMEI mei: String) -> [String: CGFloat] {
        guard let verse = RegexCache.regex(pattern: #"<verse\b[^>]*>"#),
              let id = RegexCache.regex(pattern: #"xml:id="([^"]+)""#),
              let label = RegexCache.regex(pattern: #"\blabel="([^"]*)""#)
        else { return [:] }
        // a scale needs a verse named "ly@..."; see `apply`
        guard TextSearch.contains(mei, "label=\"ly") else { return [:] }
        let ns = mei as NSString
        var out: [String: CGFloat] = [:]
        for match in verse.matches(in: mei, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: match.range)
            let t = tag as NSString
            let all = NSRange(location: 0, length: t.length)
            guard let i = id.firstMatch(in: tag, range: all),
                  let l = label.firstMatch(in: tag, range: all),
                  let scale = look(label: t.substring(with: l.range(at: 1)))?.scale else { continue }
            out[t.substring(with: i.range(at: 1))] = scale
        }
        return out
    }
}
