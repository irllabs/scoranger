import Foundation

/// How much room a score's page gives: between staves, between systems, and to
/// a whistle's fingering column.
///
/// Written by `ops.staff_spacing` into the notation as
/// `<miscellaneous-field name="scoranger-spacing">staff=12;system=4;rows=3</…>`
/// and read here and by `render.spacing_from_musicxml`, which must stay in
/// step -- engine/scripts/check_staff_spacing.py reads this file's constants
/// and holds them to the engine's.
///
/// A field rather than MusicXML's own `<staff-layout>`/`<system-layout>`:
/// music21 writes those correctly and Verovio ignores both at every value, so
/// the spacing is carried to the renderer as Verovio OPTIONS, by us.
///
/// Pure, with no Verovio and no file access, so it compiles into the
/// host-less test bundle.
enum StaffSpacing {

    struct Values: Equatable {
        /// Verovio's `spacingStaff`: the MINIMUM space between staves of one
        /// system, in MEI units. A minimum opens space up; it cannot take back
        /// space the music itself claims.
        var staff: Int
        /// Verovio's `spacingSystem`: the minimum space between systems.
        var system: Int
        /// Lyric rows reserved for a whistle column's six holes; the octave
        /// "+" gets one more, only on the notes that carry it.
        var rows: Int
    }

    static let field = "scoranger-spacing"
    static let defaultStaff = 12      // Verovio's own defaults, so a score
    static let defaultSystem = 4      // nobody has spaced is laid out as before
    static let spacingRange = 0...48  // Verovio's accepted range for both
    /// Four is the tightest the drawn column fits inside the band it reserves
    /// -- three put the top hole into the margin toward the system above, which
    /// check_render.py refuses (render.DEFAULT_FINGERING_ROWS has the numbers).
    /// Six is the layout every build before 0.13.0 drew. Ali: "too much space
    /// above penny whistle tablatures, so scores that have it end up fitting
    /// very few lines".
    static let defaultRows = 4
    static let rowsRange = 4...6

    static let defaults = Values(staff: defaultStaff, system: defaultSystem, rows: defaultRows)

    /// The score's spacing, or the defaults for anything it does not set.
    ///
    /// Lenient: an unreadable or out-of-range value falls back to its default
    /// rather than stopping a page from drawing. The op is the strict side.
    static func values(inMusicXML xml: String) -> Values {
        let pattern = "<miscellaneous-field[^>]*name=\"\(field)\"[^>]*>([^<]*)</miscellaneous-field>"
        guard let re = RegexCache.regex(pattern: pattern),
              let match = re.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              let range = Range(match.range(at: 1), in: xml) else {
            return defaults
        }
        return values(field: String(xml[range]))
    }

    /// The field's own text as values -- the same parse `render.parse_spacing_value` does.
    static func values(field text: String) -> Values {
        var out = defaults
        for part in text.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard pair.count == 2, let number = Int(pair[1]) else { continue }
            switch pair[0] {
            case "staff" where spacingRange.contains(number): out.staff = number
            case "system" where spacingRange.contains(number): out.system = number
            case "rows" where rowsRange.contains(number): out.rows = number
            default: continue
            }
        }
        return out
    }
}
