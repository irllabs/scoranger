import XCTest

/// The tempo knob turns down after it has been turned up (Ali's recording,
/// 2026-10-03: from 120 to 186, released, and then it would not move again --
/// by finger or by pointer).
final class TempoKnobTurnsBothWays: XCTestCase {
    private var app: XCUIApplication!

    private func tempo(_ knob: XCUIElement) -> Int {
        let digits = (knob.value as? String ?? "").filter(\.isNumber)
        return Int(digits.prefix(3)) ?? -1
    }

    private func drag(_ knob: XCUIElement, dx: CGFloat = 0, dy: CGFloat = 0) {
        let face = knob.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        face.press(forDuration: 0.05, thenDragTo: face.withOffset(CGVector(dx: dx, dy: dy)))
        sleep(1)
    }

    func testTheKnobTurnsDownAfterItWasTurnedUp() {
        app = XCUIApplication()
        app.launchArguments = ["-resetLibrary", "-seedTestLibrary"]
        app.launch()
        let row = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "row-")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 240))
        row.tap()
        if !app.buttons["score-title"].waitForExistence(timeout: 5) {
            let open = app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "arrangement-")).firstMatch
            if open.waitForExistence(timeout: 8) { open.tap() }
        }
        let knob = app.descendants(matching: .any)["transport-tempo"].firstMatch
        XCTAssertTrue(knob.waitForExistence(timeout: 120), "no tempo knob")
        let start = tempo(knob)
        print("TEMPO start \(start) value=\(String(describing: knob.value))")

        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        // Ali's own movement: 120 to 186 is 66 bpm at 2 bpm per 14pt -- about
        // 460pt of travel, which ends well up over the score canvas.
        drag(knob, dy: -470)
        let up = tempo(knob)
        print("TEMPO after up \(up)")
        XCTAssertGreaterThan(up, start + 50, "turning up did nothing")

        // DOWN has almost no room: the knob is on the bottom edge. Measured
        // before the fix: a 200pt downward drag moved it 8 bpm. That is the
        // whole bug, and it is still true of a vertical drag.
        drag(knob, dy: 200)
        let downward = tempo(knob)
        print("TEMPO after a downward drag \(downward)")

        // LEFT has the whole tray: the way back down.
        drag(knob, dx: -300)
        let left = tempo(knob)
        print("TEMPO after a leftward drag \(left)")
        XCTAssertLessThan(left, downward - 30,
                          "dragging left must turn it down by the whole drag (~43 bpm)")

        drag(knob, dx: 140)
        print("TEMPO after a rightward drag \(tempo(knob))")
        XCTAssertGreaterThan(tempo(knob), left + 10, "dragging right turns it up")
    }
}
