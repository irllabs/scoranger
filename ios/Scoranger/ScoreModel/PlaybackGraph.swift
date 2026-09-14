import AVFoundation
import Foundation

/// The audio graph: samplers, the sequencer, the click track, and the volume
/// on each channel.
///
/// It lives here, beside the pure types, for one reason: **it can be rendered
/// offline.** `AVAudioEngine.enableManualRenderingMode` needs no audio session,
/// no hardware and no host app, so what a listener would hear can be measured
/// in the unit suite. Every audio claim about this app used to be structural --
/// the right objects were connected to each other -- and nobody had ever
/// checked that a sample came out. `PlaybackAudioTests` drives THIS type, so
/// the thing measured is the thing that ships.
///
/// What is NOT here: play/stop state, the sounding bar, anything published.
/// `PlaybackEngine` owns those and owns one of these.
///
/// The shape was measured on the iOS 26.5 runtime:
///
///   - music21 writes one MIDI track per part plus a leading conductor track,
///     and whether `AVAudioSequencer.tracks` includes that conductor track
///     DEPENDS ON THE FILE. This used to say it was omitted, and index by
///     part; on the score in Ali's video it was present, and every part was
///     wired one sampler too low. `trackOffset(trackCount:partCount:)` is
///     measured at load instead, and `partTrackOffset` is used everywhere a
///     track is looked up.
///   - A track appended AFTER loading lands after the parts, so the click is
///     always last and the part indices stay put.
///   - `AVAudioUnitSampler.volume` is linear in amplitude and takes effect
///     while the graph is running, which is what a fader needs.
/// A MIDI whose track count the graph cannot explain against its parts.
enum PlaybackGraphError: LocalizedError {
    case unexplainedTracks(tracks: Int, parts: Int)
    var errorDescription: String? {
        switch self {
        case .unexplainedTracks(let tracks, let parts):
            return "This performance has \(tracks) tracks for \(parts) parts, and "
                 + "the mixer cannot tell which is which."
        }
    }
}

final class PlaybackGraph {

    let engine = AVAudioEngine()
    private(set) var sequencer: AVAudioSequencer?
    private(set) var samplers: [AVAudioUnitSampler] = []
    /// `tracks[part.index + partTrackOffset]` is the part's track. Measured at
    /// load, never assumed -- see `trackOffset(trackCount:partCount:)`.
    private(set) var partTrackOffset = 0

    /// How far into `sequencer.tracks` the parts begin.
    ///
    /// music21 writes a conductor track ahead of the parts, and whether
    /// `AVAudioSequencer.tracks` includes it turned out to depend on the file:
    /// the score in Ali's video came back as four tracks for three parts, the
    /// first with no notes in it. The graph used to index by part and so wired
    /// every part to the sampler one too low -- the piano's left hand sounded
    /// with the voice's instrument, the voice fell to the default piano, and
    /// muting "Voice" muted the piano (2026-09-10).
    ///
    /// Zero or one extra track is explainable and mapped. Anything else is not
    /// understood, and wiring it anyway is how the wrong instrument lands on
    /// the wrong staff; nil, so the caller can refuse rather than guess.
    static func trackOffset(trackCount: Int, partCount: Int) -> Int? {
        let extra = trackCount - partCount
        return (0...1).contains(extra) ? extra : nil
    }
    private(set) var clickSampler: AVAudioUnitSampler?
    private(set) var clickTrack: AVMusicTrack?
    /// Which parts failed to load a sound bank. They still play, on the
    /// sampler's own default sound; refusing a whole arrangement because one
    /// staff is unusual is the wrong trade for a practice aid.
    private(set) var bankFailures: [Int] = []

    var isLoaded: Bool { sequencer != nil }

    /// Build the graph for a performance.
    ///
    /// Order matters and is not obvious: every sampler must be attached and
    /// connected BEFORE the sequencer loads, because a track's destination has
    /// to be part of a running graph for the sequencer to accept it.
    /// True when the app was launched by the UI-test harness.
    ///
    /// TWO SIGNALS, AND THE ENVIRONMENT IS THE ONE THAT HOLDS.
    ///
    /// This read `-seedTestLibrary` alone, on the reasoning that every UI test
    /// passes it and nothing else does. That was true when it was written and
    /// is not true now: `ScreenStaysLit`, `SetlistFromTheScore` and
    /// `SignInReachable` launch the app without it, and a test written tomorrow
    /// can forget it just as easily. The failure mode is not a red test -- it
    /// is music coming out of the machine's speakers while somebody is working,
    /// which is how this was found.
    ///
    /// So the deciding signal is `SCORANGER_SILENT_AUDIO`, set once in the
    /// scheme's test action as `TEST_RUNNER_SCORANGER_SILENT_AUDIO` (XCTest
    /// strips that prefix on the way into the app under test) and therefore
    /// carried by every `xcodebuild test` through this scheme, including
    /// `-only-testing:` runs and the gate's `test-without-building`. No
    /// individual test can forget what no individual test has to remember.
    /// The launch argument stays as a second path for an app started outside
    /// the scheme.
    ///
    /// This deliberately does not reach `ScorangerTests`, which measures real
    /// gain through `enableManualRenderingMode`; that bundle sets its own
    /// output volume explicitly so a silencing rule cannot quietly turn its
    /// assertions into `0 == 0`.
    static let silencedForTesting: Bool =
        ProcessInfo.processInfo.environment["SCORANGER_SILENT_AUDIO"] == "1"
        || ProcessInfo.processInfo.arguments.contains("-seedTestLibrary")

    func load(midi: URL, timeline: PlaybackTimeline,
              instruments: PlaybackInstruments = PlaybackInstruments()) throws {
        teardown()
        for part in timeline.parts {
            let sampler = AVAudioUnitSampler()
            engine.attach(sampler)
            engine.connect(sampler, to: engine.mainMixerNode, format: nil)
            let sound = instruments.resolved(for: part)
            if !loadInstrument(sampler, program: sound.program,
                               bankMSB: sound.bank.msb) {
                bankFailures.append(part.index)
            }
            samplers.append(sampler)
        }
        let click = AVAudioUnitSampler()
        engine.attach(click)
        engine.connect(click, to: engine.mainMixerNode, format: nil)
        _ = loadInstrument(click, program: PlaybackSound.clickProgram,
                           bankMSB: PlaybackSound.percussionBankMSB)
        clickSampler = click

        // A UI test drives real playback -- the transport, the mixer, the
        // playhead all need the clock running -- and on a developer's machine
        // that came out of the speakers while they were working. The graph is
        // built and run exactly as it ships; only the master output is turned
        // down, so every test still asserts what it always did.
        //
        // This cannot touch the offline assertions: those render through
        // `enableManualRenderingMode` into a buffer and never reach this
        // mixer, which is why they can still measure RMS and gain.
        if PlaybackGraph.silencedForTesting { engine.mainMixerNode.outputVolume = 0 }
        if !engine.isRunning { try engine.start() }
        let loaded = AVAudioSequencer(audioEngine: engine)
        try loaded.load(from: midi, options: [])
        guard let offset = Self.trackOffset(trackCount: loaded.tracks.count,
                                            partCount: timeline.parts.count) else {
            throw PlaybackGraphError.unexplainedTracks(tracks: loaded.tracks.count,
                                                       parts: timeline.parts.count)
        }
        partTrackOffset = offset
        for part in timeline.parts where part.index < samplers.count {
            loaded.tracks[part.index + offset].destinationAudioUnit = samplers[part.index]
        }
        // The click is a TRACK in the same sequence, not a timer beside it.
        // That is what makes it follow the tempo map -- a mid-score change
        // included -- without a line of code here, and what makes it unable to
        // drift away from the music over the length of a movement. It is also
        // what makes silencing the click the same operation as silencing a
        // viola, so one cannot accidentally do the other.
        let metronome = loaded.createAndAppendTrack()
        metronome.destinationAudioUnit = click
        for tick in timeline.clicks {
            let sound = PlaybackSound.click(down: tick.down)
            metronome.addEvent(
                AVMIDINoteEvent(channel: 0, key: UInt32(sound.key),
                                velocity: UInt32(sound.velocity), duration: 0.05),
                at: AVMusicTimeStamp(tick.beat))
        }
        clickTrack = metronome
        sequencer = loaded
    }

    /// Put a different sound on ONE channel, while the transport runs.
    ///
    /// No rebuild and no restart: `loadSoundBankInstrument` is per-node, each
    /// part already has its own sampler, and the sequencer's tracks point at
    /// those samplers rather than at a patch. So the graph, the clock and the
    /// play head are all untouched -- the reader hears the next note in the
    /// new sound and nothing skips.
    ///
    /// The one audible caveat, stated because it is a property of the sampler
    /// and not of this code: notes already ringing were rendered by the old
    /// patch and finish in it. Changing instrument under a held whole note is
    /// heard on the note after it.
    @discardableResult
    func setInstrument(program: UInt8, bank: GeneralMIDI.Bank,
                       channel: Int) -> Bool {
        guard samplers.indices.contains(channel) else { return false }
        let loaded = reseat(channel: channel, program: program, bank: bank)
        // The failure list is a live fact about the graph, not a log of what
        // happened during load: a channel that has just been given a sound
        // that works is no longer a channel with no sound.
        if loaded { bankFailures.removeAll { $0 == channel } }
        else if !bankFailures.contains(channel) { bankFailures.append(channel) }
        return loaded
    }

    /// Re-seat every channel's sound. Used when the whole mixer changes at
    /// once -- "every voice on a piano" -- so one pass replaces n rebuilds.
    func applyInstruments(_ instruments: PlaybackInstruments,
                          parts: [PlaybackTimeline.Part]) {
        for part in parts where part.index < samplers.count {
            let sound = instruments.resolved(for: part)
            setInstrument(program: sound.program, bank: sound.bank,
                          channel: part.index)
        }
    }

    /// Re-seat one channel's sound WITHOUT writing to the sampler that is
    /// rendering: a fresh unit is loaded off-graph and swapped in for it.
    ///
    /// `loadSoundBankInstrument` REPLACES a sampler's sample data and is not
    /// documented as real-time safe. Called while a voice sounds, it swaps the
    /// buffers that voice is walking and the render thread reads memory that is
    /// no longer there:
    ///
    ///     EXC_BAD_ACCESS (SIGSEGV) at 0x...ffffc -- four bytes below a
    ///     MALLOC_SMALL region -- in
    ///       ProcessMono <- Oscillator::Process <- VoiceZone::Process
    ///       <- SamplerNote::Render
    ///
    /// TestFlight 0.6.14 (173), reported as "Crash on playback": the reader
    /// changed an instrument in the mixer while the music ran. No Scoranger
    /// frame appears in the crashing thread, because the fault is a dangling
    /// sample pointer held by a voice rather than a bad call of ours.
    ///
    /// **THE SAMPLER FOR A CHANNEL IS NOT STABLE ACROSS THIS CALL.** Nothing
    /// may cache `samplers[i]`; read it again after any instrument change. That
    /// is the price of the fix and it is the whole reason it is written down
    /// here: five assertions in `PlaybackTimbreTests` measured a node that had
    /// been detached under them, and read as "the flute is silent".
    ///
    /// THREE CHEAPER FIXES WERE TRIED AND MEASURED. All three touch the live
    /// sampler and all three broke something a test already guarded:
    ///
    ///   - **A program change.** Inert. With or without bank select this
    ///     sampler's output is bit-identical afterwards (similarity 1.0 to
    ///     1e-6, iOS 26.5): `loadSoundBankInstrument` pins ONE preset per unit
    ///     and this is not a multi-preset bank player.
    ///     `testAProgramChangeDoesNotRePatchALoadedSampler` keeps the number.
    ///   - **Disconnect, load, reconnect.** Stops the music. The sequencer's
    ///     track targets this node, so taking it out of the graph halts the
    ///     transport and leaves the score silent.
    ///   - **All Sound Off, or `reset()`, before the load.** Silences the
    ///     sequencer's own playback on every channel --
    ///     `PlaybackInstrumentIsolationTests` renders four parts and got four
    ///     silences.
    ///
    /// So nothing is done TO the rendering unit. A new sampler is attached,
    /// loaded while nothing pulls it, connected, given the channel's fader, and
    /// named as its track's destination; only then is the old one detached.
    /// Attach, connect and detach are graph operations AVAudioEngine
    /// serialises against its own rendering -- the guarantee
    /// `loadSoundBankInstrument` does not offer.
    ///
    /// What the reader loses is the tail of a note already ringing on the
    /// channel being changed. The transport, the clock and the play head are
    /// untouched, which is what the picker wanted.
    ///
    /// NOT DEMONSTRATED BY A TEST, and worth saying plainly. The unit suite
    /// renders manually, pulling frames on the calling thread, so there is no
    /// concurrent render to race with. A real-time reproduction was written --
    /// engine running for real, four voices held per channel, instruments
    /// re-seated under them twelve rounds deep -- and it passed against the
    /// code that crashed, three runs out of three: the device faults inside
    /// `libEmbeddedSystemAUs.dylib` and the simulator does not use that
    /// sampler. It was deleted rather than kept, because a test that cannot
    /// fail is worse than no test. What stands behind this is the crash log and
    /// the absence of a real-time-safety guarantee; what the tests hold is that
    /// the music keeps playing, the mapping stays put, and the sound changes.
    /// Re-seat one channel's sound with the sequencer held still, because
    /// replacing sample data underneath a sounding voice is a crash.
    ///
    /// `loadSoundBankInstrument` REPLACES a sampler's sample data and is not
    /// documented as real-time safe. Called while a voice sounds, it swaps the
    /// buffers that voice is walking and the render thread reads memory that is
    /// no longer there:
    ///
    ///     EXC_BAD_ACCESS (SIGSEGV) at 0x...ffffc -- four bytes below a
    ///     MALLOC_SMALL region -- in
    ///       ProcessMono <- Oscillator::Process <- VoiceZone::Process
    ///       <- SamplerNote::Render
    ///
    /// TestFlight 0.6.14 (173), reported as "Crash on playback": the reader
    /// changed an instrument in the mixer while the music ran. No Scoranger
    /// frame appears in the crashing thread, because the fault is a dangling
    /// sample pointer held by a voice rather than a bad call of ours.
    ///
    /// So the sequencer stops generating voices for the length of the load and
    /// is put back on the beat it was on. The reader hears a hesitation on that
    /// channel; the play head does not move and the transport does not restart.
    ///
    /// FOUR OTHER FIXES WERE TRIED AND MEASURED ON THE iOS 26.5 RUNTIME. They
    /// are written down because every one of them is the obvious idea, and each
    /// costs an evening to rediscover:
    ///
    ///   - **A program change.** Inert. With or without bank select this
    ///     sampler's output is bit-identical afterwards (similarity 1.0 to
    ///     1e-6): `loadSoundBankInstrument` pins ONE preset per unit and this
    ///     is not a multi-preset bank player.
    ///     `testAProgramChangeDoesNotRePatchALoadedSampler` keeps the number.
    ///   - **Disconnect the node, load, reconnect.** Stops the music. The
    ///     sequencer's track targets this node, so taking it out of the graph
    ///     halts the transport and leaves the score silent.
    ///   - **All Sound Off (CC 120), or `reset()`, then load, node left in
    ///     place.** Silences the sequencer's playback on every channel;
    ///     `PlaybackInstrumentIsolationTests` renders four parts and got four
    ///     silences.
    ///   - **Attach a fresh sampler, load it off-graph, re-point the track,
    ///     detach the old one.** The cleanest on paper -- the rendering unit is
    ///     never written to -- and `AVAudioSequencer` refuses it: assigning
    ///     `destinationAudioUnit` while playing throws -10852. It also breaks
    ///     the invariant that a channel's sampler identity is stable, which
    ///     three tests in `PlaybackTimbreTests` rely on.
    ///
    /// NOT DEMONSTRATED BY A TEST, and worth saying plainly. The unit suite
    /// renders manually, pulling frames on the calling thread, so there is no
    /// concurrent render to race with and the crash cannot be reproduced. A
    /// real-time version was written -- engine running for real, four voices
    /// held per channel, instruments re-seated under them twelve rounds deep --
    /// and it passed against the code that crashed, three runs out of three:
    /// the device faults inside `libEmbeddedSystemAUs.dylib` and the simulator
    /// does not use that sampler. It was deleted rather than kept, because a
    /// test that cannot fail is worse than no test. What stands behind this fix
    /// is the crash log and the absence of a real-time-safety guarantee; what
    /// the tests hold is that the music keeps playing, from the same beat, and
    /// that the sound actually changes.
    private func reseat(channel: Int, program: UInt8,
                        bank: GeneralMIDI.Bank) -> Bool {
        let sampler = samplers[channel]
        guard engine.isRunning, let sequencer, sequencer.isPlaying else {
            // Nothing is generating voices, so there is nothing to race: the
            // plain load, which is what the graph build and the catalogue
            // tests take.
            return loadInstrument(sampler, program: program, bankMSB: bank.msb)
        }
        // Held in place, not restarted, so the reader hears a hesitation on one
        // channel rather than a jump. Measured: `stop()` leaves
        // `currentPositionInBeats` where it was and `start()` resumes from it,
        // so the assignment below changes nothing today -- it is kept because
        // that behaviour is not documented, and a test asserting the play head
        // is held cannot fail while it is implicit.
        let beat = sequencer.currentPositionInBeats
        sequencer.stop()
        let loaded = loadInstrument(sampler, program: program, bankMSB: bank.msb)
        sequencer.currentPositionInBeats = beat
        try? sequencer.start()
        return loaded
    }

    /// Put one program on one sampler, out of the bundled bank.
    ///
    /// A false here is what "this channel has no sound" means, and it is the
    /// whole reason the failure is recorded rather than thrown: a sampler that
    /// refused a load does not go quiet, it keeps whatever patch it had -- and
    /// with nothing ever loaded, that is `AVAudioUnitSampler`'s own built-in
    /// near-sine, identical on every channel. Silence would have been the
    /// louder bug report.
    ///
    /// No bank at all is the same answer, reached earlier. It cannot happen in
    /// a shipped build -- see `PlaybackSound.bank` -- and pretending to have
    /// attempted a load would put every channel back in the state this whole
    /// change exists to end.
    @discardableResult
    private func loadInstrument(_ sampler: AVAudioUnitSampler,
                                program: UInt8, bankMSB: UInt8) -> Bool {
        guard let bank = PlaybackSound.bank else { return false }
        do {
            try sampler.loadSoundBankInstrument(at: bank,
                                                program: program,
                                                bankMSB: bankMSB,
                                                bankLSB: PlaybackSound.bankLSB)
            return true
        } catch {
            return false
        }
    }

    func teardown() {
        sequencer?.stop()
        sequencer = nil
        clickTrack = nil
        bankFailures = []
        for sampler in samplers { engine.detach(sampler) }
        samplers = []
        if let clickSampler { engine.detach(clickSampler) }
        clickSampler = nil
        if engine.isRunning { engine.stop() }
    }

    // MARK: - The mixer

    /// Apply the whole mixer state at once.
    ///
    /// Mute and gain arrive together because they are one number to the graph
    /// (`PlaybackVoices.amplitude`). Applying them separately is how a mute
    /// gets overwritten by the next fader move.
    func apply(_ voices: PlaybackVoices, parts: [PlaybackTimeline.Part],
               metronome: Bool) {
        for part in parts where part.index < samplers.count {
            samplers[part.index].volume = Float(voices.amplitude(part.index))
        }
        // The track mute as well as the volume. Belt and braces on purpose: a
        // muted track sends no events at all, which is cheaper than rendering
        // notes at zero, and it is what makes `isMuted` readable in a test.
        if let sequencer {
            let muted = voices.mutedTracks(in: parts)
            for part in parts where part.index + partTrackOffset < sequencer.tracks.count {
                sequencer.tracks[part.index + partTrackOffset].isMuted = muted.contains(part.index)
            }
        }
        clickTrack?.isMuted = !metronome
    }
}
