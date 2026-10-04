import CoreGraphics
import Foundation

/// Joins page geometry to musical semantics and produces the hit-test model.
///
/// Pure over strings on purpose: it takes SVG pages and MEI text, so it is
/// testable headlessly against fixtures with no Verovio, no engine and no view.
/// Wiring it to the live toolkit belongs to Phase B, which is also when the
/// display list starts feeding the drawing path.
enum ScoreModelBuilder {

    /// Classes Verovio puts on groups that we index. Structural wrappers
    /// (`layer`, `staff`, `system`) are skipped: they bound half a page and
    /// would swallow every lasso.
    static let indexedClasses: Set<String> = [
        "note", "chord", "rest", "mRest", "measure", "harm", "clef", "accid",
        "slur", "tie", "dynam", "fermata", "artic",
        // A text mark. A chord DIAGRAM is drawn in a group of this class too,
        // and is filtered out one step later: the MEI parser gives it no
        // address, and an element with no address is not selectable.
        "dir"
    ]

    /// - Parameters:
    ///   - svgPages: page SVG in page order, as Verovio renders them.
    ///   - mei: the same document's MEI, from `getMEI()`.
    static func build(svgPages: [String], mei: String) throws -> ScoreGeometry {
        let addresses = try MEISemanticsParser.parse(mei)
        var pages: [ScorePage] = []
        for (index, svg) in svgPages.enumerated() {
            let parsed = try SVGGeometryParser.parse(svg)
            var elements: [ScoreElement] = []
            for group in parsed.groups {
                // a class attribute can carry modifiers, e.g. "ledgerLines below"
                let primary = group.svgClass.split(separator: " ").first.map(String.init) ?? ""
                guard indexedClasses.contains(primary),
                      let kind = ScoreElementKind(meiTag: primary) else { continue }
                elements.append(ScoreElement(sessionID: group.id,
                                             kind: kind,
                                             address: addresses[group.id],
                                             pageIndex: index,
                                             frame: group.frame))
            }
            // The engraver's own answer to "how many systems are on this
            // page", kept beside the app's inference of it. Verovio wraps each
            // system in <g class="system">; those groups are deliberately not
            // INDEXED (a structural wrapper bounds half a page and would
            // swallow every lasso) but they are still parsed, and counting
            // them costs one pass over groups already in hand.
            let drawn = parsed.groups.count {
                $0.svgClass.split(separator: " ").first.map(String.init) == "system"
            }
            pages.append(ScorePage(index: index, size: parsed.size,
                                   elements: elements, drawnSystems: drawn))
        }
        return ScoreGeometry(pages: pages)
    }
}

/// A selection of score elements, and the description of it that chat receives.
///
/// Held by durable address rather than by session id, so it survives the
/// re-render that every engine op triggers.
/// How a new lasso combines with the selection already on the page.
///
/// A mode rather than a toggle-by-overlap: lassoing selected things to remove
/// them reads differently depending on what was caught before, so neither a
/// user nor a test can say what it will do over a mixed region.
enum SelectionCombine: String, CaseIterable, Equatable {
    case replace
    case add
    case subtract

    /// Whether the lasso is drawn in the removing colour, so the gesture that
    /// takes things away never looks like the one that adds them.
    var strokeIsWarning: Bool { self == .subtract }

    /// The mode the NEXT lasso should use.
    ///
    /// With nothing selected there is nothing to add to or take from, so the
    /// only mode that means anything is replace. Without this the app had an
    /// unrecoverable state: Subtract empties the selection, an empty selection
    /// hides the chip, and the chip is the only way to change the mode -- so
    /// every later lasso subtracted from nothing and caught nothing, across
    /// score switches and version switches, until the app was relaunched.
    /// Ali reported it as "I draw the lasso and nothing gets selected".
    static func modeAfter(_ mode: SelectionCombine,
                          selectionIsEmpty: Bool) -> SelectionCombine {
        selectionIsEmpty ? .replace : mode
    }

    var label: String {
        switch self {
        case .replace: return "Replace"
        case .add: return "Add"
        case .subtract: return "Subtract"
        }
    }
}

struct ScoreSelection: Equatable {
    var addresses: [ScoreAddress]

    init(_ elements: [ScoreElement]) {
        addresses = Self.selectable(elements.compactMap(\.address))
    }

    /// What a lasso or a tap is allowed to catch.
    ///
    /// Never the bar itself. A `<measure>` element's frame spans the whole bar
    /// across every staff, so lassoing three notes caught the measure too and
    /// lit up the entire bar (Ali's #9), and tapping empty space caught the
    /// measure alone and selected the whole bar out of nowhere (#10a). One
    /// cause, two symptoms.
    ///
    /// Bars are still selectable -- deliberately, by double- or triple-tapping
    /// an empty part of one (#10b), which is the only way to ask for a bar and
    /// so the only way to get one. That selection is the bar's MEMBERS, never
    /// the measure element, so it survives this filter untouched.
    static func selectable(_ addresses: [ScoreAddress]) -> [ScoreAddress] {
        addresses.filter { !ScoreElementKind.barLike.contains($0.kind) }
    }

    /// EVERY selection is filtered, not just the one built from elements.
    ///
    /// The rule above was written once and reachable only through
    /// `init(_ elements:)` -- which the tests call and the app does not. The
    /// app catches elements, takes their addresses, and goes through
    /// `combining`, so a `<measure>` walked straight in: Ali selected a note
    /// on the top staff and the highlight painted the whole bar across every
    /// staff, because that is the shape of a measure's frame. A guard only one
    /// caller passes through is not a guard.
    init(addresses: [ScoreAddress]) {
        self.addresses = Self.selectable(addresses)
    }

    /// This selection, combined with what a new lasso caught.
    ///
    /// Order is the order things were selected in, so the chat reference reads
    /// the way the user built it up rather than jumping about.
    func combining(_ caught: [ScoreAddress], mode: SelectionCombine) -> ScoreSelection {
        switch mode {
        case .replace:
            return ScoreSelection(addresses: caught)
        case .add:
            var merged = addresses
            for address in caught where !merged.contains(address) { merged.append(address) }
            return ScoreSelection(addresses: merged)
        case .subtract:
            let removing = Set(caught)
            return ScoreSelection(addresses: addresses.filter { !removing.contains($0) })
        }
    }

    /// Drop one element, for a single correction rather than a whole region.
    func dropping(_ address: ScoreAddress) -> ScoreSelection {
        ScoreSelection(addresses: addresses.filter { $0 != address })
    }

    var isEmpty: Bool { addresses.isEmpty }

    var bars: [Int] { Set(addresses.map(\.measure)).sorted() }

    /// Staff 0 is the parser's "not staff-specific" marker — a `<measure>`
    /// lives outside any `<staff>` — so it is a fact about the model, not a
    /// staff anyone can be told about. A lasso over one staff caught measures
    /// too, and reported "staves 0, 4".
    var staves: [Int] { Set(addresses.map(\.staff)).filter { $0 > 0 }.sorted() }

    /// What is dropped into the chat input when a lasso finishes: short, in the
    /// user's terms, and visibly about what they just drew.
    /// The voices (MEI layers) the selection spans. Layer 0 is the parser's
    /// "not layer-specific" marker, the same convention `staves` uses.
    var voices: [Int] { Set(addresses.map(\.layer)).filter { $0 > 0 }.sorted() }

    /// The chip's headline: how many things, and where. "3 elements from bar 15".
    var headline: String {
        let n = addresses.count
        let unit = n == 1 ? "element" : "elements"
        let bars = self.bars
        guard let first = bars.first else { return "\(n) \(unit)" }
        let where_ = BarName.range(first, bars[bars.count - 1])
        return "\(n) \(unit) from \(where_)"
    }

    /// The second line: which staff, which voice. Both are in every address
    /// already; the chip simply never showed them.
    var placeLine: String? {
        let staves = self.staves, voices = self.voices
        var parts: [String] = []
        if staves.count == 1 { parts.append("staff \(staves[0])") }
        else if staves.count > 1 {
            parts.append("staves " + staves.map(String.init).joined(separator: ", "))
        }
        if voices.count == 1 { parts.append("voice \(voices[0])") }
        else if voices.count > 1 {
            parts.append("voices " + voices.map(String.init).joined(separator: ", "))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// May a selection made on `from` be carried onto `to`?
    ///
    /// Yes only within one arrangement, and only when the version changed by
    /// itself -- which means an op produced a new one. A version the user
    /// picked is them looking somewhere else, and a different arrangement is
    /// the bleed between a score and its copy that must never happen.
    static func survivesReRender(from: String?, to: String,
                                 userPickedVersion: Bool) -> Bool {
        guard let from, !userPickedVersion else { return false }
        return from.split(separator: "/").first == to.split(separator: "/").first
    }

    /// Kinds whose size and position can be adjusted from the chip.
    ///
    /// Every kind `adjust-element` reaches and the lasso can catch. Chord
    /// DIAGRAMS and tab columns are adjustable in the engine and are not here:
    /// a diagram is drawn by us rather than by Verovio and carries no address,
    /// and a tab column IS a note, so selecting one would mean selecting the
    /// music under it.
    static let adjustableKinds: Set<ScoreElementKind> = Set(AddedMark.kinds)

    /// True when every selected element can be adjusted AND they are all the
    /// same kind, so the chip's position and size row is shown.
    ///
    /// A mixed selection does not get it: nudging a notehead is a different
    /// feature with different rules, and offering a control that silently
    /// skips half the selection is worse than none. Once there were five
    /// adjustable kinds, "all adjustable" stopped being enough -- a dynamic
    /// and a fermata selected together would drive one row that names one
    /// noun, steps one size unit and moves by one of two different mechanics,
    /// and all three would be true of only half of what was selected.
    var isAdjustable: Bool {
        guard let kind = addresses.first?.kind,
              Self.adjustableKinds.contains(kind) else { return false }
        return addresses.allSatisfy { $0.kind == kind }
    }

    /// The addresses themselves, for an op that must touch exactly these
    /// elements and nothing else.
    var addressList: [String] { addresses.map(\.description) }

    var chatReference: String {
        guard !isEmpty else { return "" }
        let bars = self.bars
        let range = bars.count == 1 ? "bar \(bars[0])"
                                    : "bars \(bars[0])–\(bars[bars.count - 1])"
        let staves = self.staves
        let where_ = staves.isEmpty ? ""
            : (staves.count == 1 ? ", staff \(staves[0])"
                                 : ", staves \(staves.map(String.init).joined(separator: ", ")))")
        return "[selection: \(addresses.count) element(s) in \(range)\(where_)] "
    }

    /// What the chat agent is told, in the terms it already understands:
    /// parts and bar numbers, not pixels. Replaces the linear "≈ bars" estimate
    /// the old drag-select produced.
    var chatDescription: String? {
        guard !isEmpty else { return nil }
        let bars = self.bars
        let staves = self.staves
        let range = bars.count == 1
            ? "bar \(bars[0])"
            : "bars \(bars[0])–\(bars[bars.count - 1])"
        let kinds = Set(addresses.map(\.kind.rawValue)).sorted().joined(separator: ", ")
        let staffPart = staves.isEmpty ? ""
            : (staves.count == 1 ? " of staff \(staves[0])"
                                 : " of staves \(staves.map(String.init).joined(separator: ", ")))")
        return "A selection is ACTIVE: \(addresses.count) element(s) (\(kinds)) "
            + "in \(range)\(staffPart). Apply operations only there unless "
            + "told otherwise."
    }
}
