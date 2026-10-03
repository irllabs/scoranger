import XCTest

/// A shared set list's row and its server entries brought into step (0.18.0).
///
/// Ali added a tune to "Echo and Bubba" on his iPad and it never reached
/// Echo. These hold the decision both directions need; the Firebase half is
/// `AppState.syncSharedSetlist`.
final class SetlistSyncTests: XCTestCase {

    private func remote(_ id: String, _ order: String, uid: String = "",
                        removed: Bool = false) -> SetlistSync.Remote {
        .init(id: id, order: order, scoreUid: uid.isEmpty ? "uid-\(id)" : uid,
              isRemoved: removed)
    }

    private func local(_ slug: String, uid: String? = nil,
                       entry: String? = nil) -> SetlistSync.Local {
        .init(slug: slug, uid: uid ?? "uid-\(slug)", sharedEntry: entry)
    }

    // MARK: - Ali's case

    /// The tune Ali added on his iPad goes up, and comes down on Echo's.
    func testATuneAddedOnOneDeviceReachesTheOther() {
        // Ali's row: the two tunes that were shared, and the one he added.
        let server = [remote("e1", "1", uid: "uid-reel"), remote("e2", "2", uid: "uid-jig")]
        let ali = SetlistSync.plan(
            local: [local("reel"), local("jig"), local("molly")],
            remote: server, base: ["e1", "e2"], mayEdit: true)
        XCTAssertEqual(ali.push, ["molly"])
        XCTAssertEqual(ali.pushKeys.count, 1)
        XCTAssertGreaterThan(ali.pushKeys[0], "2", "it lands after everything there")
        XCTAssertTrue(ali.adopt.isEmpty && ali.withdraw.isEmpty && ali.dropLocally.isEmpty)
        XCTAssertEqual(ali.order, [.local("reel"), .local("jig"), .local("molly")])

        // Echo's row: copies of the first two, linked by entry.
        let after = server + [remote("e3", ali.pushKeys[0], uid: "uid-molly")]
        let echo = SetlistSync.plan(
            local: [local("reel-copy", entry: "e1"), local("jig-copy", entry: "e2")],
            remote: after, base: ["e1", "e2"], mayEdit: true)
        XCTAssertEqual(echo.adopt, ["e3"])
        XCTAssertTrue(echo.writesNothing, "Echo has nothing to send back")
        XCTAssertEqual(echo.order, [.local("reel-copy"), .local("jig-copy"), .adopt("e3")])
    }

    /// The first sync on a device that has never synced -- every row joined or
    /// shared before this build -- only ADDS, both ways. With no base nothing
    /// can be read as a removal made here.
    func testTheFirstSyncOnlyAdds() {
        let plan = SetlistSync.plan(
            local: [local("reel"), local("molly")],
            remote: [remote("e1", "1", uid: "uid-reel"), remote("e2", "2")],
            base: nil, mayEdit: true)
        XCTAssertEqual(plan.push, ["molly"])
        XCTAssertEqual(plan.adopt, ["e2"])
        XCTAssertTrue(plan.withdraw.isEmpty)
        XCTAssertEqual(plan.order, [.local("reel"), .adopt("e2"), .local("molly")])
    }

    // MARK: - the two opposite acts the base tells apart

    func testAnEntryTheRowLostSinceLastSyncWasRemovedHere() {
        let plan = SetlistSync.plan(
            local: [local("reel")],
            remote: [remote("e1", "1", uid: "uid-reel"), remote("e2", "2")],
            base: ["e1", "e2"], mayEdit: true)
        XCTAssertEqual(plan.withdraw, ["e2"])
        XCTAssertTrue(plan.adopt.isEmpty)
        XCTAssertEqual(plan.order, [.local("reel")])
    }

    func testAnEntryTheRowNeverHadWasAddedElsewhere() {
        let plan = SetlistSync.plan(
            local: [local("reel")],
            remote: [remote("e1", "1", uid: "uid-reel"), remote("e2", "2")],
            base: ["e1"], mayEdit: true)
        XCTAssertEqual(plan.adopt, ["e2"])
        XCTAssertTrue(plan.withdraw.isEmpty)
    }

    func testAnEntryRemovedOnTheServerLeavesTheRow() {
        let plan = SetlistSync.plan(
            local: [local("reel"), local("jig")],
            remote: [remote("e1", "1", uid: "uid-reel"),
                     remote("e2", "2", uid: "uid-jig", removed: true)],
            base: ["e1", "e2"], mayEdit: true)
        XCTAssertEqual(plan.dropLocally, ["jig"])
        XCTAssertTrue(plan.push.isEmpty, "a removal elsewhere is not re-added from here")
        XCTAssertEqual(plan.order, [.local("reel")])
    }

    /// Removed by somebody, then added again here after the last sync: the
    /// row's act is newer, so it is a new entry rather than a removal.
    func testAnArrangementAddedAgainAfterItsRemovalIsPushed() {
        let plan = SetlistSync.plan(
            local: [local("reel"), local("jig")],
            remote: [remote("e1", "1", uid: "uid-reel"),
                     remote("e2", "2", uid: "uid-jig", removed: true)],
            base: ["e1"], mayEdit: true)
        XCTAssertEqual(plan.push, ["jig"])
        XCTAssertTrue(plan.dropLocally.isEmpty)
    }

    // MARK: - order

    func testTheServersOrderWinsWhenTheRowWasNotReorderedHere() {
        let plan = SetlistSync.plan(
            local: [local("a"), local("b"), local("c")],
            remote: [remote("ea", "3", uid: "uid-a"), remote("eb", "1", uid: "uid-b"),
                     remote("ec", "2", uid: "uid-c")],
            base: ["ea", "eb", "ec"], mayEdit: true)
        XCTAssertEqual(plan.order, [.local("b"), .local("c"), .local("a")])
        XCTAssertTrue(plan.moves.isEmpty)
    }

    func testAReorderHereIsWrittenAsKeysInTheRowsOrder() {
        let server = [remote("ea", "1", uid: "uid-a"), remote("eb", "2", uid: "uid-b"),
                      remote("ec", "3", uid: "uid-c")]
        let plan = SetlistSync.plan(
            local: [local("c"), local("a"), local("b")],
            remote: server, base: ["ea", "eb", "ec"], mayEdit: true)
        XCTAssertEqual(plan.order, [.local("c"), .local("a"), .local("b")])
        XCTAssertFalse(plan.moves.isEmpty)
        let keys = server.map { plan.moves[$0.id] ?? $0.order }
        let resorted = zip(["a", "b", "c"], keys).sorted { $0.1 < $1.1 }.map(\.0)
        XCTAssertEqual(resorted, ["c", "a", "b"], "the server, re-sorted, reads as the row")
    }

    /// The row matches the server's order already -- my other device pushed
    /// the move, and library sync brought the row here: nothing to write.
    func testAReorderAlreadyOnTheServerWritesNothing() {
        let plan = SetlistSync.plan(
            local: [local("b"), local("a")],
            remote: [remote("ea", "2", uid: "uid-a"), remote("eb", "1", uid: "uid-b")],
            base: ["ea", "eb"], mayEdit: true)
        XCTAssertTrue(plan.writesNothing)
        XCTAssertEqual(plan.order, [.local("b"), .local("a")])
    }

    func testPushedKeysFollowARespreadOrder() {
        let plan = SetlistSync.plan(
            local: [local("b"), local("a"), local("new")],
            remote: [remote("ea", "1", uid: "uid-a"), remote("eb", "2", uid: "uid-b")],
            base: ["ea", "eb"], mayEdit: true)
        XCTAssertEqual(plan.push, ["new"])
        let highest = plan.moves.values.max() ?? "2"
        XCTAssertGreaterThan(plan.pushKeys[0], highest)
    }

    // MARK: - who may write

    func testAReaderChangesNothingOnTheServerAndFollowsIt() {
        let plan = SetlistSync.plan(
            local: [local("mine")],
            remote: [remote("e1", "1")],
            base: ["e1"], mayEdit: false)
        XCTAssertTrue(plan.writesNothing)
        XCTAssertEqual(plan.adopt, ["e1"], "what a reader took out comes back")
        XCTAssertEqual(plan.order, [.adopt("e1"), .local("mine")],
                       "and what a reader added stays in their own row")
    }

    // MARK: - matching

    /// My own arrangement, on my other device through library sync, has the
    /// same uid: it IS the entry, not a new one.
    func testAnArrangementIsItsEntryByUid() {
        let plan = SetlistSync.plan(
            local: [local("reel", uid: "U")],
            remote: [remote("e1", "1", uid: "U")], base: nil, mayEdit: true)
        XCTAssertTrue(plan.writesNothing && plan.changesNothingHere)
    }

    /// A copy adopted before the link was kept on the arrangement is matched
    /// by this device's own record of it.
    func testAnOlderCopyIsMatchedByTheDevicesRecord() {
        let plan = SetlistSync.plan(
            local: [local("reel-copy")],
            remote: [remote("e1", "1", uid: "U")], base: nil,
            copies: ["e1": "reel-copy"], mayEdit: true)
        XCTAssertTrue(plan.writesNothing && plan.changesNothingHere)
    }

    /// Two copies of one entry -- both of an account's devices adopted it
    /// before either heard of the other's -- leave one in the row.
    func testASecondCopyOfOneEntryLeavesTheRow() {
        let plan = SetlistSync.plan(
            local: [local("reel-copy", entry: "e1"), local("reel-copy-2", entry: "e1")],
            remote: [remote("e1", "1", uid: "U")], base: ["e1"], mayEdit: true)
        XCTAssertTrue(plan.writesNothing)
        XCTAssertEqual(plan.order.count, 1)
        XCTAssertEqual(plan.dropLocally.count, 1)
    }

    /// Measured on the emulators: one add pushed twice, by a sync planned
    /// from a snapshot taken during its own upload. The second entry is
    /// withdrawn, never adopted as a copy of the reader's own arrangement.
    func testASecondEntryForAnArrangementInTheRowIsWithdrawn() {
        let plan = SetlistSync.plan(
            local: [local("reel", uid: "U")],
            remote: [remote("e1", "1", uid: "U"), remote("e2", "2", uid: "U")],
            base: nil, mayEdit: true)
        XCTAssertEqual(plan.withdraw, ["e2"])
        XCTAssertTrue(plan.adopt.isEmpty)
        XCTAssertEqual(plan.order, [.local("reel")])
        let reader = SetlistSync.plan(
            local: [local("reel", uid: "U")],
            remote: [remote("e1", "1", uid: "U"), remote("e2", "2", uid: "U")],
            base: nil, mayEdit: false)
        XCTAssertTrue(reader.adopt.isEmpty && reader.writesNothing)
    }

    func testANewEntryIsPreferredOverARemovedOneForTheSameArrangement() {
        let links = SetlistSync.links(
            local: [local("reel", uid: "U")],
            remote: [remote("old", "1", uid: "U", removed: true), remote("new", "2", uid: "U")],
            copies: [:])
        XCTAssertEqual(links["reel"], "new")
    }
}
