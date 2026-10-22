import XCTest

/// The library drawn at launch from the manifest the engine last wrote, before
/// the engine is up (`LibrarySnapshot`).
///
/// The fixture is a `manifest.json` written by the real engine through the
/// app's own bridge: two settings of a tune filed under one piece, one
/// unfiled, a version history, a set list and a book.
final class LibrarySnapshotTests: XCTestCase {

    private func fixture() throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: "launch-manifest",
                                                 withExtension: "json",
                                                 subdirectory: "Fixtures"),
                      "the engine-written manifest is not in the test bundle")
    }

    /// Exactly the path `LocalEngine.manifest()` takes with the bridge's
    /// answer: parsed to a dictionary, written back out, decoded.
    private func decodedAsTheEngineAnswer(_ url: URL) throws -> Manifest {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Manifest.self, from: data)
    }

    /// The handover from snapshot to engine redraws nothing when nothing
    /// changed: `refresh` publishes only a manifest that differs.
    func testASnapshotEqualsTheEnginesOwnAnswerForTheSameLibrary() throws {
        let url = try fixture()
        let snapshot = try XCTUnwrap(LibrarySnapshot.read(from: url))
        XCTAssertEqual(snapshot, try decodedAsTheEngineAnswer(url))
        XCTAssertEqual(snapshot.scores.count, 3)
        XCTAssertEqual(snapshot.pieces?.count, 1)
        XCTAssertEqual(snapshot.setlists?.count, 1)
        XCTAssertEqual(snapshot.books?.count, 1)
        XCTAssertEqual(snapshot.scores.reduce(0) { $0 + $1.versions.count }, 4)
    }

    func testTheLibraryRowsComeOutOfASnapshotAsTheyDoOutOfTheEngine() throws {
        let url = try fixture()
        let snapshot = try XCTUnwrap(LibrarySnapshot.read(from: url))
        let engine = try decodedAsTheEngineAnswer(url)
        XCTAssertEqual(LibraryModel.pieceRows(manifest: snapshot) + LibraryModel.unfiledRows(manifest: snapshot),
                       LibraryModel.pieceRows(manifest: engine) + LibraryModel.unfiledRows(manifest: engine))
        XCTAssertEqual(LibraryModel.pieceRows(manifest: snapshot).count, 1)
        XCTAssertEqual(LibraryModel.unfiledRows(manifest: snapshot).count, 1)
    }

    /// No file and half a file are both "no snapshot": the list waits for the
    /// engine, as it did before snapshots existed.
    func testNoFileIsNoSnapshot() {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "no-such-\(UUID().uuidString)").appending(path: "manifest.json")
        XCTAssertNil(LibrarySnapshot.read(from: url))
    }

    func testHalfAFileIsNoSnapshot() throws {
        let whole = try Data(contentsOf: try fixture())
        let url = FileManager.default.temporaryDirectory
            .appending(path: "truncated-\(UUID().uuidString).json")
        try whole.prefix(whole.count / 2).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(LibrarySnapshot.read(from: url))
    }

    /// What `ScorangerApp.init` starts is what `AppState.init` collects, once.
    func testAPrefetchIsCollectedOnceAndAReadFollowsIt() throws {
        let url = try fixture()
        LibrarySnapshot.prefetch(from: url)
        XCTAssertEqual(LibrarySnapshot.collect(from: url), LibrarySnapshot.read(from: url))
        let missing = FileManager.default.temporaryDirectory
            .appending(path: "none-\(UUID().uuidString).json")
        XCTAssertNil(LibrarySnapshot.collect(from: missing),
                     "the prefetch was handed over; a second collect reads the file it is given")
    }

    // MARK: - The row's day, now that its formatters are shared

    /// The three forms a timestamp has arrived in: the engine's own (whole
    /// seconds with a zone), with fractional seconds, and the zone-less form
    /// older libraries carry.
    func testEveryTimestampFormStillReadsAsADay() {
        let now = ISO8601DateFormatter().date(from: "2026-10-21T12:00:00Z")!
        for stamp in ["2026-08-09T13:52:16-07:00", "2026-08-09T20:52:16.250Z",
                      "2026-08-09T13:52:16"] {
            XCTAssertFalse(LibraryModel.day(stamp, now: now).isEmpty, stamp)
            XCTAssertEqual(LibraryModel.day(stamp, now: now), LibraryModel.day(stamp, now: now),
                           "a remembered date reads the same the second time")
        }
        XCTAssertEqual(LibraryModel.day(nil, now: now), "")
        XCTAssertEqual(LibraryModel.day("not a date", now: now), "")
    }

    func testTodayIsStillToday() {
        let now = Date()
        let stamp = ISO8601DateFormatter().string(from: now)
        XCTAssertEqual(LibraryModel.day(stamp, now: now), "today")
    }
}
