import AVFoundation
import XCTest

/// The play head is fed at DISPLAY rate, not at the readout's twenty a second
/// (0.8.0 build 195, item B). Measured against a real sequencer in real time
/// on whatever screen this runs on: the ticker's samples per second, and the
/// largest step between two consecutive beats it handed over.
final class PlayheadTickerTests: XCTestCase {

    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext,
                                                 subdirectory: "Fixtures"),
                      "missing fixture \(name).\(ext)")
    }

    func testTheTickerHandsOverTheBeatEveryFrame() throws {
        let midi = try fixture("sous-le-ciel-performance", "mid")
        let json = try Data(contentsOf: fixture("sous-le-ciel-timeline", "json"))
        let timeline = try JSONDecoder().decode(PlaybackTimeline.self, from: json)
        let graph = PlaybackGraph()
        try graph.load(midi: midi, timeline: timeline)
        // Real time, so it reaches the Mac's speakers through the simulator;
        // what it measures is frames and clock positions, never loudness, so
        // the output is turned down (Ali, 2026-10-03: "make sure you dont make
        // sound out of my loudspeakers").
        graph.engine.mainMixerNode.outputVolume = 0
        try graph.engine.start()
        let sequencer = try XCTUnwrap(graph.sequencer)
        sequencer.prepareToPlay()
        try sequencer.start()

        let ticker = PlayheadTicker()
        var beats: [Double] = []
        let started = CACurrentMediaTime()
        let done = expectation(description: "two seconds of frames")
        ticker.start {
            beats.append(sequencer.currentPositionInBeats)
            if CACurrentMediaTime() - started >= 2, beats.count > 1 { done.fulfill() }
        }
        wait(for: [done], timeout: 10)
        ticker.stop()
        sequencer.stop()

        let seconds = CACurrentMediaTime() - started
        let perSecond = Double(beats.count) / seconds
        let steps = zip(beats, beats.dropFirst()).map { $1 - $0 }
        let largest = steps.max() ?? 0
        let maxFPS = Double(UIScreen.main.maximumFramesPerSecond)
        print("TICKER \(beats.count) samples in \(seconds)s = \(perSecond)/s; largest step \(largest) beats; screen max \(maxFPS)")
        // A 20-a-second poll gives 20 samples and 0.1-beat steps at 120.
        XCTAssertGreaterThanOrEqual(perSecond, min(maxFPS, 60) * 0.8,
                                    "the ticker ran at \(perSecond)/s on a \(maxFPS) screen")
        XCTAssertLessThan(largest, 0.08, "a step of \(largest) beats is a visible jump at 120")
        XCTAssertTrue(steps.allSatisfy { $0 >= -1e-9 }, "the beat went backwards")
    }
}
