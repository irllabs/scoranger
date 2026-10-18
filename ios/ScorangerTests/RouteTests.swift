import XCTest

/// The navigation rules (NAV_MODAL_FREE_0.4.2 §1, §3.5, §8.6).
final class RouteTests: XCTestCase {

    /// §3.5's rule, in one line: pushing is right when the actions need a
    /// target list or lead to more detail; expanding is right when they are
    /// immediate and positional. The spec flags that two behaviours could read
    /// as inconsistent, so the rule deciding between them is stated once.
    func testARowWhoseActionsNeedATargetPushes() {
        XCTAssertEqual(RowMenuBehaviour.forRow(needsATarget: true), .push)
    }

    func testARowWhoseActionsAreAllOneTapExpands() {
        XCTAssertEqual(RowMenuBehaviour.forRow(needsATarget: false), .expand)
    }

    /// A library row can move to a piece and open its details, so it pushes.
    /// A set-list member's ☰ holds only one-tap actions -- it is reordered by
    /// dragging that ☰ and removed by a swipe -- so it expands. Those are the
    /// two real cases in the app.
    func testTheTwoRealCases() {
        XCTAssertEqual(RowMenuBehaviour.forRow(needsATarget: true), .push,
                       "an arrangement row leads to Move to piece and Details")
        XCTAssertEqual(RowMenuBehaviour.forRow(needsATarget: false), .expand,
                       "a set-list member's actions are all one tap")
    }

    // MARK: - Back labels name the place

    func testTopLevelScreensSayWhereBackGoes() {
        XCTAssertEqual(Route.piece("cavatina").backLabel, "Library")
        XCTAssertEqual(Route.setlist("friday").backLabel, "Library")
        XCTAssertEqual(Route.settings.backLabel, "Library")
    }

    func testDeeperScreensJustSayBack() {
        XCTAssertEqual(Route.moveToPiece(["a"]).backLabel, "Back")
        XCTAssertEqual(Route.versions("a").backLabel, "Back")
    }

    // MARK: - Routes are values, so a stack can hold them

    func testTheSameScreenTwiceIsTheSameRoute() {
        XCTAssertEqual(Route.piece("cavatina"), Route.piece("cavatina"))
        XCTAssertNotEqual(Route.piece("cavatina"), Route.piece("libertango"))
    }

    func testMovingASelectionIsOneScreenForAllOfIt() {
        XCTAssertEqual(Route.moveToPiece(["a", "b"]), Route.moveToPiece(["a", "b"]))
        XCTAssertNotEqual(Route.moveToPiece(["a"]), Route.moveToPiece(["a", "b"]))
    }
    // MARK: - A route follows the arrangement it points at (0.4.2)

    /// The slug is editable on the details screen, so the route that got you
    /// there names something that no longer exists the moment you use it. The
    /// screen went blank and every screen under it with it.
    func testARouteFollowsAMovedArrangement() {
        let moves = ["quartet": "paris-quartet"]
        XCTAssertEqual(Route.details("quartet").following(moves), .details("paris-quartet"))
        XCTAssertEqual(Route.arrangement("quartet").following(moves),
                       .arrangement("paris-quartet"))
        XCTAssertEqual(Route.versions("quartet").following(moves), .versions("paris-quartet"))
        XCTAssertEqual(Route.parts("quartet").following(moves), .parts("paris-quartet"))
        XCTAssertEqual(Route.setlistsFor("quartet").following(moves),
                       .setlistsFor("paris-quartet"))
    }

    func testEveryArrangementInASelectionFollows() {
        XCTAssertEqual(Route.moveToPiece(["a", "b"]).following(["a": "a2", "b": "b2"]),
                       .moveToPiece(["a2", "b2"]))
    }

    /// A piece and a set list are not arrangements: their slugs do not move,
    /// and a matching arrangement slug must not drag them somewhere else.
    func testPiecesAndSetlistsAreLeftAlone() {
        let moves = ["quartet": "paris-quartet"]
        XCTAssertEqual(Route.piece("quartet").following(moves), .piece("quartet"))
        XCTAssertEqual(Route.setlist("quartet").following(moves), .setlist("quartet"))
        XCTAssertEqual(Route.settings.following(moves), .settings)
    }

    func testMovedTwiceLandsOnTheLatestName() {
        XCTAssertEqual(Route.details("a").following(["a": "b", "b": "c"]), .details("c"))
    }

    /// Following a cycle has to stop rather than hang the screen it draws.
    func testACycleStopsInsteadOfSpinning() {
        _ = Route.details("a").following(["a": "b", "b": "a"])
    }

    func testNothingMovedMeansNothingChanges() {
        XCTAssertEqual(Route.details("quartet").following([:]), .details("quartet"))
    }
}
