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

    /// The owner's report: the iPhone showed few of the iPad's pieces, and
    /// Settings still said the library was up to date, because the only
    /// number it had was what this device owes.
    func testUpToDateIsNotSaidWhileSomethingIsArriving() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let synced = LibrarySyncModel.Status.synced(now.addingTimeInterval(-10))
        let three = LibrarySyncModel.Arriving(arrangements: 3)
        XCTAssertEqual(LibrarySyncModel.sentence(synced, arriving: three, now: now),
                       "Synced just now. 3 arrangements have not finished arriving on this device.")
        XCTAssertFalse(LibrarySyncModel.sentence(synced, arriving: three, now: now)
                        .contains("up to date"))
        XCTAssertTrue(LibrarySyncModel.sentence(synced, arriving: .none, now: now)
                        .contains("up to date"), "and it is said when nothing is")
        XCTAssertEqual(LibrarySyncModel.sentence(.waiting(2),
                                                 arriving: .init(setlists: 1)),
                       "2 changes waiting to sync. 1 set list has not finished arriving on this device.")
        XCTAssertTrue(LibrarySyncModel.sentence(.offline(0), arriving: three)
                        .hasSuffix("3 arrangements have not finished arriving on this device."))
    }

    func testWhatIsArrivingIsCountedAsAPersonWouldSayIt() {
        XCTAssertNil(LibrarySyncModel.arrivingClause(.none))
        XCTAssertEqual(LibrarySyncModel.arrivingClause(.init(arrangements: 1)),
                       "1 arrangement has not finished arriving on this device.")
        XCTAssertEqual(LibrarySyncModel.arrivingClause(.init(arrangements: 1, setlists: 1)),
                       "1 arrangement and 1 set list have not finished arriving on this device.")
        XCTAssertEqual(LibrarySyncModel.arrivingClause(.init(arrangements: 10, setlists: 1, books: 2)),
                       "10 arrangements, 1 set list and 2 books have not finished arriving on this device.")
    }

    /// A push that fails no longer stops the pull, so the line has to say
    /// which half went wrong.
    func testAFailedPushSaysWhatWasNotSent() {
        XCTAssertEqual(LibrarySyncModel.sentence(.unsent(3, "the server could not be reached. It will try again.")),
                       "Could not send 3 changes from this device: the server could not be reached. "
                       + "It will try again.")
        XCTAssertEqual(LibrarySyncModel.sentence(.unsent(1, "no"), arriving: .init(books: 1)),
                       "Could not send 1 change from this device: no. 1 book has not finished "
                       + "arriving on this device.")
        XCTAssertEqual(LibrarySyncModel.sentence(.unsent(0, "no")),
                       "Could not send this device's changes: no")
    }

    // MARK: - pushing

    /// A first push of a large library is cut off whenever iOS suspends the
    /// app; what was uploaded but not committed and acknowledged goes again.
    /// The window was 400 records, so one interruption could cost minutes.
    func testAPushIsCommittedInSmallWindows() {
        XCTAssertFalse(LibrarySyncModel.windowIsFull(records: 19, bytes: 0))
        XCTAssertTrue(LibrarySyncModel.windowIsFull(records: 20, bytes: 0),
                      "twenty records at most between commits")
        XCTAssertFalse(LibrarySyncModel.windowIsFull(records: 1, bytes: 1_999_999))
        XCTAssertTrue(LibrarySyncModel.windowIsFull(records: 1, bytes: 2_000_000),
                      "and sooner once a large file has gone up")
    }

    // MARK: - this device's name

    private func identity(_ storedID: String?, _ storedVendor: String?,
                          _ vendor: String?) -> LibrarySyncModel.DeviceIdentity {
        LibrarySyncModel.deviceIdentity(storedID: storedID, storedVendor: storedVendor,
                                        vendor: vendor, mint: { "minted" })
    }

    func testADeviceKeepsItsNameOnTheDeviceThatMintedIt() {
        XCTAssertEqual(identity(nil, nil, "V1"), .init(id: "minted", vendor: "V1"),
                       "the first sign-in names the device and remembers whose name it is")
        XCTAssertEqual(identity("D1", "V1", "V1"), .init(id: "D1", vendor: "V1"))
    }

    /// UserDefaults is in every backup. Restored onto a second device, the
    /// first device's name made each skip the other's writes as its own.
    func testADeviceRestoredFromAnotherDevicesBackupTakesANewName() {
        XCTAssertEqual(identity("D1", "V1", "V2"), .init(id: "minted", vendor: "V2"))
    }

    func testANameStoredBeforeTheVendorWasKeptIsReplacedOnce() {
        let replaced = identity("D1", nil, "V1")
        XCTAssertEqual(replaced, .init(id: "minted", vendor: "V1"),
                       "a name with no vendor beside it could have come from a backup")
        XCTAssertEqual(identity(replaced.id, replaced.vendor, "V1"), replaced,
                       "and from then on it is kept")
    }

    func testBeforeTheFirstUnlockTheStoredNameIsUsed() {
        XCTAssertEqual(identity("D1", "V1", nil), .init(id: "D1", vendor: "V1"),
                       "iOS has no vendor id before the first unlock after a restart")
        XCTAssertEqual(identity(nil, nil, nil), .init(id: "minted", vendor: nil))
    }

    func testMegabytesAreRoundedForAPerson() {
        XCTAssertEqual(LibrarySyncModel.megabytes(400_000), "under 1 MB")
        XCTAssertEqual(LibrarySyncModel.megabytes(48_400_000), "48 MB")
    }
}
