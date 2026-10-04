import Foundation

/// Where a mark is being sent, how the reader says so, and what to do with the
/// engine's refusal.
///
/// THE DESTINATION IS A TAPPED BAR PLUS AN OFFSET INSIDE IT. This app has no
/// drag (0.4.2 removed it and pinch means zoom), so the reader taps the bar
/// they want and steps the offset within it. `ops.move_element` takes exactly
/// that pair, in quarter notes from the barline, which is why nothing here
/// converts anything.
///
/// ## The refusal is the other half of the feature
///
/// A note-attached mark -- a fermata, an articulation -- has no offset of its
/// own: it hangs off a note, and the engine refuses a destination no note
/// starts at rather than inventing a placement MusicXML cannot express. It
/// refuses USEFULLY, by listing the onsets the bar does have, and a dialog
/// that showed that sentence and stopped would have turned a list of the right
/// answers into a dead end. So the sentence is read: the onsets become the
/// choices, and one tap lands the mark on one of them.
///
/// Pure, so the parsing of a refusal is tested against the engine's real
/// wording without an engine, a screen or a score.
struct MoveDestination: Equatable {

    enum Intent: String, Equatable {
        case move, duplicate

        /// The button, and the verb in every sentence about it.
        var verb: String { self == .move ? "Move" : "Duplicate" }
    }

    let intent: Intent
    /// What is being placed, so the refusal can be read in its terms.
    let kind: ScoreElementKind
    /// Where it is now.
    let source: ScoreAddress

    /// The bar the reader has tapped, or nil while they have not tapped one.
    var bar: Int?
    /// Quarter notes from the barline. 0 is the downbeat.
    var offset: Double = 0
    /// How long the destination bar is, when anything knows -- the playback
    /// timeline, or the engine's own refusal. Nil means unclamped: the stepper
    /// still steps and the engine is still the authority.
    var barLength: Double?
    /// The onsets the engine listed, once it has had cause to list them.
    var onsets: [Double] = []
    /// The refusal in the engine's words, or nil.
    var refusal: String?

    /// One step of the offset stepper: an eighth note. Small enough to reach
    /// the off-beats a mark is actually written on, large enough that walking
    /// a 4/4 bar is eight taps rather than thirty-two.
    static let step: Double = 0.5

    init(intent: Intent, kind: ScoreElementKind, source: ScoreAddress) {
        self.intent = intent
        self.kind = kind
        self.source = source
    }

    /// True when the mark must land ON a note, which is what makes a refusal
    /// possible at all.
    var needsANote: Bool { AddedMark.isNoteAttached(kind) }

    /// Nothing can be sent until a bar has been tapped.
    var isReady: Bool { bar != nil }

    // MARK: - The stepper

    func canStep(by delta: Double) -> Bool {
        let next = offset + delta
        if next < -0.0001 { return false }
        if let barLength, next > barLength - Self.step / 2 { return false }
        return true
    }

    mutating func step(by delta: Double) {
        guard canStep(by: delta) else { return }
        offset = max(0, offset + delta)
        // The reader has moved the target, so a refusal about the old one is
        // stale. The onsets are NOT cleared: they are facts about the bar.
        refusal = nil
    }

    /// Land exactly on one of the onsets the engine named.
    mutating func snap(to onset: Double) {
        offset = onset
        refusal = nil
    }

    /// A tap on the page picked a bar. Everything known about the last one
    /// goes with it -- a different bar has different onsets and its own length.
    mutating func aim(atBar number: Int, barLength: Double? = nil) {
        bar = number
        offset = 0
        self.barLength = barLength
        onsets = []
        refusal = nil
    }

    // MARK: - What it says

    /// `bar 12 · downbeat`, or `bar 12 · 1½ ♩ in`. Nil before a bar is tapped.
    var summary: String? {
        guard let bar else { return nil }
        return offset == 0 ? "\(BarName.text(bar)) \u{00B7} downbeat"
                           : "\(BarName.text(bar)) \u{00B7} \(Self.quarters(offset)) in"
    }

    /// What the chip asks for while no bar has been tapped.
    var prompt: String {
        "\(intent.verb) the \(AddedMark.noun(kind)): tap the bar it should go to"
    }

    /// The button.
    var confirmTitle: String { "\(intent.verb) it here" }

    /// The offset, as a reader writes it: `1½ ♩`, `2 ♩`, `½ ♩`.
    static func quarters(_ value: Double) -> String {
        let whole = Int(value)
        let half = value - Double(whole) >= 0.25
        let body: String
        switch (whole, half) {
        case (0, true):  body = "\u{00BD}"
        case (_, true):  body = "\(whole)\u{00BD}"
        default:         body = "\(whole)"
        }
        return body + " \u{2669}"
    }

    // MARK: - Reading a refusal

    /// Take what the engine said and keep the facts out of it.
    mutating func refused(_ reason: String) {
        refusal = reason
        if let found = Self.onsets(inRefusal: reason), !found.isEmpty {
            onsets = found
        }
        if let length = Self.barLength(inRefusal: reason) {
            barLength = length
        }
    }

    /// The onsets in `... that bar starts notes at [0.0, 1.0, 2.0, 3.0]`.
    ///
    /// Matched on the engine's own phrase rather than on "any bracketed list",
    /// so a refusal that happens to contain a list of something else does not
    /// become a row of wrong choices.
    static func onsets(inRefusal reason: String) -> [Double]? {
        guard let re = try? NSRegularExpression(
                pattern: "starts notes at \\[([^\\]]*)\\]"),
              let m = re.firstMatch(in: reason,
                                    range: NSRange(location: 0,
                                                   length: (reason as NSString).length)),
              m.numberOfRanges > 1 else { return nil }
        let body = (reason as NSString).substring(with: m.range(at: 1))
        return body.split(separator: ",").compactMap {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
    }

    /// The length in `offset 5.0 is not inside measure 12, which is 4.0
    /// quarter notes long`.
    static func barLength(inRefusal reason: String) -> Double? {
        guard let re = try? NSRegularExpression(
                pattern: "which is ([0-9.]+) quarter notes long"),
              let m = re.firstMatch(in: reason,
                                    range: NSRange(location: 0,
                                                   length: (reason as NSString).length)),
              m.numberOfRanges > 1 else { return nil }
        return Double((reason as NSString).substring(with: m.range(at: 1)))
    }

    /// The one line the chip shows when the engine has refused: what went
    /// wrong, in the app's terms, and what to do about it.
    ///
    /// Nil when nothing has been refused. When the bar HAS onsets the sentence
    /// stops short of listing them, because the buttons beside it are the list.
    var refusalNote: String? {
        guard refusal != nil else { return nil }
        let noun = AddedMark.noun(kind)
        if !onsets.isEmpty {
            return "A \(noun) hangs off a note, and nothing starts "
                + "\(offset == 0 ? "on the downbeat" : "at \(Self.quarters(offset))") "
                + "of \(bar.map(BarName.phrase) ?? "that bar"). "
                + "Here is what that bar does start:"
        }
        if let barLength {
            return "Bar \(bar.map(String.init) ?? "?") is only "
                + "\(Self.quarters(barLength)) long."
        }
        return refusal
    }
}
