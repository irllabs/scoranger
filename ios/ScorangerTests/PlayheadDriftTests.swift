import AVFoundation
import XCTest

/// The cursor keeps step with the sound through the LAST bar.
///
/// Ali, 0.8.0 build 193: "the piece ends but the visual playhead is about
/// one bar behind the sound." The cursor is placed from ONE number, the
/// sequencer's `currentPositionInBeats`, through the timeline's bar map. So
/// there are exactly two places a bar can go missing: the clock does not
/// advance with the audio it renders, or the map and the MIDI disagree about
/// how long the piece is. This measures both on the real pair the app ships
/// through the engine -- `sous-le-ciel-performance.mid` and its timeline --
/// rendered offline, where a second of audio is exactly 44100 frames.
final class PlayheadDriftTests: XCTestCase {

    private func fixture(_ name: String, _ ext: String) throws -> URL {
        guard let url = Bundle(for: Self.self).url(forResource: name, withExtension: ext,
                                                   subdirectory: "Fixtures") else {
            throw XCTSkip("\(name).\(ext) is not in the test bundle")
        }
        return url
    }

    /// The clock against rendered time, second by second, to the end.
    func testTheClockKeepsStepWithTheRenderedAudioToTheLastBar() throws {
        let midi = try fixture("sous-le-ciel-performance", "mid")
        let json = try Data(contentsOf: fixture("sous-le-ciel-timeline", "json"))
        let timeline = try JSONDecoder().decode(PlaybackTimeline.self, from: json)
        let bpm = timeline.openingTempo
        XCTAssertEqual(timeline.tempos.count, 1, "this fixture is one tempo throughout")

        let graph = PlaybackGraph()
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        try graph.engine.enableManualRenderingMode(.offline, format: format,
                                                   maximumFrameCount: 4096)
        try graph.load(midi: midi, timeline: timeline)
        try graph.engine.start()
        guard let sequencer = graph.sequencer else { return XCTFail("no sequencer") }
        sequencer.prepareToPlay()
        try sequencer.start()

        // What the MIDI says the piece is, in beats, against the map.
        let midiBeats = sequencer.tracks.map(\.lengthInBeats).max() ?? 0
        print("DRIFT map beats \(timeline.beats)  midi beats \(midiBeats)  bars \(timeline.bars.count)")
        XCTAssertEqual(midiBeats, timeline.beats, accuracy: 1.0,
                       "the map and the MIDI disagree about the piece's length: "
                       + "map \(timeline.beats) beats, MIDI \(midiBeats)")

        let buffer = AVAudioPCMBuffer(pcmFormat: graph.engine.manualRenderingFormat,
                                      frameCapacity: 4096)!
        var worst = 0.0
        var worstAt = 0.0
        var seconds = 0.0
        let total = timeline.beats / bpm * 60
        // Whole 4096-frame renders only, and the second is read off the
        // engine's own sample counter. Rendering a SHORT final chunk each
        // second (44100 = 10 x 4096 + 3140) made the sequencer's offline
        // clock run 2% fast against the samples -- eleven calls counted as
        // eleven full buffers -- which is an artefact of driving the engine
        // by hand: in real time the clock keeps pace with the device to
        // 0.05% (testTheClockKeepsPaceWithTheDeviceInRealTime).
        // Up to the last bar's end and no further: past the end of the MIDI
        // the sequencer's beat keeps counting while the music has stopped,
        // which is the player's business (it stops on `sequencer.isPlaying`),
        // not the cursor's.
        while seconds < total {
            let target = graph.engine.manualRenderingSampleTime + 44100
            while graph.engine.manualRenderingSampleTime < target {
                guard try graph.engine.renderOffline(4096, to: buffer) == .success else { break }
            }
            seconds = Double(graph.engine.manualRenderingSampleTime) / 44100
            let beat = sequencer.currentPositionInBeats
            if Int(seconds) % 60 == 0 {
                // Is the clock's SECOND the rendered second? If these agree
                // and the beat still runs ahead, the file's tempo is not what
                // the map says; if they disagree, the clock is not the audio.
                print("DRIFT clock seconds=\(sequencer.currentPositionInSeconds) rendered seconds=\(seconds) sampleTime=\(graph.engine.manualRenderingSampleTime) rate=\(sequencer.rate) tempoTrackBPM=\(sequencer.tempoTrack.lengthInBeats)")
            }
            let expected = seconds * bpm / 60
            let off = beat - expected
            if abs(off) > abs(worst) { worst = off; worstAt = seconds }
            if Int(seconds) % 30 == 0 || seconds > total - 3 {
                print("DRIFT t=\(seconds)s beat=\(beat) expected=\(expected) off=\(off) bar=\(timeline.bar(atBeat: beat) ?? -1)")
            }
        }
        print("DRIFT worst \(worst) beats at \(worstAt)s")
        // Half a beat is a quaver at this tempo; a bar is three beats.
        XCTAssertLessThan(abs(worst), 0.5,
                          "the clock drifted \(worst) beats from the rendered audio by \(worstAt)s")
        // And the last thing the map says while the sound is still going is
        // the last bar, not the one before it.
        let lastBar = timeline.bars.last!.measure
        let nearEnd = timeline.bar(atBeat: midiBeats - 0.1)
        XCTAssertEqual(nearEnd, lastBar, "a tenth of a beat from the end the map says bar \(nearEnd ?? -1)")
    }

    /// Is the SOUND where the clock says it is? The map says the violin first
    /// sounds at beat 24 -- 12.0s at 120. Everything else silenced, the first
    /// audible sample is where the violin enters in the rendered audio. If
    /// that is 12.0s the audio is at tempo and a fast clock is a fast cursor;
    /// if it is 11.76s the audio is fast too and clock and sound agree.
    func testTheAudioIsWhereTheClockSaysItIs() throws {
        let midi = try fixture("sous-le-ciel-performance", "mid")
        let json = try Data(contentsOf: fixture("sous-le-ciel-timeline", "json"))
        let timeline = try JSONDecoder().decode(PlaybackTimeline.self, from: json)
        guard let violin = timeline.parts.first, let entry = violin.sounding.first?.first else {
            return XCTFail("the fixture's first part has no sounding span")
        }
        let expectedSeconds = entry / timeline.openingTempo * 60

        let graph = PlaybackGraph()
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        try graph.engine.enableManualRenderingMode(.offline, format: format,
                                                   maximumFrameCount: 4096)
        try graph.load(midi: midi, timeline: timeline)
        var voices = PlaybackVoices()
        voices.setAll(on: false, parts: timeline.parts)
        voices.toggle(violin.index)
        graph.apply(voices, parts: timeline.parts, metronome: false)
        try graph.engine.start()
        guard let sequencer = graph.sequencer else { return XCTFail("no sequencer") }
        sequencer.prepareToPlay()
        try sequencer.start()

        let buffer = AVAudioPCMBuffer(pcmFormat: graph.engine.manualRenderingFormat,
                                      frameCapacity: 4096)!
        var onsetFrame: AVAudioFramePosition?
        var clockAtOnset = 0.0
        let limit = AVAudioFramePosition((expectedSeconds + 4) * 44100)
        while graph.engine.manualRenderingSampleTime < limit, onsetFrame == nil {
            let start = graph.engine.manualRenderingSampleTime
            guard try graph.engine.renderOffline(4096, to: buffer) == .success,
                  let channels = buffer.floatChannelData else { break }
            for frame in 0..<Int(buffer.frameLength) where abs(channels[0][frame]) > 0.01 {
                onsetFrame = start + AVAudioFramePosition(frame)
                clockAtOnset = sequencer.currentPositionInBeats
                break
            }
        }
        guard let onsetFrame else { return XCTFail("the violin never sounded") }
        let onsetSeconds = Double(onsetFrame) / 44100
        print("ONSET audio at \(onsetSeconds)s, map says \(expectedSeconds)s (beat \(entry)); clock read \(clockAtOnset) beats")
        XCTAssertEqual(onsetSeconds, expectedSeconds, accuracy: 0.05,
                       "the violin entered at \(onsetSeconds)s in the audio; the map says \(expectedSeconds)s")
        XCTAssertEqual(clockAtOnset, entry, accuracy: 0.25,
                       "when the violin entered the clock said beat \(clockAtOnset), the map says \(entry)")
    }

    /// The same question in REAL TIME, which is how the iPad plays: does the
    /// sequencer's clock keep pace with the audio device's? A tap on the main
    /// mixer counts the frames the device has actually taken; the sequencer's
    /// own seconds are read in the same callback. Twenty seconds is enough to
    /// see a 2% error (0.4s) ten times over the tolerance.
    func testTheClockKeepsPaceWithTheDeviceInRealTime() throws {
        let midi = try fixture("sous-le-ciel-performance", "mid")
        let json = try Data(contentsOf: fixture("sous-le-ciel-timeline", "json"))
        let timeline = try JSONDecoder().decode(PlaybackTimeline.self, from: json)
        let graph = PlaybackGraph()
        try graph.load(midi: midi, timeline: timeline)
        try graph.engine.start()
        guard let sequencer = graph.sequencer else { return XCTFail("no sequencer") }
        // Real time, so it reaches the Mac's speakers through the simulator;
        // what it measures is frames and clock positions, never loudness, so
        // the output is turned down (Ali, 2026-10-03: "make sure you dont make
        // sound out of my loudspeakers").
        graph.engine.mainMixerNode.outputVolume = 0
        let rate = graph.engine.mainMixerNode.outputFormat(forBus: 0).sampleRate
        let done = expectation(description: "twenty seconds of audio")
        var frames: AVAudioFramePosition = 0
        var readings: [(device: Double, clock: Double, beats: Double)] = []
        var finished = false
        graph.engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
            frames += AVAudioFramePosition(buffer.frameLength)
            let device = Double(frames) / rate
            readings.append((device, sequencer.currentPositionInSeconds, sequencer.currentPositionInBeats))
            if device >= 20, !finished { finished = true; done.fulfill() }
        }
        sequencer.prepareToPlay()
        try sequencer.start()
        wait(for: [done], timeout: 40)
        graph.engine.mainMixerNode.removeTap(onBus: 0)
        sequencer.stop()
        for reading in readings where Int(reading.device * 10) % 50 == 0 {
            print("DRIFT-RT device=\(reading.device) clock=\(reading.clock) beats=\(reading.beats)")
        }
        guard let last = readings.last else { return XCTFail("the tap never fired") }
        print("DRIFT-RT end device=\(last.device) clock=\(last.clock) beats=\(last.beats) ratio=\(last.clock / last.device)")
        XCTAssertEqual(last.clock, last.device, accuracy: 0.1,
                       "after \(last.device)s of audio the sequencer's clock said \(last.clock)s")
        XCTAssertEqual(last.beats, last.device * timeline.openingTempo / 60, accuracy: 0.25,
                       "after \(last.device)s the clock said beat \(last.beats); at \(timeline.openingTempo) that should be \(last.device * timeline.openingTempo / 60)")
    }

    /// The tempo knob now reaches 480, which at this fixture's 120 is a rate
    /// of 4. Does the SEQUENCER honour it -- the sound, not only the number?
    /// At rate 4 the violin's entry at beat 24 (12.0s at 120) must be heard
    /// at 3.0s, and the clock must say beat 24 when it is.
    func testTheSequencerHonoursFourTimesTheOpeningTempo() throws {
        let midi = try fixture("sous-le-ciel-performance", "mid")
        let json = try Data(contentsOf: fixture("sous-le-ciel-timeline", "json"))
        let timeline = try JSONDecoder().decode(PlaybackTimeline.self, from: json)
        guard let violin = timeline.parts.first, let entry = violin.sounding.first?.first else {
            return XCTFail("the fixture's first part has no sounding span")
        }
        let rate = PlaybackTempo.rate(target: PlaybackTempo.maximum, opening: timeline.openingTempo)
        XCTAssertEqual(rate, 4, accuracy: 1e-9, "480 over 120 is four times")
        let expectedSeconds = entry / timeline.openingTempo * 60 / rate

        let graph = PlaybackGraph()
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        try graph.engine.enableManualRenderingMode(.offline, format: format,
                                                   maximumFrameCount: 4096)
        try graph.load(midi: midi, timeline: timeline)
        var voices = PlaybackVoices()
        voices.setAll(on: false, parts: timeline.parts)
        voices.toggle(violin.index)
        graph.apply(voices, parts: timeline.parts, metronome: false)
        try graph.engine.start()
        guard let sequencer = graph.sequencer else { return XCTFail("no sequencer") }
        sequencer.prepareToPlay()
        sequencer.rate = Float(rate)
        try sequencer.start()

        let buffer = AVAudioPCMBuffer(pcmFormat: graph.engine.manualRenderingFormat,
                                      frameCapacity: 4096)!
        var onsetFrame: AVAudioFramePosition?
        var clockAtOnset = 0.0
        let limit = AVAudioFramePosition((expectedSeconds + 4) * 44100)
        while graph.engine.manualRenderingSampleTime < limit, onsetFrame == nil {
            let start = graph.engine.manualRenderingSampleTime
            guard try graph.engine.renderOffline(4096, to: buffer) == .success,
                  let channels = buffer.floatChannelData else { break }
            for frame in 0..<Int(buffer.frameLength) where abs(channels[0][frame]) > 0.01 {
                onsetFrame = start + AVAudioFramePosition(frame)
                clockAtOnset = sequencer.currentPositionInBeats
                break
            }
        }
        guard let onsetFrame else { return XCTFail("the violin never sounded at rate \(rate)") }
        let onsetSeconds = Double(onsetFrame) / 44100
        print("RATE480 audio onset \(onsetSeconds)s, expected \(expectedSeconds)s; clock \(clockAtOnset) beats, entry \(entry)")
        XCTAssertEqual(onsetSeconds, expectedSeconds, accuracy: 0.1,
                       "at 480 the violin should enter at \(expectedSeconds)s; it entered at \(onsetSeconds)s")
        XCTAssertEqual(clockAtOnset, entry, accuracy: 0.5)
    }
}
