import XCTest

/// What LibrarySync decides without a server (0.16.0). The engine half --
/// that two devices converge on one library -- is engine/scripts/
/// check_library_sync.py; the rules half is firebase/rules.test.mjs.
final class LibrarySyncModelTests: XCTestCase {

    private func remote(_ collection: String, _ uid: String, at: Double,
                        payload: String = "{}") -> LibrarySyncModel.Remote {
        .init(collection: collection, uid: uid, deleted: false, payload: payload,
              device: "d", fileName: nil, fileBytes: nil, fileEncoding: nil, updatedAt: at)
    }

    // MARK: - cellular (Ali, 2026-09-26)

    func testWiFiMovesEverything() {
        XCTAssertEqual(LibrarySyncModel.transfer(isBook: true, network: .wifi, consented: false), .go)
        XCTAssertEqual(LibrarySyncModel.transfer(isBook: false, network: .wifi, consented: false), .go)
    }

    /// "if on Cell only, ask the user if they want to sync now or later"
    func testCellularAsksBeforeABookAndNotBeforeAnArrangement() {
        XCTAssertEqual(LibrarySyncModel.transfer(isBook: true, network: .cellular, consented: false), .ask)
        XCTAssertEqual(LibrarySyncModel.transfer(isBook: false, network: .cellular, consented: false), .go,
                       "an arrangement's history is small and goes on any connection")
        XCTAssertEqual(LibrarySyncModel.transfer(isBook: true, network: .cellular, consented: true), .go,
                       "once the reader says now, books go")
    }

    func testOfflineMovesNothing() {
        XCTAssertEqual(LibrarySyncModel.transfer(isBook: false, network: .offline, consented: true), .wait)
    }

    // MARK: - the pull cursor

    func testThePullReachesBackBeforeItsCursor() {
        XCTAssertEqual(LibrarySyncModel.floor(for: nil), 0, "a first pull reads everything")
        XCTAssertEqual(LibrarySyncModel.floor(for: 10_000), 10_000 - LibrarySyncModel.overlap,
                       "a server timestamp is set at commit, so a write stamped just "
                       + "before the cursor can appear after it")
        XCTAssertEqual(LibrarySyncModel.floor(for: 30), 0)
    }

    // MARK: - held records

    func testHeldRecordsAreOfferedAgainAndANewerCopyReplacesThem() {
        let held = [remote("scores", "a", at: 5, payload: "old"), remote("books", "b", at: 6)]
        let fresh = [remote("scores", "a", at: 9, payload: "new"), remote("pieces", "c", at: 7)]
        let merged = LibrarySyncModel.merge(held: held, fresh: fresh)
        XCTAssertEqual(merged.map(\.key), ["books/b", "pieces/c", "scores/a"])
        XCTAssertEqual(merged.first { $0.key == "scores/a" }?.payload, "new")
    }

    func testAnOlderCopyNeverReplacesANewerHeldOne() {
        let merged = LibrarySyncModel.merge(held: [remote("scores", "a", at: 9, payload: "held")],
                                            fresh: [remote("scores", "a", at: 5, payload: "stale")])
        XCTAssertEqual(merged.map(\.payload), ["held"])
    }

    // MARK: - files

    func testOnlyNotationIsPacked() {
        XCTAssertTrue(LibrarySyncModel.shouldCompress("versions/01ABC.musicxml"))
        XCTAssertTrue(LibrarySyncModel.shouldCompress("sources/x.xml"))
        XCTAssertFalse(LibrarySyncModel.shouldCompress("books/01ABC.pdf"),
                       "a PDF is already compressed")
        XCTAssertFalse(LibrarySyncModel.shouldCompress("versions/01ABC.pdf"))
    }

    // MARK: - what the reader is told

    func testTheStatusLineSaysWhereTheLibraryStands() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(LibrarySyncModel.sentence(.synced(now.addingTimeInterval(-10)), now: now)
                        .contains("up to date"))
        XCTAssertTrue(LibrarySyncModel.sentence(.synced(now.addingTimeInterval(-300)), now: now)
                        .contains("5 min ago"))
        XCTAssertEqual(LibrarySyncModel.sentence(.waiting(1)), "1 change waiting to sync.")
        XCTAssertEqual(LibrarySyncModel.sentence(.waiting(3)), "3 changes waiting to sync.")
        XCTAssertTrue(LibrarySyncModel.sentence(.offline(2)).contains("2 changes wait"))
        XCTAssertTrue(LibrarySyncModel.sentence(.askCellular(bytes: 48_000_000)).contains("48 MB"))
        XCTAssertTrue(LibrarySyncModel.sentence(.failed("the server said no")).hasSuffix("the server said no"))
    }

    func testMegabytesAreRoundedForAPerson() {
        XCTAssertEqual(LibrarySyncModel.megabytes(400_000), "under 1 MB")
        XCTAssertEqual(LibrarySyncModel.megabytes(48_400_000), "48 MB")
    }
}
