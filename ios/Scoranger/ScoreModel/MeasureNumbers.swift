import Foundation

/// Which bars the page numbers (0.17.0).
///
/// Written by `ops.measure_numbers` into the notation as
/// `<miscellaneous-field name="scoranger-measure-numbers">every=3</…>` and read
/// here and by `render.measure_numbers_from_musicxml`, which must stay in step
/// -- engine/scripts/check_measure_numbers.py reads this file and holds it to
/// the engine's constants.
///
///     (no field)   the first bar of each line but the first: Verovio's
///                  default, `mnumInterval` 0
///     every=N      every Nth bar: `mnumInterval` N
///     none         no numbers. Verovio has no OPTION for that; it reads MEI's
///                  `mnum.visible="false"` on the score definition, which
///                  `meiHidingNumbers` writes before the document is reloaded.
///
/// Pure, with no Verovio and no file access, so it compiles into the
/// host-less test bundle.
enum MeasureNumbers {

    enum Mode: Equatable {
        case system
        case every(Int)
        case none
    }

    static let field = "scoranger-measure-numbers"
    /// Verovio's accepted `mnumInterval`. Mirrors render.MEASURE_NUMBERS_EVERY_RANGE.
    static let everyRange = 1...64

    /// The score's numbering, or the default for anything unreadable: a page
    /// must draw whatever the field says. The op is the strict side.
    static func mode(inMusicXML xml: String) -> Mode {
        let pattern = "<miscellaneous-field[^>]*name=\"\(field)\"[^>]*>([^<]*)</miscellaneous-field>"
        guard let re = try? NSRegularExpression(pattern: pattern),
              let match = re.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              let range = Range(match.range(at: 1), in: xml) else {
            return .system
        }
        return mode(field: String(xml[range]))
    }

    /// The field's own text -- the same parse `render.parse_measure_numbers` does.
    static func mode(field text: String) -> Mode {
        let value = text.trimmingCharacters(in: .whitespaces)
        if value == "none" { return .none }
        let pair = value.split(separator: "=", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if pair.count == 2, pair[0] == "every", let n = Int(pair[1]), everyRange.contains(n) {
            return .every(n)
        }
        return .system
    }

    /// Verovio's `mnumInterval`. Named in EVERY option set (EngravingOptions):
    /// setOptions merges, and one score's numbering would be the next score's.
    static func interval(_ mode: Mode) -> Int {
        if case .every(let n) = mode { return n }
        return 0
    }

    /// `mnum.visible="false"` on the first score definition, or nil when there
    /// is nothing to change. The same rewrite as render.mei_with_measure_numbers_hidden.
    static func meiHidingNumbers(_ mei: String) -> String? {
        guard let tagRange = mei.range(of: "<scoreDef\\b[^>]*>", options: .regularExpression) else {
            return nil
        }
        var tag = String(mei[tagRange])
        if tag.contains("mnum.visible=\"false\"") { return nil }
        tag = tag.replacingOccurrences(of: "\\smnum\\.visible=\"[^\"]*\"", with: "",
                                       options: .regularExpression)
        let opened = tag.hasSuffix("/>")
            ? String(tag.dropLast(2)) + " mnum.visible=\"false\"/>"
            : String(tag.dropLast()) + " mnum.visible=\"false\">"
        return mei.replacingCharacters(in: tagRange, with: opened)
    }
}
