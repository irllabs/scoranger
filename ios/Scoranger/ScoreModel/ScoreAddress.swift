import Foundation

/// What kind of musical thing an element is, as far as selection cares.
///
/// Backed by the class Verovio puts on the SVG group and by the MEI tag name,
/// which agree for everything we index.
enum ScoreElementKind: String, Codable, Hashable, CaseIterable {
    case note, chord, rest, measure, harm, clef, accid, slur, tie
    case dynam, fermata, articulation, beam, staff, layer
    /// A text mark -- "dolce", "rit." -- which MEI calls a `<dir>`. Added last
    /// so every other raw value keeps the string it is already persisted as.
    case text
    /// A sung word: one verse under one note (0.21.0). Its ordinal is the
    /// ENGINE's -- every word of the bar on that staff, note by note and then
    /// verse by verse -- not a count within one layer: see MEISemanticsParser.
    case verse

    /// Kinds a "notes" selection should return.
    static let noteLike: Set<ScoreElementKind> = [.note, .chord, .rest]
    /// Kinds a "bars" selection should return.
    static let barLike: Set<ScoreElementKind> = [.measure]
    /// Everything else a user might lasso: markings rather than pitches.
    static let markingLike: Set<ScoreElementKind> = [
        .harm, .clef, .accid, .slur, .tie, .dynam, .fermata, .articulation,
        .text, .verse
    ]

    /// MEI tag -> kind. Tags absent here are not addressable.
    init?(meiTag: String) {
        switch meiTag {
        case "note":         self = .note
        case "chord":        self = .chord
        case "rest", "mRest", "space", "mSpace": self = .rest
        case "measure":      self = .measure
        case "harm":         self = .harm
        case "clef":         self = .clef
        case "accid":        self = .accid
        case "slur":         self = .slur
        case "tie":          self = .tie
        case "dynam":        self = .dynam
        case "fermata":      self = .fermata
        case "artic":        self = .articulation
        // A chord DIAGRAM is a <dir> too. MEISemanticsParser reads the body
        // before it decides, and gives a diagram no address -- so the
        // ordinals here count the same text marks `ops._elements_in_measure`
        // counts, which is what makes an address usable by the engine.
        case "dir":          self = .text
        // A whistle's fingerings and a guitar tab's frets are verses too; the
        // MEI parser gives those no address, so only WORDS are selectable.
        case "verse":        self = .verse
        case "beam":         self = .beam
        case "staff":        self = .staff
        case "layer":        self = .layer
        default:             return nil
        }
    }
}

/// A durable reference to one element of a score.
///
/// Verovio's SVG ids cannot be used for this: they are regenerated on every
/// load, so the same note is `m5b2j45` in one session and `ul7tvng` in the
/// next (measured — see ios/VECTOR_SCORE.md). An address is derived instead
/// from musical position, which survives re-rendering, relaunching, and any
/// edit that does not move the element.
///
/// `ordinal` disambiguates within one layer of one measure: the 0-based index
/// among elements of the same kind, in document order.
struct ScoreAddress: Hashable, Codable, CustomStringConvertible {
    var staff: Int
    var measure: Int
    var layer: Int
    var kind: ScoreElementKind
    var ordinal: Int

    init(staff: Int, measure: Int, layer: Int, kind: ScoreElementKind, ordinal: Int) {
        self.staff = staff
        self.measure = measure
        self.layer = layer
        self.kind = kind
        self.ordinal = ordinal
    }

    /// Compact, sortable, and readable in a chat prompt or a log:
    /// `s1/m12/l1/note#3`.
    var description: String {
        "s\(staff)/m\(measure)/l\(layer)/\(kind.rawValue)#\(ordinal)"
    }

    /// How a human would hear it read out. Used for chat context.
    var musicalDescription: String {
        switch kind {
        case .measure: return "bar \(measure)"
        case .verse:   return "word in bar \(measure), staff \(staff)"
        default:       return "\(kind.rawValue) in bar \(measure), staff \(staff)"
        }
    }
}
