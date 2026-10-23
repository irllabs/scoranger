import Foundation

/// Whether `VerovioRenderer.engrave` will rewrite this score's MEI and load it
/// a second time, read from the MusicXML before Verovio has seen it.
///
/// An engrave that rewrites loads the score twice: the MusicXML, for the MEI
/// the rewrites work on, and then the rewritten MEI, which is what is drawn.
/// The first load's layout is never drawn, so when a rewrite is coming the
/// first load skips it (`EngravingOptions.json(layOut: false)`), and that is
/// most of the first load's cost: 1.0 s of 4.2 s on "Espresso" on the
/// simulator, about 60% of which was casting off pages nobody looked at.
///
/// Only the SPEED depends on this answer, never the pages:
///  - predicted and a rewrite happens: the rewritten MEI is loaded and laid
///    out, as it always was;
///  - predicted and nothing is rewritten: the MusicXML is loaded again with
///    its layout, which is the engrave a score with nothing to rewrite always
///    had (one wasted unlaid load);
///  - not predicted and a rewrite happens anyway: the first load was laid out
///    as before, and the reload follows as before (no saving).
///
/// Each clause mirrors the guard of one rewrite in `engrave`.
enum MEIRewritePrediction {
    static func likely(inMusicXML xml: String,
                       adjustments: [ChordAdjustments.Kind: [ChordAdjustments.Adjustment]],
                       chordsOnStaff: [Bool],
                       diagrams: [ChordDiagrams.Adjustment],
                       numbering: MeasureNumbers.Mode) -> Bool {
        // FingeringDiagrams.meiWithFingeringsAbove: a note carrying a column
        // of hole letters, each a lyric syllable
        let holes = ["X", "O", "/"].contains { xml.contains("<text>\($0)</text>") }
        // ChordAdjustments.meiWithAdjustments: any added mark with an offset
        let offsets = adjustments.values.contains { kind in
            kind.contains { $0.dx != nil || $0.dy != nil }
        }
        // RehearsalMarks.meiWithDedupedMarks: two marks or more
        let rehearsals: Bool = {
            guard let first = xml.range(of: "<rehearsal") else { return false }
            return xml.range(of: "<rehearsal", range: first.upperBound..<xml.endIndex) != nil
        }()
        return holes
            || offsets
            // ChordPlacement.meiWithChartStyling
            || chordsOnStaff.contains(true)
            // ChordDiagrams.meiWithDiagrams
            || !diagrams.isEmpty
            || rehearsals
            // MeasureNumbers.meiHidingNumbers
            || numbering == .none
    }
}
