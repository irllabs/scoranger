import XCTest

/// A file of many tunes imports what it can and names the rest (0.19.0).
final class ImportReportTests: XCTestCase {

    func testNothingToSayWhenEveryTuneImported() {
        XCTAssertNil(ImportReport.notice(from: ["score": "a", "arrangements": [1, 2],
                                                "abc": ["decorations_carried": 4]]))
        XCTAssertNil(ImportReport.notice(from: ["score": "a"]))
    }

    func testSkippedTunesAreNamed() {
        let one = ImportReport.notice(from: [
            "arrangements": Array(repeating: 0, count: 29),
            "abc": ["tunes_skipped": [["title": "The Wind That Shakes The Barley",
                                       "reason": "Bad chord indicator"]]]])
        XCTAssertEqual(one, "Imported 29 of 30 tunes. This one could not be read: "
                       + "The Wind That Shakes The Barley.")
        let many = ImportReport.notice(from: [
            "arrangements": [0],
            "abc": ["tunes_skipped": ["A", "B", "C", "D", "E"].map { ["title": $0] }]])
        XCTAssertEqual(many, "Imported 1 of 6 tunes. These could not be read: "
                       + "A, B, C and 2 more.")
    }
}
