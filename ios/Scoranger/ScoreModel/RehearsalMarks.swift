import Foundation

/// Rehearsal marks, on the render side.
///
/// The engine writes a mark to EVERY part, so an extracted part a player reads
/// from carries its own (`ops.set_rehearsal`). Verovio renders the direction
/// from each part and, in a COMBINED score, anchors them all to the same
/// staff -- so a four-part score draws the same letter over itself four times.
/// This keeps the first of each (measure, letter) and drops the rest.
///
/// A single part already has one of each, so this is a no-op there; that is
/// what lets one render path serve the score and the parts.
///
/// The Python renderer does the same thing in
/// `render.mei_with_deduped_rehearsals`, and the two must stay in step -- the
/// export and the screen have to agree about what is on the page.
enum RehearsalMarks {
    /// Nil when nothing was dropped, so the caller can skip a reload.
    static func meiWithDedupedMarks(_ mei: String) -> String? {
        guard let element = RegexCache.regex(
            pattern: "<reh\\b[^>]*(?:/>|>.*?</reh>)",
            options: [.dotMatchesLineSeparators]) else { return nil }
        let text = mei as NSString
        let matches = element.matches(in: mei, range: NSRange(location: 0, length: text.length))
        guard matches.count > 1 else { return nil }

        var kept = Set<String>()
        var out = ""
        var position = 0
        var dropped = false
        for match in matches {
            let range = match.range
            let key = barKey(text, before: range.location) + "\u{1}" + label(text.substring(with: range))
            if kept.contains(key) {
                out += text.substring(with: NSRange(location: position, length: range.location - position))
                position = range.location + range.length
                dropped = true
            } else {
                kept.insert(key)
            }
        }
        guard dropped else { return nil }
        out += text.substring(from: position)
        return out
    }

    /// Which bar an element sits in: the `n` of the nearest `<measure` before it.
    private static func barKey(_ mei: NSString, before index: Int) -> String {
        let head = mei.substring(to: index)
        guard let start = head.range(of: "<measure", options: .backwards) else {
            return "?"
        }
        let tail = head[start.lowerBound...].prefix(200)
        guard let n = tail.range(of: "n=\"") else { return "?" }
        let rest = tail[n.upperBound...]
        return String(rest.prefix(while: { $0 != "\"" }))
    }

    /// The letter, with the markup taken off.
    private static func label(_ element: String) -> String {
        element.replacingOccurrences(of: "<[^>]+>", with: "",
                                     options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
