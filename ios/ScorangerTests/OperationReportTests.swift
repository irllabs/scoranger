import XCTest

/// The sentence a failed operation says out loud.
///
/// These are the rules that stop a notice being unreadable: a Python traceback
/// arrives as several lines and a hundreds-of-characters `ModuleNotFoundError`,
/// and a bar that renders it whole is a bar nobody reads.
final class OperationReportTests: XCTestCase {

    // MARK: - What an error says

    func testEngineErrorSpeaksTheEnginesOwnRefusal() {
        let e = EngineError(error: "no part named 'Vln III'")
        XCTAssertEqual(OperationReport.reason(e), "no part named 'Vln III'")
    }

    /// 0.19.0: "Couldn't import that file: ValueError: None of the tunes..."
    /// -- the class name is for a log; a refusal is a sentence for a reader.
    /// A crash keeps its class, because that is the news.
    func testARefusalLosesItsClassNameAndACrashKeepsIt() {
        XCTAssertEqual(OperationReport.reason(EngineError(error: "ValueError: None of the tunes could be read.")),
                       "None of the tunes could be read.")
        XCTAssertEqual(OperationReport.reason(EngineError(error: "KeyError: 'parts'")),
                       "KeyError: 'parts'")
    }

    func testOtherErrorsFallBackToTheirDescription() {
        struct Boom: LocalizedError { var errorDescription: String? { "the disk is full" } }
        XCTAssertEqual(OperationReport.reason(Boom()), "the disk is full")
    }

    func testAnEmptyReasonStillSaysSomething() {
        XCTAssertEqual(OperationReport.reason(EngineError(error: "   ")),
                       OperationReport.unexplained)
        XCTAssertFalse(OperationReport.unexplained.isEmpty)
    }

    // MARK: - The sentence

    func testFailureNamesTheActionThenTheReason() {
        XCTAssertEqual(OperationReport.failure("rename that part", reason: "no such part"),
                       "Couldn't rename that part: no such part.")
    }

    func testTheSentenceEndsInExactlyOneStop() {
        XCTAssertEqual(OperationReport.failure("export", reason: "no such version."),
                       "Couldn't export: no such version.")
        XCTAssertEqual(OperationReport.failure("export", reason: "no such version!"),
                       "Couldn't export: no such version!")
        XCTAssertEqual(OperationReport.failure("export", reason: "why?"),
                       "Couldn't export: why?")
    }

    func testAMultiLineTracebackBecomesOneLine() {
        let traceback = """
        Traceback (most recent call last):
          File "bridge.py", line 4, in <module>
        ModuleNotFoundError: No module named 'pypdf'
        """
        let said = OperationReport.failure("import that book", reason: traceback)
        XCTAssertFalse(said.contains("\n"))
        // the last line is the one that names the failure, and it survives
        XCTAssertTrue(said.contains("No module named 'pypdf'"), said)
    }

    func testALongReasonIsTrimmedRatherThanFillingTheScreen() {
        let long = String(repeating: "x", count: 900)
        let said = OperationReport.failure("import that book", reason: long)
        XCTAssertLessThanOrEqual(said.count, OperationReport.reasonLimit + 40)
        XCTAssertTrue(said.hasSuffix("…"), said)
    }

    func testAShortReasonIsNotTrimmed() {
        let said = OperationReport.failure("export", reason: "no such version")
        XCTAssertFalse(said.contains("…"))
    }

    // MARK: - The whole path, as AppState uses it

    func testEngineFailureBecomesTheSentenceAReaderSees() {
        let said = OperationReport.failure("delete that arrangement",
                                           error: EngineError(error: "no score 'x'"))
        XCTAssertEqual(said, "Couldn't delete that arrangement: no score 'x'.")
    }
}
