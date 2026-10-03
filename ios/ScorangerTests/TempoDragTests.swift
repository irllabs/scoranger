import XCTest

/// The tray's tempo knob turns by either axis (0.17.1): it sits on the bottom
/// edge, and turning it down by dragging down had about 40pt of room.
final class TempoDragTests: XCTestCase {

    func testUpAndRightAreFasterDownAndLeftAreSlower() {
        let up = TempoDrag.bpm(start: 120, translation: CGSize(width: 0, height: -140))
        let right = TempoDrag.bpm(start: 120, translation: CGSize(width: 140, height: 0))
        let down = TempoDrag.bpm(start: 120, translation: CGSize(width: 0, height: 140))
        let left = TempoDrag.bpm(start: 120, translation: CGSize(width: -140, height: 0))
        XCTAssertEqual(up, 140, accuracy: 0.001, "2 bpm per 14pt, as it always was")
        XCTAssertEqual(right, 140, accuracy: 0.001)
        XCTAssertEqual(down, 100, accuracy: 0.001)
        XCTAssertEqual(left, 100, accuracy: 0.001)
    }

    /// Ali's case: 186, and only 40pt of screen below the knob. Dragging left
    /// gets back to where he started.
    func testFrom186TheWayBackDownIsSideways() {
        let downward = TempoDrag.bpm(start: 186, translation: CGSize(width: 0, height: 40))
        XCTAssertGreaterThan(downward, 180, "40pt down is all the room there is, and it is ~6 bpm")
        let leftward = TempoDrag.bpm(start: 186, translation: CGSize(width: -462, height: 0))
        XCTAssertEqual(leftward, 120, accuracy: 0.001)
    }

    func testADiagonalDragAddsBothWays() {
        let diagonal = TempoDrag.bpm(start: 100, translation: CGSize(width: 70, height: -70))
        XCTAssertEqual(diagonal, 120, accuracy: 0.001)
    }
}
