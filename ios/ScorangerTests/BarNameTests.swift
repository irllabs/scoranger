import XCTest

/// A pickup is "pickup" wherever the app names a bar to a reader (0.18.2).
/// The engine's twin is ops.bar_label, held by check_whistle.py.
final class BarNameTests: XCTestCase {

    func testAPickupIsNamedAndEveryOtherBarIsNumbered() {
        XCTAssertEqual(BarName.text(0), "pickup")
        XCTAssertEqual(BarName.text(1), "bar 1")
        XCTAssertEqual(BarName.text(12), "bar 12")
        XCTAssertEqual(BarName.phrase(0), "the pickup")
        XCTAssertEqual(BarName.phrase(12), "bar 12")
    }

    func testARunOfBars() {
        XCTAssertEqual(BarName.range(3, 3), "bar 3")
        XCTAssertEqual(BarName.range(3, 8), "bars 3–8")
        XCTAssertEqual(BarName.range(0, 8), "the pickup to bar 8")
        XCTAssertEqual(BarName.range(0, 0), "the pickup")
    }

    /// The readouts Amazing Grace's screenshots showed as "bar 0".
    func testTheReadoutsUseIt() {
        XCTAssertEqual(BarPosition.label(for: 0), "pickup")
        XCTAssertEqual(PageFollow.syncLabel(bar: 0), "Back to the pickup")
        XCTAssertEqual(PageFollow.syncLabel(bar: 9), "Back to bar 9")
    }
}
