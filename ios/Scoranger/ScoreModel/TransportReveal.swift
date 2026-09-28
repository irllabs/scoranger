import Foundation

/// Whether the transport should be put on screen without being asked for.
///
/// 0.6 shipped playback -- the whole release -- behind `showTransport`, an
/// `@AppStorage` preference defaulting to FALSE and reachable only through a
/// toggle in More -> Display. The result was that the reader who asked for the
/// feature installed the build, opened a score with real notation, found no
/// play button anywhere, and reasonably asked whether playback was in there at
/// all. It was. Nothing ever turned it on.
///
/// Two changes, because either alone leaves someone out. The default is now
/// TRUE, which covers a fresh install. And the FIRST time an arrangement can
/// actually play, the transport is revealed once -- which covers everyone
/// carrying a stored `false` from a build where that was the default.
///
/// Revealed ONCE, and recorded. After that the toggle is the reader's: someone
/// who deliberately hides the chrome must not have it pushed back at them
/// every time they open something playable.
enum TransportReveal {

    struct Decision: Equatable {
        var showTransport: Bool
        var revealed: Bool
    }

    /// Given what is stored and whether the arrangement on screen can play,
    /// what should be stored next.
    static func decide(canPlay: Bool,
                       showTransport: Bool,
                       alreadyRevealed: Bool) -> Decision {
        // Nothing to reveal it for: an unplayable arrangement is not the
        // moment to teach someone the transport exists.
        guard canPlay else {
            return Decision(showTransport: showTransport, revealed: alreadyRevealed)
        }
        // The reader's own choice, already made and recorded, stands.
        guard !alreadyRevealed else {
            return Decision(showTransport: showTransport, revealed: true)
        }
        return Decision(showTransport: true, revealed: true)
    }
}
