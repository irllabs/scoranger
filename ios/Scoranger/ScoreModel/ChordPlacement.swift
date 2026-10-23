import Foundation

/// Where a chord symbol sits, decided by the notation rather than the renderer.
///
/// The bug this exists to remove: `render.py` stamped the Real Book treatment
/// — name on the staff, centred in the bar, bold — onto EVERY score that had a
/// chord symbol, while the in-app renderer stamped nothing at all. The same
/// file therefore drew its chord names in two different places, and "move it up
/// half a space" would have meant one thing on screen and another in the PDF.
///
/// The rule is the one the rhythm work landed on: correctness belongs in the
/// notation, not in each renderer. `chart_style` records the intent as
/// `placement="below"` plus a `default-y` on each `<harmony>`; both renderers
/// read it and neither decides.
///
/// Mirrors `mei_with_chart_styling` in engine/scoranger_engine/render.py; keep
/// the two in step.
enum ChordPlacement {

    /// Whether each chord symbol asks to sit ON the staff, in document order —
    /// the order the MEI presents them in, which is what lets the two be
    /// matched without inventing an identity scheme.
    static func onStaffFlags(inMusicXML xml: String) -> [Bool] {
        guard let tagRE = RegexCache.regex(pattern: "<harmony\\b[^>]*>") else { return [] }
        let ns = xml as NSString
        return tagRE.matches(in: xml, range: NSRange(location: 0, length: ns.length))
            .map { match in
                let tag = ns.substring(with: match.range)
                return tag.contains("placement=\"below\"") && tag.contains("default-y=")
            }
    }

    /// The beat a centred symbol sits on, for a bar of `count` beats.
    ///
    /// Verovio counts `tstamp` from 1, so a 4/4 bar centres at 2.5 rather than
    /// at 2. Getting this wrong puts every chord name a beat early.
    static func centredTimestamp(beatsPerBar: Int) -> Double {
        (Double(beatsPerBar) + 1) / 2
    }

    /// Apply the treatment to the symbols that asked for it, and only those.
    ///
    /// Returns nil when none asks, so the caller can skip a Verovio reload.
    static func meiWithChartStyling(_ mei: String, onStaff flags: [Bool]) -> String? {
        guard flags.contains(true),
              let harmRE = RegexCache.regex(pattern: "<harm\\b[^>]*>")
        else { return nil }

        let beats = beatsPerBar(in: mei)
        let ns = mei as NSString
        var out = ""
        var cursor = 0
        var index = 0
        for match in harmRE.matches(in: mei, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor,
                                              length: match.range.location - cursor))
            var tag = ns.substring(with: match.range)
            if index < flags.count, flags[index] {
                tag = replacing("place", in: tag, with: "within")
                if let beats {
                    let centre = centredTimestamp(beatsPerBar: beats)
                    tag = replacing("tstamp", in: tag,
                                    with: trimmed(centre))
                }
            }
            out += tag
            index += 1
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// The bar length, read off whichever meter the MEI carries.
    static func beatsPerBar(in mei: String) -> Int? {
        for pattern in ["<meterSig[^>]*\\bcount=\"(\\d+)\"", "meter\\.count=\"(\\d+)\""] {
            guard let re = RegexCache.regex(pattern: pattern) else { continue }
            let ns = mei as NSString
            if let hit = re.firstMatch(in: mei, range: NSRange(location: 0, length: ns.length)),
               hit.numberOfRanges > 1,
               let value = Int(ns.substring(with: hit.range(at: 1))) {
                return value
            }
        }
        return nil
    }

    /// Set an attribute on a tag, replacing any existing value.
    private static func replacing(_ attribute: String, in tag: String,
                                  with value: String) -> String {
        guard let re = RegexCache.regex(pattern: "\\s\(attribute)=\"[^\"]*\"")
        else { return tag }
        let ns = tag as NSString
        let stripped = re.stringByReplacingMatches(
            in: tag, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        guard let insert = stripped.range(of: "<harm") else { return stripped }
        return stripped.replacingCharacters(
            in: insert, with: "<harm \(attribute)=\"\(value)\"")
    }

    /// `2.5`, not `2.5000` — the MEI is read by people as well as by Verovio.
    private static func trimmed(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
