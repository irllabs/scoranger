import XCTest

/// Putting the transport on screen without being asked (`TransportReveal`).
///
/// The bug: 0.6 shipped playback behind a preference defaulting to false in a
/// submenu, so the release's headline feature was invisible. The reader opened
/// a score with real notation, saw no play button, and asked whether the build
/// had playback at all.
final class TransportRevealTests: XCTestCase {

    /// The moment the fix exists for: something can play, nobody has been
    /// shown the transport, so show it.
    func testTheFirstPlayableArrangementRevealsTheTransport() {
        let d = TransportReveal.decide(canPlay: true, showTransport: false,
                                       alreadyRevealed: false)

        XCTAssertTrue(d.showTransport)
        XCTAssertTrue(d.revealed, "it would reveal again on the next score")
    }

    /// A reader who hid the chrome on purpose must not have it pushed back at
    /// them every time they open something playable.
    func testAReaderWhoHidItKeepsItHidden() {
        let d = TransportReveal.decide(canPlay: true, showTransport: false,
                                       alreadyRevealed: true)

        XCTAssertFalse(d.showTransport)
    }

    /// A scan is not the moment to teach someone the transport exists -- it
    /// would appear saying only that it cannot play.
    func testAnUnplayableArrangementRevealsNothing() {
        let d = TransportReveal.decide(canPlay: false, showTransport: false,
                                       alreadyRevealed: false)

        XCTAssertFalse(d.showTransport)
        XCTAssertFalse(d.revealed, "the one reveal would be spent on a scan")
    }

    /// Already on and already revealed: nothing changes, and in particular the
    /// flag is not re-written on every score.
    func testAlreadyShowingIsLeftAlone() {
        let d = TransportReveal.decide(canPlay: true, showTransport: true,
                                       alreadyRevealed: true)

        XCTAssertEqual(d, .init(showTransport: true, revealed: true))
    }

    /// Showing but never formally revealed -- a fresh install on the new
    /// default. The flag is recorded so the one reveal is not still owed.
    func testAFreshInstallRecordsThatItHasBeenSeen() {
        let d = TransportReveal.decide(canPlay: true, showTransport: true,
                                       alreadyRevealed: false)

        XCTAssertTrue(d.showTransport)
        XCTAssertTrue(d.revealed)
    }
}
