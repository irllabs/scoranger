import CoreGraphics

/// How a drag on the tray's tempo knob turns it (0.17.1).
///
/// Ali, 2026-10-03, on a recording: turned it up from 120 to 186, let go, "and
/// now I can't turn it down anymore". The knob sits on the BOTTOM edge of the
/// screen and turned only by vertical drag, down for slower -- so turning it
/// down had about 40pt of travel before the finger or the pointer met the
/// edge, which is 6 bpm, while turning it up had the whole screen. It never
/// stopped working; there was nowhere to drag.
///
/// So the knob reads BOTH axes: up or RIGHT is faster, down or LEFT is
/// slower, at the same 2 bpm per 14pt. A knob on an edge can always be turned
/// toward the side that has room, and a vertical drag behaves as it did.
enum TempoDrag {

    /// Points of travel per step, and bpm per step (MIXER §7.8's 14pt unit).
    static let pointsPerStep: CGFloat = 14
    static let bpmPerStep: Double = 2

    /// The tempo a drag that began at `start` has reached, unrounded.
    static func bpm(start: Double, translation: CGSize) -> Double {
        let travel = translation.width - translation.height
        return start + Double(travel / pointsPerStep) * bpmPerStep
    }
}
