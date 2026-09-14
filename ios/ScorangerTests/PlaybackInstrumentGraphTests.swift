import AVFoundation
import XCTest

/// The instrument picker's two claims about the audio graph, measured rather
/// than assumed.
///
/// The catalogue in `GeneralMIDI` was read out of the bundled bank's preset
/// table by `check_vendored_soundfont.py`. That says what is in the FILE. This
/// says what the runtime does with it, which is the claim a reader's ear cares
/// about -- an entry in the picker that loads nothing is a silent channel with
/// a confident label on it.
///
/// Rendered offline, the way `PlaybackAudioTests` does: manual rendering mode
/// needs no audio session, no hardware and no host app, and it drives the
/// `PlaybackGraph` that ships rather than a parallel copy of its wiring.
final class PlaybackInstrumentGraphTests: XCTestCase {

    private let sampleRate = 44100.0
    private let block: AVAudioFrameCount = 4096
    private let silence = 1e-5

    private func fixture(_ name: String) throws -> URL {
        guard let url = Bundle(for: Self.self).url(forResource: name,
                                                   withExtension: "mid",
                                                   subdirectory: "Fixtures") else {
            throw XCTSkip("fixture \(name).mid is not in the test bundle")
        }
        return url
    }

    private func quartet() -> [PlaybackTimeline.Part] {
        let names = ["Violin I", "Violin II", "Viola", "Violoncello"]
        let programs = [40, 40, 41, 42]
        return (0..<4).map {
            .init(index: $0, name: names[$0], instrument: names[$0],
                  program: programs[$0])
        }
    }

    private func timeline(parts: [PlaybackTimeline.Part],
                          beats: Double = 16) -> PlaybackTimeline {
        let bars = stride(from: 0.0, to: beats, by: 4).map {
            PlaybackTimeline.Bar(measure: Int($0 / 4) + 1, start: $0, end: $0 + 4)
        }
        let clicks = stride(from: 0.0, to: beats, by: 1).map {
            PlaybackTimeline.Click(beat: $0,
                                   down: $0.truncatingRemainder(dividingBy: 4) == 0)
        }
        return PlaybackTimeline(parts: parts, bars: bars, clicks: clicks,
                                tempos: [.init(beat: 0, bpm: 120)])
    }

    private func loaded(parts: [PlaybackTimeline.Part],
                        instruments: PlaybackInstruments = PlaybackInstruments())
        throws -> PlaybackGraph {
        let graph = PlaybackGraph()
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                   channels: 2)!
        try graph.engine.enableManualRenderingMode(.offline, format: format,
                                                   maximumFrameCount: block)
        try graph.load(midi: try fixture("quartet-playback"),
                       timeline: timeline(parts: parts), instruments: instruments)
        // THIS BUNDLE MEASURES GAIN, SO IT STATES ITS OWN GAIN.
        //
        // Every assertion below is "this program is louder than silence", read
        // out of a buffer rendered through the main mixer. `load` turns that
        // mixer down when it believes it is under the UI-test harness, and what
        // it believes is decided outside this file -- today an argument and an
        // environment variable, tomorrow whatever stops music reaching a
        // loudspeaker. Any of those arriving here would make every RMS zero and
        // every one of these tests pass by measuring nothing.
        //
        // Offline rendering never reaches a speaker, so there is nothing here
        // to silence. Set it explicitly and the question cannot be reopened by
        // a change made somewhere else for a good reason.
        graph.engine.mainMixerNode.outputVolume = 1
        return graph
    }

    @discardableResult
    private func render(_ graph: PlaybackGraph, seconds: Double) throws -> Double {
        if !graph.engine.isRunning { try graph.engine.start() }
        let buffer = AVAudioPCMBuffer(pcmFormat: graph.engine.manualRenderingFormat,
                                      frameCapacity: block)!
        let target = graph.engine.manualRenderingSampleTime
            + AVAudioFramePosition(seconds * sampleRate)
        var sum = 0.0, counted = 0
        while graph.engine.manualRenderingSampleTime < target {
            let remaining = target - graph.engine.manualRenderingSampleTime
            let frames = AVAudioFrameCount(min(AVAudioFramePosition(block), remaining))
            // renderOffline hands back autoreleased CoreAudio objects; drained
            // per block, the loop's peak is one block rather than a whole note.
            let status = try autoreleasepool {
                try graph.engine.renderOffline(frames, to: buffer)
            }
            guard status == .success, let channels = buffer.floatChannelData else { break }
            for channel in 0..<Int(buffer.format.channelCount) {
                for frame in 0..<Int(buffer.frameLength) {
                    let value = Double(channels[channel][frame])
                    sum += value * value
                    counted += 1
                }
            }
        }
        return counted > 0 ? (sum / Double(counted)).squareRoot() : 0
    }

    /// Play one key on one channel and measure what comes out.
    ///
    /// All-sound-off (MIDI controller 120) before and after, because a sampler
    /// tail is long: a church organ still ringing from the previous program
    /// would make the next one look like it sounded. Without that cut, this
    /// test passes whether or not the sound it is measuring exists.
    private func rms(_ graph: PlaybackGraph, channel: Int, key: UInt8,
                     seconds: Double = 0.4) throws -> Double {
        let sampler = graph.samplers[channel]
        sampler.sendController(120, withValue: 0, onChannel: 0)
        _ = try render(graph, seconds: 0.05)
        sampler.startNote(key, withVelocity: 100, onChannel: 0)
        let level = try render(graph, seconds: seconds)
        sampler.stopNote(key, onChannel: 0)
        sampler.sendController(120, withValue: 0, onChannel: 0)
        _ = try render(graph, seconds: 0.05)
        return level
    }

    /// The loudest of a few standard keys. One key is not a fair question of a
    /// bank that holds a piccolo and a contrabass, and a program that is silent
    /// at middle C but speaks an octave down is not a silent program.
    private func loudest(_ graph: PlaybackGraph, keys: [UInt8]) throws -> Double {
        var best = 0.0
        for key in keys { best = max(best, try rms(graph, channel: 0, key: key)) }
        return best
    }

    private func sounding(_ parts: [PlaybackTimeline.Part]) throws -> PlaybackGraph {
        let graph = try loaded(parts: parts)
        graph.apply(PlaybackVoices(), parts: parts, metronome: false)
        if !graph.engine.isRunning { try graph.engine.start() }
        return graph
    }

    // MARK: - The catalogue is real

    /// All 128, one at a time, on the graph that ships. An entry the picker
    /// offers that will not load is a silent channel with a label on it.
    func testEveryMelodicProgramInTheCatalogueLoads() throws {
        let graph = try loaded(parts: quartet())
        var refused: [UInt8] = []
        for instrument in GeneralMIDI.melodic {
            if !graph.setInstrument(program: instrument.program,
                                    bank: .melodic, channel: 0) {
                refused.append(instrument.program)
            }
        }
        XCTAssertEqual(refused, [],
                       "the melodic bank "
                       + "(\(PlaybackSound.bank?.lastPathComponent ?? "NONE")) "
                       + "refused these")
    }

    /// The kits, and the reason the picker offers thirteen rather than 128:
    /// the percussion bank holds nothing at the other programs.
    func testEveryDrumKitInTheCatalogueLoads() throws {
        let graph = try loaded(parts: quartet())
        var refused: [UInt8] = []
        for kit in GeneralMIDI.kits {
            if !graph.setInstrument(program: kit.program,
                                    bank: .percussion, channel: 0) {
                refused.append(kit.program)
            }
        }
        XCTAssertEqual(refused, [], "the percussion bank refused these kits")
    }

    /// A channel that failed to load a sound is recorded, and a channel that
    /// has just been given one that works is no longer on that list -- the
    /// failures are a live fact about the graph, not a log of the load.
    func testARepairedChannelStopsBeingReportedAsAFailure() throws {
        let graph = try loaded(parts: quartet())
        XCTAssertEqual(graph.bankFailures, [])
        XCTAssertTrue(graph.setInstrument(program: 0, bank: .melodic, channel: 0))
        XCTAssertEqual(graph.bankFailures, [])
    }

    /// A channel the graph does not have is refused rather than trapped: the
    /// part list and the sampler list can disagree for one layout pass while a
    /// new arrangement loads.
    func testAChannelTheGraphDoesNotHaveIsRefused() throws {
        let graph = try loaded(parts: quartet())
        XCTAssertFalse(graph.setInstrument(program: 0, bank: .melodic, channel: 99))
    }

    // MARK: - The catalogue SOUNDS

    /// **Loading is not sounding.** `loadSoundBankInstrument` returning true
    /// says the sampler accepted a bank and a program; it does not say a note
    /// on that program makes a noise, and a picker row that loads and then
    /// plays silence is worse than one that is not offered -- the reader
    /// changes a staff's sound, hears nothing, and blames the mute.
    ///
    /// So every one of the 128 the picker offers is PLAYED here and the output
    /// is measured, on the graph that ships. Three keys because one is not a
    /// fair question of a bank holding both a piccolo and a contrabass.
    ///
    /// The `XCTAssertTrue` carries the other half and is not decoration. A
    /// REFUSED load leaves the previous patch on the sampler, so a program the
    /// bank does not hold still makes a noise -- measured, by putting a
    /// percussion program the file has nothing at into this loop and watching
    /// it sound like the piano before it. Silence alone cannot see that; the
    /// loader's answer can.
    ///
    /// And this assertion can fail: forcing one program's channel to zero
    /// volume names it in the list. Verified the same way.
    func testEveryMelodicProgramActuallyMakesASound() throws {
        let graph = try sounding(quartet())
        var silent: [String] = []
        for instrument in GeneralMIDI.melodic {
            // AN AUTORELEASE POOL PER PROGRAM, and it is not decoration.
            //
            // This loop is 128 programs x 3 keys = 384 offline renders, each
            // allocating a PCM buffer, each `setInstrument` reading a patch
            // out of a 31MB sound bank -- and every one of those is CoreAudio,
            // which is Objective-C underneath. Nothing drains until the method
            // returns, so the peak is the whole loop's allocations at once.
            //
            // It crashed twice under four-worker gate load ("Test crashed with
            // signal kill" in `render`), on the worker also carrying all 1019
            // unit tests, and passed on quieter runs -- which is what a memory
            // cliff looks like rather than a broken assertion. The assertions
            // are untouched: the same 128 programs on the same three keys.
            try autoreleasepool {
                XCTAssertTrue(graph.setInstrument(program: instrument.program,
                                                  bank: .melodic, channel: 0),
                              "\(instrument.name) would not load")
                if try loudest(graph, keys: [60, 48, 72]) <= silence {
                    silent.append("\(instrument.program) \(instrument.name)")
                }
            }
        }
        XCTAssertEqual(silent, [],
                       "the picker offers these and they play nothing")
    }

    /// The same question of the kits, on kit keys rather than pitches: a
    /// drum kit answers to key numbers, and middle C on a drum bank is a
    /// different instrument rather than a different pitch.
    func testEveryDrumKitActuallyMakesASound() throws {
        let graph = try sounding(quartet())
        var silent: [String] = []
        for kit in GeneralMIDI.kits {
            // Same pool, same reason as the melodic loop above -- fewer
            // programs, but the same 31MB bank behind each load.
            try autoreleasepool {
                XCTAssertTrue(graph.setInstrument(program: kit.program,
                                                  bank: .percussion, channel: 0),
                              "\(kit.name) would not load")
                // bass drum, snare, closed hi-hat -- every kit has these three
                if try loudest(graph, keys: [36, 38, 42]) <= silence {
                    silent.append("\(kit.program) \(kit.name)")
                }
            }
        }
        XCTAssertEqual(silent, [], "these kits play nothing")
    }

    /// The measurement above can only fail if it can tell silence from sound.
    /// A program the percussion bank does not hold is the control: it is
    /// refused by the loader, and if it is forced onto the sampler anyway
    /// nothing comes out of it.
    func testTheMeasurementCanTellSilenceFromSound() throws {
        let graph = try sounding(quartet())
        XCTAssertTrue(graph.setInstrument(program: 0, bank: .melodic, channel: 0))
        XCTAssertGreaterThan(try rms(graph, channel: 0, key: 60), silence,
                             "a grand piano at middle C is not silence")
        // Never started: a sampler asked for no note makes no sound, which is
        // what the threshold has to be able to see.
        _ = try render(graph, seconds: 0.05)
        graph.samplers[0].sendController(120, withValue: 0, onChannel: 0)
        XCTAssertLessThanOrEqual(try render(graph, seconds: 0.4), silence,
                                 "the threshold cannot see silence")
    }

    // MARK: - Mid-performance

    /// The reader changes a strip's instrument while the music is playing.
    /// `loadSoundBankInstrument` is per-node and each part has its own
    /// sampler, so nothing is rebuilt: the clock keeps running, the play head
    /// does not move back, and sound keeps coming out.
    func testChangingAnInstrumentMidPerformanceDoesNotRestartTheTransport() throws {
        let parts = quartet()
        let graph = try loaded(parts: parts)
        graph.apply(PlaybackVoices(), parts: parts, metronome: false)
        try graph.engine.start()
        graph.sequencer?.prepareToPlay()
        try graph.sequencer?.start()

        try render(graph, seconds: 1)
        let before = graph.sequencer?.currentPositionInBeats ?? 0
        XCTAssertGreaterThan(before, 0)

        // every voice on a piano, which is the ask this feature came from
        var instruments = PlaybackInstruments()
        instruments.chooseAll(program: 0, parts: parts)
        graph.applyInstruments(instruments, parts: parts)

        XCTAssertEqual(graph.sequencer?.isPlaying, true,
                       "the transport stopped when an instrument changed")
        let after = graph.sequencer?.currentPositionInBeats ?? 0
        XCTAssertGreaterThanOrEqual(after, before,
                                    "the play head moved backwards")

        let rms = try render(graph, seconds: 1)
        XCTAssertGreaterThan(rms, silence,
                             "the score went silent after the instrument changed")
    }

    /// The initial patch comes from the reader's choices, not only from the
    /// engine's programs -- a score reopened plays in the sound it was left in.
    func testAGraphLoadsTheChoicesItIsGiven() throws {
        let parts = quartet()
        var instruments = PlaybackInstruments()
        instruments.chooseAll(program: 0, parts: parts)
        let graph = try loaded(parts: parts, instruments: instruments)
        XCTAssertEqual(graph.bankFailures, [])
        graph.apply(PlaybackVoices(), parts: parts, metronome: false)
        try graph.engine.start()
        graph.sequencer?.prepareToPlay()
        try graph.sequencer?.start()
        XCTAssertGreaterThan(try render(graph, seconds: 1), silence)
    }
}
