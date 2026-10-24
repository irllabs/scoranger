import XCTest

/// The transcription queue (Ali, 2026-09-14: "the progress belongs to THE
/// score being transcribed"; and a real queue he can put several pieces in).
final class OMRQueueTests: XCTestCase {

    private func entry(_ name: String, arrangement: String?, running: Bool,
                       stage: String = "uploading…",
                       fraction: Double? = nil) -> OMRQueue.Entry {
        OMRQueue.Entry(id: UUID(), arrangement: arrangement, name: name,
                       running: running, stage: stage, fraction: fraction)
    }

    // MARK: - The fault Ali found

    /// The whole of it: a job belonging to one arrangement said nothing about
    /// any other. Opening a different scan showed its progress bar.
    func testAnotherArrangementsJobIsNotThisArrangementsBusiness() {
        let jobs = [entry("waltz", arrangement: "waltz", running: true)]
        XCTAssertNotNil(OMRQueue.status(ofArrangement: "waltz", in: jobs))
        XCTAssertNil(OMRQueue.status(ofArrangement: "quartet", in: jobs))
    }

    /// A PDF from the share sheet is BECOMING an arrangement and belongs to
    /// none, so it can never claim a score on screen.
    func testATranscriptionThatIsBecomingAnArrangementClaimsNoScore() {
        let jobs = [entry("scan", arrangement: nil, running: true)]
        XCTAssertNil(OMRQueue.status(ofArrangement: "waltz", in: jobs))
        XCTAssertNil(OMRQueue.status(ofArrangement: nil, in: jobs))
    }

    /// A reader looking at no score is not looking at one being transcribed.
    func testNoScoreNoStatus() {
        XCTAssertNil(OMRQueue.status(ofArrangement: nil,
                                     in: [entry("a", arrangement: "a", running: true)]))
    }

    /// The pair that must never disagree: the chip and the Make editable
    /// switch are both built from this one value, so whatever a score shows,
    /// its switch shows the same. Asserted as the invariant, over every score
    /// in a mixed queue and one that is in no queue at all.
    func testTheChipAndTheSwitchCannotDisagreeOnAnyScore() {
        let jobs = [
            entry("one", arrangement: "waltz", running: true, stage: "reading p. 2 / 9",
                  fraction: 0.2),
            entry("two", arrangement: "quartet", running: false),
            entry("three", arrangement: nil, running: false),
        ]
        for slug in ["waltz", "quartet", "tango", "", "scan"] {
            let status = OMRQueue.status(ofArrangement: slug, in: jobs)
            let control = MakeEditable.control(status: status)
            XCTAssertEqual(control.isOn, status != nil,
                           "\(slug): the switch and the progress disagree")
            if let status {
                XCTAssertEqual(control.detail, MakeEditable.detailText(status))
                XCTAssertEqual(control.fraction, status.fraction)
            } else {
                XCTAssertEqual(control.detail, MakeEditable.offer)
                XCTAssertTrue(control.acceptsTap)
            }
        }
    }

    // MARK: - The order, and how many run at once

    /// One at a time. The service is a single Cloud Run instance running
    /// Audiveris and queues submissions itself; parallel clients buy nothing
    /// and pay in 429s.
    func testOneRunsAtATime() {
        XCTAssertEqual(OMRQueue.concurrency, 1)
    }

    func testTheOldestWaitingJobGoesNext() {
        let a = entry("a", arrangement: "a", running: false)
        let b = entry("b", arrangement: "b", running: false)
        XCTAssertEqual(OMRQueue.next(in: [a, b]), a.id)
    }

    func testNothingStartsWhileTheSlotIsTaken() {
        let running = entry("a", arrangement: "a", running: true)
        let waiting = entry("b", arrangement: "b", running: false)
        XCTAssertNil(OMRQueue.next(in: [running, waiting]))
    }

    func testAnEmptyQueueStartsNothing() {
        XCTAssertNil(OMRQueue.next(in: []))
    }

    /// The slot frees when the running job leaves the list.
    func testTheNextOneStartsWhenTheRunningOneIsGone() {
        let waiting = entry("b", arrangement: "b", running: false)
        XCTAssertEqual(OMRQueue.next(in: [waiting]), waiting.id)
    }

    // MARK: - What a waiting score says

    func testAWaitingScoreIsToldWhereInTheQueueItIs() {
        let jobs = [
            entry("one", arrangement: "a", running: true),
            entry("two", arrangement: "b", running: false),
            entry("three", arrangement: "c", running: false),
        ]
        XCTAssertEqual(OMRQueue.status(ofArrangement: "b", in: jobs),
                       .waiting(place: 1, of: 2))
        XCTAssertEqual(OMRQueue.status(ofArrangement: "c", in: jobs),
                       .waiting(place: 2, of: 2))
        XCTAssertEqual(OMRQueue.status(ofArrangement: "c", in: jobs)?.detail,
                       "waiting, 2nd of 2")
    }

    /// The position counts the WAITING ones. A running job is not somebody
    /// the reader is behind in a queue; it is the work happening.
    func testThePositionCountsOnlyWhatIsWaiting() {
        let jobs = [
            entry("one", arrangement: "a", running: true),
            entry("two", arrangement: "b", running: false),
        ]
        XCTAssertEqual(OMRQueue.status(ofArrangement: "b", in: jobs),
                       .waiting(place: 1, of: 1))
        XCTAssertEqual(OMRQueue.status(ofArrangement: "b", in: jobs)?.detail, "waiting")
    }

    func testARunningScoreReportsItsStageAndBar() {
        let jobs = [entry("one", arrangement: "a", running: true,
                          stage: "reading p. 3 / 9", fraction: 0.22)]
        XCTAssertEqual(OMRQueue.status(ofArrangement: "a", in: jobs),
                       .running(stage: "reading p. 3 / 9", fraction: 0.22))
        XCTAssertEqual(OMRQueue.status(ofArrangement: "a", in: jobs)?.fraction, 0.22)
        XCTAssertFalse(OMRQueue.status(ofArrangement: "a", in: jobs)!.showsSpinner)
    }

    /// Waiting has no progress: nothing has started.
    func testWaitingHasNoBar() {
        let status = OMRStatus.waiting(place: 1, of: 2)
        XCTAssertNil(status.fraction)
        XCTAssertTrue(status.showsSpinner)
        XCTAssertFalse(status.isRunning)
    }

    // MARK: - Ordinals, because a reader reads them

    func testTheOrdinalsRead() {
        let pairs: [(Int, String)] = [(1, "1st"), (2, "2nd"), (3, "3rd"), (4, "4th"),
                                      (11, "11th"), (12, "12th"), (13, "13th"),
                                      (21, "21st"), (22, "22nd"), (23, "23rd")]
        for (place, said) in pairs {
            XCTAssertEqual(OMRStatus.waiting(place: place, of: 99).detail,
                           "waiting, \(said) of 99")
        }
    }

    // MARK: - The whole queue in one line

    func testTheSummaryCountsBothKinds() {
        XCTAssertNil(OMRQueue.summary([]))
        XCTAssertEqual(OMRQueue.summary([entry("a", arrangement: "a", running: true)]),
                       "1 transcribing")
        XCTAssertEqual(OMRQueue.summary([
            entry("a", arrangement: "a", running: true),
            entry("b", arrangement: "b", running: false),
            entry("c", arrangement: nil, running: false),
        ]), "1 transcribing, 2 waiting")
        XCTAssertEqual(OMRQueue.summary([entry("b", arrangement: "b", running: false)]),
                       "1 waiting")
    }

    /// 0.23.2: the bar read 100% at once and then waited. Every byte handed
    /// to the network stack is not every byte received, so from there the
    /// stage is a spinner that says what the wait is.
    func testAnUploadHandedOverWaitsWithASpinner() {
        XCTAssertEqual(OMRUpload.stage(sent: 0.4).fraction, 0.4)
        XCTAssertEqual(OMRUpload.stage(sent: 0.4).stage, OMRUpload.sending)
        let handedOver = OMRUpload.stage(sent: 1)
        XCTAssertNil(handedOver.fraction, "no full bar while the service has not answered")
        XCTAssertEqual(handedOver.stage, OMRUpload.waitingForService)
        XCTAssertTrue(OMRStatus.running(stage: handedOver.stage,
                                        fraction: handedOver.fraction).showsSpinner)
    }
}
