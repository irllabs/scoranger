import SwiftUI

/// The tray (design/DESIGN_SYSTEM.md §7.7): one 56pt line under the score
/// that IS the transport and the mixer.
///
/// Left to right: the set list step and prev/next · play, to start, click,
/// loop · one knob per part, then the tempo knob · the position in mono and,
/// while playing, the seek scrubber · at the right, all-on/all-off. More parts
/// than fit scroll sideways inside the knob slot under a fade; tempo and the
/// position stay put. A scan being converted shows its progress in More and
/// nowhere else (0.8.0 build 194, Ali's item 2: the tray had a second copy);
/// the tray is the transport, or the reason there is none.
///
/// It replaces `ScoreFooter`'s Transport and the mixer WINDOW -- the thing
/// that could be dragged, parked, clamped and collapsed. Nothing here moves.
/// The knob's anatomy (MIXER_WINDOW.md §13, `MixerKnob`) is kept: the arc is
/// the level, the LED in the centre is whether the part sounds, and in 0.8
/// tapping that LED is the mute [C3].
///
/// The tray is always there while reading; performance mode slides it off
/// with the bar (§5). There is no "show transport" any more.
struct Tray: View {
    /// "2 of 6" -- the step through the set list being played, or nil.
    let setlistLabel: String?
    var canStep: Bool
    var onPrevious: () -> Void
    var onNext: () -> Void

    @ObservedObject var playback: PlaybackEngine
    var unavailable: PlaybackAvailability = .available
    var preparing: Bool
    var onPlay: () -> Void
    var onResolve: () -> Void = {}
    /// The phone's merged page scrubber (§9.6), until the phone layout of 0.8.4.
    var leading: AnyView?
    /// While the ink tools are out the tray rests at half (§7.14).
    var dimmed = false

    @Environment(\.dynamicTypeSize) private var typeSize
    /// A phone has no room for the running clock and the scrubber beside the
    /// knobs: with them the line outgrew the screen while playing, and being
    /// centred it pushed play/stop off the LEFT edge -- found photographing
    /// the App Store screenshots on a 6.5" iPhone, where Stop could not be
    /// tapped. A phone's position bar sits above the tray already.
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var hasRoomForTheClock: Bool { sizeClass != .compact }

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                // SC15 / §12: at accessibility sizes the one line is wider
                // than a screen, and nothing grows downward -- so the line
                // scrolls sideways, play and the knobs first.
                ScrollView(.horizontal, showsIndicators: false) {
                    line.fixedSize(horizontal: true, vertical: false)
                }
            } else {
                // The same rule wherever the line is wider than the screen: a
                // phone with a quartet open has a knob per part, and centred
                // the line pushed play off the left edge before anything
                // played (PhoneTransport). When it fits, it is drawn as it
                // always was.
                ViewThatFits(in: .horizontal) {
                    line
                    ScrollView(.horizontal, showsIndicators: false) {
                        line.fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
        }
            .padding(.horizontal, Theme.Metric.s16)
            .frame(minHeight: Theme.Metric.transportHeight)
            // LIKE THE TOP BAR (Ali, 2026-09-14 item 9). It was inset 16 from
            // each edge with `rPage` top corners, so it read as a drawer
            // sliding out of the bottom of a card while the bar above it was a
            // flat full-width strip with a rule under it. The two are the same
            // kind of thing -- the screen's chrome -- and now look it: full
            // width, square, a rule on the edge facing the music, and the fill
            // carried under the home indicator the way the bar's is carried
            // under the status bar.
            .background(Theme.Surface.panel.ignoresSafeArea(edges: .bottom))
            .overlay(alignment: .top) { Theme.Rule() }
            .opacity(dimmed ? 0.5 : 1)
            .background(alignment: .leading) { spaceKey }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("transport")
    }

    // MARK: - the one line

    @ViewBuilder
    private var line: some View {
        HStack(spacing: Theme.Metric.s8) {
            if let leading {
                leading.frame(maxWidth: .infinity)
                Theme.Rule(vertical: true).frame(height: 20)
            }
            if let setlistLabel {
                Text(setlistLabel).typeRole(.data).foregroundStyle(Theme.Ink.ink2)
                    .accessibilityIdentifier("transport-setlist")
                stepButton("chevron.left", label: "Previous in set list",
                           id: "transport-prev", enabled: canStep, action: onPrevious)
                stepButton("chevron.right", label: "Next in set list",
                           id: "transport-next", enabled: canStep, action: onNext)
                Theme.Rule(vertical: true).frame(height: 20)
            }

            if !unavailable.canPlay || playback.unavailable != nil {
                unavailableRow
                Spacer(minLength: 0)
            } else {
                playControls
                Theme.Rule(vertical: true).frame(height: 20)
                knobs.layoutPriority(2)
                Theme.Rule(vertical: true).frame(height: 20)
                position.fixedSize().layoutPriority(1)
                if playback.isPlaying && hasRoomForTheClock {
                    TrayScrubber(playback: playback)
                        .frame(minWidth: 60, maxWidth: 220)
                } else {
                    Spacer(minLength: 0)
                }
                allOnOff
            }
        }
    

    }

    // MARK: - transport

    @ViewBuilder
    private var playControls: some View {
        Button(action: onPlay) {
            Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Theme.Accent.clayPress)
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(preparing)
        .opacity(preparing ? 0.45 : 1)
        .accessibilityIdentifier("transport-play")
        .accessibilityLabel(playback.isPlaying ? "Stop" : "Play")

        capsule("backward.end.alt.fill", label: "To the start", id: "transport-rewind",
                on: false) { playback.rewind() }
        capsule("metronome", label: "Click", id: "transport-metronome",
                on: playback.metronome) { playback.metronome.toggle() }
        capsule("repeat", label: "Loop", id: "transport-loop",
                on: playback.loop) { playback.loop.toggle() }
    }

    @ViewBuilder
    private var unavailableRow: some View {
        let engineFailure = playback.unavailable
        HStack(spacing: Theme.Metric.s8) {
            Text(engineFailure ?? unavailable.message)
                .typeRole(.meta).foregroundStyle(Theme.Ink.ink3).lineLimit(1)
                .accessibilityIdentifier("transport-unavailable")
            if engineFailure == nil, let title = unavailable.actionTitle {
                Button(action: onResolve) {
                    Text(title).typeRole(.control).foregroundStyle(Theme.Accent.clayStrong)
                        .padding(.horizontal, Theme.Metric.s12).frame(height: 32)
                        .background(Theme.Surface.well).clipShape(Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("transport-resolve")
            }
            if engineFailure == nil, unavailable.warnsItIsADraft {
                Text("draft").typeRole(.data).foregroundStyle(Theme.Ink.ink3)
                    .accessibilityIdentifier("transport-draft-warning")
            }
        }
        .accessibilityIdentifier(unavailable.identifier)
    }

    // MARK: - knobs

    /// One knob per part in a slot that scrolls sideways under a fade when
    /// there are more than fit; the tempo knob outside it, so it stays put.
    private var knobs: some View {
        HStack(spacing: Theme.Metric.s8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Metric.s6) {
                    ForEach(playback.timeline.parts, id: \.index) { part in
                        TrayPartKnob(playback: playback, part: part)
                    }
                }
            }
            .mask {
                // The fade at the end of an overflowing slot (§4).
                HStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 18)
                }
            }
            .frame(width: TrayLayout.knobSlotMaxWidth(parts: playback.timeline.parts.count))
            TrayTempoKnob(playback: playback)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tray-knobs")
    }

    // MARK: - position

    private var position: some View {
        HStack(spacing: Theme.Metric.s6) {
            if preparing {
                Text("preparing…").typeRole(.meta).foregroundStyle(Theme.Ink.ink3)
                    .accessibilityIdentifier("transport-preparing")
            } else {
                Text(playback.soundingBar.map { "bar \($0)" } ?? "bar —")
                    .typeRole(.data).fontWeight(.semibold).foregroundStyle(Theme.Ink.ink)
                    .monospacedDigit()
                    .frame(minWidth: 54, alignment: .leading)
                    .accessibilityIdentifier("transport-bar")
                if playback.isPlaying && hasRoomForTheClock {
                    Text("· \(clock(playback.beat)) / \(clock(playback.timeline.beats))")
                        .typeRole(.data).foregroundStyle(Theme.Ink.ink3).monospacedDigit()
                        .accessibilityIdentifier("mixer-elapsed")
                }
            }
        }
        .fixedSize()
    }

    /// The tempo the position is read at is the one the music is played at.
    private func clock(_ beats: Double) -> String {
        let seconds = Int((beats / max(playback.tempoBPM, 1) * 60).rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - all on / all off

    /// One glyph, at the right: every part on when any is off, otherwise
    /// every part off. Its identifier says which it will do, because the two
    /// used to be two buttons and the tests address them by what they do.
    private var allOnOff: some View {
        let parts = playback.timeline.parts
        let anyOff = parts.contains { !playback.voices.isOn($0.index) }
        return Button {
            playback.voices.setAll(on: anyOff, parts: parts)
        } label: {
            Image(systemName: anyOff ? "speaker.wave.2" : "speaker.slash")
                .font(.system(size: 13))
                .foregroundStyle(Theme.Ink.ink2)
                .frame(width: 32, height: 32)
                .background(Theme.Surface.well)
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(anyOff ? "voices-all-on" : "voices-all-off")
        .accessibilityLabel(anyOff ? "All voices on" : "All voices off")
        // What will be heard -- "all voices", "3 of 4 voices", "silent",
        // "metronome only". The mixer header's summary, carried by the one
        // control that changes all of it at once.
        .accessibilityValue(playback.voices.summary(in: parts, metronome: playback.metronome))
    }

    // MARK: - pieces

    private func capsule(_ glyph: String, label: String, id: String, on: Bool,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: glyph).font(.system(size: 13))
                .foregroundStyle(on ? Theme.Accent.clayStrong : Theme.Ink.ink2)
                .frame(width: 32, height: 32)
                .background(on ? Theme.Accent.clayTint : Theme.Surface.well)
                .clipShape(Circle())
                .overlay { Circle().strokeBorder(on ? Theme.Accent.clay : Color.clear, lineWidth: 1.5) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityLabel(label)
        .accessibilityValue(on ? "on" : "off")
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : [.isButton])
    }

    private func stepButton(_ glyph: String, label: String, id: String,
                            enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: glyph).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(enabled ? Theme.Ink.ink : Theme.Ink.ink3)
                .frame(width: 32, height: 32)
                .background(Theme.Surface.well)
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityIdentifier(id)
        .accessibilityLabel(label)
    }

    /// The spacebar, as in every DAW. It lives on the tray so it exists
    /// exactly while the transport does, and never swallows a space typed
    /// into a text field (`TransportKeys`).
    private var spaceKey: some View {
        Button("Play or stop") {
            guard TransportKeys.spaceToggles(
                    isEditingText: KeyboardFocus.isEditingText,
                    isTransportShowing: true,
                    canPlay: unavailable.canPlay && playback.unavailable == nil && !preparing)
            else { return }
            onPlay()
        }
        .keyboardShortcut(.space, modifiers: [])
        .frame(width: 1, height: 1)
        .opacity(0)
        .accessibilityHidden(true)
        .accessibilityIdentifier("transport-space-key")
    }
}

// MARK: - Layout

enum TrayLayout {
    /// A knob group is 44 wide with 6 between; the slot shows up to six
    /// before it scrolls (SC15 draws nine parts as six and a fade).
    static let knobGroup: CGFloat = 44
    static let knobGap: CGFloat = 6
    static let knobsShown = 6

    static func knobSlotMaxWidth(parts: Int) -> CGFloat {
        let shown = min(max(parts, 1), knobsShown)
        return CGFloat(shown) * knobGroup + CGFloat(max(shown - 1, 0)) * knobGap + 18
    }
}

// MARK: - A part's knob

/// The 32pt dial with its LED-as-mute in the centre and "Vln I 7" under it,
/// in a 44pt group (§7.8). The dial and its gesture are `MixerKnob`'s; what
/// is new is that the LED is a button and the label opens the sound picker.
struct TrayPartKnob: View {
    @ObservedObject var playback: PlaybackEngine
    let part: PlaybackTimeline.Part
    @State private var choosingSound = false

    private var isOn: Bool { playback.voices.isOn(part.index) }
    /// The lamp follows the MUSIC, muted or not: the staff is still playing
    /// and the reader cannot hear it, which is how they confirm the mute is
    /// working -- the dial dims around a lit lamp (§7.8).
    private var isSounding: Bool { part.isSounding(at: playback.beat) }
    private var patch: (program: UInt8, bank: GeneralMIDI.Bank) { playback.instrument(for: part) }
    private var chosen: Bool { playback.hasChosenInstrument(for: part) }

    var body: some View {
        VStack(spacing: 2) {
            MixerKnob(playback: playback, part: part) {
                Button {
                    playback.voices.toggle(part.index)
                } label: {
                    MixerLED(on: isSounding, part: part)
                        .frame(width: 20, height: 20)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                // A CONTAINER, so the LED inside keeps its own identifier and
                // value ("sounding: yes/no") for the tests and VoiceOver that
                // read the lamp separately from the mute.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("strip-mute-\(part.index)")
                .accessibilityLabel("\(part.name), mute")
                // The value is the MUTE's state, as it was on the strip: "off"
                // while the part sounds. Tests read it, so it is a contract.
                .accessibilityValue(isOn ? "off" : "on")
            }
            .opacity(isOn ? 1 : 0.5)
            Button { choosingSound = true } label: {
                HStack(spacing: 3) {
                    Text(TrayLayout.shortName(part.name)).typeRole(.knobLabel)
                        .foregroundStyle(Theme.Ink.ink2).lineLimit(1)
                    Text("\(playback.voices.fader(part.index))").typeRole(.knobData)
                        .foregroundStyle(Theme.Ink.ink3).fixedSize()
                }
                .frame(maxWidth: TrayLayout.knobGroup + 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("strip-sound-\(part.index)")
            .accessibilityLabel("\(part.name), sound")
            // "automatic" and not "from the staff name" (MixerWindowStrips'
            // note, kept): the suffix is a contract a test reads.
            .accessibilityValue(GeneralMIDI.name(program: patch.program, bank: patch.bank)
                                + (chosen ? ", chosen" : ", automatic"))
            .accessibilityHint("Opens the list of sounds")
            .popover(isPresented: $choosingSound) {
                MixerSoundPicker(playback: playback, part: part) { choosingSound = false }
                    .frame(width: 320, height: 420)
            }
        }
        .frame(width: TrayLayout.knobGroup)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("strip-\(part.index)")
        .accessibilityLabel(part.name)
    }
}

extension TrayLayout {
    /// "Violin I" -> "Vln I", the way a desk labels a channel. Only the words
    /// a player abbreviates; anything else is left as it is and truncated.
    static func shortName(_ name: String) -> String {
        let table: [(String, String)] = [
            ("Violoncello", "Vc"), ("Violin", "Vln"), ("Viola", "Vla"), ("Contrabass", "Cb"),
            ("Double Bass", "Db"), ("Clarinet", "Cl"), ("Trumpet", "Tpt"), ("Trombone", "Tbn"),
            ("Accordion", "Acc"), ("Piano", "Pno"), ("Guitar", "Gtr"), ("Flute", "Fl"),
            ("Oboe", "Ob"), ("Bassoon", "Bsn"), ("Horn", "Hn"), ("Soprano", "S"),
            ("Alto", "A"), ("Tenor", "T"), ("Bass", "B"),
        ]
        var out = name
        for (long, short) in table where out.localizedCaseInsensitiveContains(long) {
            out = out.replacingOccurrences(of: long, with: short, options: .caseInsensitive)
        }
        return out
    }
}

// MARK: - The tempo knob

/// The same dial in `ink2`, no LED, "tempo 120" under it. Drag to set the
/// tempo -- up or right is faster, down or left slower (TempoDrag: it sits on
/// the bottom edge) -- and double-tap returns to the score's marking (§7.8).
struct TrayTempoKnob: View {
    @ObservedObject var playback: PlaybackEngine
    /// The tempo the drag began at. GESTURE state, so a drag the system
    /// cancels -- which does not call `onEnded` -- cannot leave a stale start
    /// behind for the next one.
    @GestureState private var startBPM: Double?
    @Environment(\.dynamicTypeSize) private var typeSize

    private static let range: ClosedRange<Double> = 30...480

    var body: some View {
        let face = MixerLayout.knobFace(text: typeSize)
        let progress = (playback.tempoBPM - Self.range.lowerBound)
            / (Self.range.upperBound - Self.range.lowerBound)
        VStack(spacing: 2) {
            ZStack {
                Circle().fill(Theme.Surface.panel)
                arc(to: 1, colour: Theme.Surface.well, face: face)
                arc(to: min(max(progress, 0), 1), colour: Theme.Ink.ink2, face: face)
            }
            .frame(width: face, height: face)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($startBPM) { _, start, _ in
                        if start == nil { start = playback.tempoBPM }
                    }
                    .onChanged { move in
                        // Up OR RIGHT is faster (TempoDrag): the knob is on
                        // the bottom edge, where down has no room.
                        let bpm = TempoDrag.bpm(start: startBPM ?? playback.tempoBPM,
                                                translation: move.translation)
                        playback.setTempo(min(max(bpm.rounded(), Self.range.lowerBound),
                                              Self.range.upperBound))
                    })
            .onTapGesture(count: 2) { playback.clearTempo() }
            HStack(spacing: 3) {
                Text("tempo").typeRole(.knobLabel).foregroundStyle(Theme.Ink.ink2)
                Text("\(Int(playback.tempoBPM.rounded()))").typeRole(.knobData)
                    .foregroundStyle(Theme.Ink.ink3).monospacedDigit()
            }
            .fixedSize()
        }
        .frame(width: TrayLayout.knobGroup + 8)
        .accessibilityElement()
        .accessibilityIdentifier("transport-tempo")
        .accessibilityLabel("Tempo")
        .accessibilityValue(PlaybackTempo.label(bpm: playback.tempoBPM,
                                                fromScore: playback.timeline.tempoFromScore,
                                                overridden: playback.tempoOverride != nil))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: playback.setTempo(min(playback.tempoBPM + 2, Self.range.upperBound))
            case .decrement: playback.setTempo(max(playback.tempoBPM - 2, Self.range.lowerBound))
            @unknown default: break
            }
        }
    }

    private func arc(to: Double, colour: Color, face: CGFloat) -> some View {
        let sweep = MixerLayout.knobSweep / 360
        return Circle()
            .trim(from: 0, to: to * sweep)
            .stroke(colour, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .rotationEffect(.degrees(MixerLayout.knobStartAngle - 90))
            .frame(width: face - 3, height: face - 3)
            .accessibilityHidden(true)
    }
}

// MARK: - The seek scrubber, while playing

struct TrayScrubber: View {
    @ObservedObject var playback: PlaybackEngine

    var body: some View {
        GeometryReader { geo in
            let total = max(playback.timeline.beats, 1)
            let fraction = min(max(playback.beat / total, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.Surface.well).frame(height: 4)
                Capsule().fill(Theme.Accent.clay).frame(width: geo.size.width * fraction, height: 4)
                Circle().fill(Theme.Accent.clay).frame(width: 14, height: 14)
                    .overlay { Circle().strokeBorder(Theme.Surface.panel, lineWidth: 2) }
                    .offset(x: (geo.size.width - 14) * fraction)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                playback.seek(toBeat: total * min(max(value.location.x / max(geo.size.width, 1), 0), 1))
            })
        }
        .frame(height: 24)
        .accessibilityElement()
        .accessibilityIdentifier("mixer-scrubber")
        .accessibilityLabel("Position")
        .accessibilityValue(playback.soundingBar.map { "bar \($0)" } ?? "start")
    }
}
