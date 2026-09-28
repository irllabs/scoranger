import SwiftUI
import UIKit

/// The mixer as a window you can pick up.
///
/// design/MIXER_WINDOW.md, built. It replaces `MixerLayer`'s parking and the
/// shell of `MixerPanel`; the channel strip's internals -- fader, mute, LED,
/// sound chip -- keep their behaviour and their identifiers and lose their
/// fixed frames.
///
/// The three faults it exists to end, all measured rather than reported:
///
///   - **Not draggable.** The gesture was on the whole panel, where every
///     mute, fader and chip outranked it, and the ☰ that looked like a handle
///     was a Button that swallowed the touch. Measured: grabbing a fader moved
///     the panel 0.0pt, grabbing the body 0.0pt. Now one gesture lives on the
///     header's inert region and nothing on the body has one.
///   - **Cut off.** `panelWidth` was `8 + strips·64 + dividers`, so a
///     two-staff score computed 137pt while its header drew 198.5pt -- and
///     `origin` placed it by the number. 27pt hung off the right of a stock
///     13-inch Pro at normal text. Now the panel MEASURES itself and the
///     placement uses that measurement.
///   - **Rows that clip.** Every row was a fixed height around text that
///     scales: `.data` is 13.13pt at normal size in a 12pt value row. Now
///     rows take minimums and text takes `.fixedSize`.
struct MixerWindowLayer: View {
    @ObservedObject var state: AppState
    @ObservedObject var playback: PlaybackEngine
    var lanesInset: CGFloat

    /// Which strip's sound is being chosen. Above the panel because the panel
    /// changes size when the picker opens and this is what places it.
    @State private var picking: Int?
    /// The panel's ACTUAL size, reported by the panel itself. The whole point:
    /// placement can no longer disagree with what was drawn.
    @State private var measured: CGSize = .zero
    /// Live drag, in points, on top of the resolved origin. Zeroed on release
    /// once the final centre has been stored as a unit point.
    @State private var translation: CGSize = .zero
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
        GeometryReader { geo in
            // The container is not always the truth. Measured on iPhone 17 at
            // accessibility text, this GeometryReader reports ~697pt on a
            // 402pt screen -- so freeRect, the panel's maxWidth and the
            // anchored width were all computed from a container wider than the
            // device, and the list tier overflowed 139.5pt off EACH side while
            // every `.frame(maxWidth:)` looked like it was capping it. Three
            // separate attempts at the children changed the height and never
            // the width, which is what said the width was not theirs to give.
            //
            // The window can never be outside the screen whatever the
            // container claims, so the two are intersected. On iPad the
            // container is already right and this changes nothing.
            let free = MixerLayout.freeRect(container: geo.size,
                                            safeArea: geo.safeAreaInsets)
                .intersection(onScreen(geo))
            let tier = MixerLayout.tier(container: geo.size, text: textSize)
            let strip = MixerLayout.stripWidth(text: textSize)
            let panelWidth = MixerLayout.panelWidth(
                channels: playback.timeline.parts.count,
                stripWidth: strip, freeWidth: free.width,
                compact: MixerLayout.narrowRack(freeWidth: free.width,
                                                stripWidth: strip))
            let panel = MixerWindowPanel(
                playback: playback, tier: tier,
                width: panelWidth, picking: $picking,
                collapsed: $state.mixerCollapsed,
                placement: state.mixerPlacement,
                onClose: { state.mixerOpen = false },
                onPark: {
                    translation = .zero
                    state.mixerPlacement = .corner(state.mixerCorner.next)
                    state.mixerCorner = state.mixerCorner.next
                },
                drag: dragGesture(free: free))
                // The floor and the ceiling, both from the free rect: the
                // panel is never asked to be wider than the space it must fit
                // inside, which is the other half of "no clipping".
                // Sized to its CHANNELS (§12), not to its header and not to
                // the screen. This is the whole fix: a two-staff score is a
                // 184pt window, and a 184pt window has somewhere to go on a
                // 393pt phone -- so nothing has to be anchored, and the panel
                // that could not be dragged because it filled the width is
                // not filling the width.
                .frame(width: panelWidth)
                .fixedSize(horizontal: tier == .window, vertical: true)
                .background {
                    GeometryReader { inner in
                        Color.clear.preference(key: MixerMeasuredSize.self,
                                               value: inner.size)
                    }
                }
                .onPreferenceChange(MixerMeasuredSize.self) { size in
                    if size != .zero { measured = size }
                }

            switch tier {
            case .window:
                let size = measured == .zero
                    ? CGSize(width: MixerLayout.windowFloor,
                             height: MixerLayout.collapsedMinimum)
                    : measured
                let origin = resolved(size: size, free: free)
                panel.position(x: origin.x + size.width / 2,
                               y: origin.y + size.height / 2)
            case .list:
                // The one tier that is not a window, and the one that was
                // never about room: at an accessibility size the DAW layout
                // stops being legible at any width. Full width above whatever
                // chrome is showing -- the anchored-bar pattern from
                // NAV_MODAL_FREE_0.4.2, not a sheet.
                panel
                    .frame(width: max(free.width - 8, 0))
                    .position(x: free.midX,
                              y: free.maxY - lanesInset
                                 - (measured == .zero ? 120 : measured.height) / 2)
            }
        }
        // The mixer is drawn over the score and must not take the score's
        // touches with it: only the panel itself is hit-testable.
        .allowsHitTesting(true)
    }

    /// The part of this container that is actually on the screen, in the
    /// container's OWN coordinates.
    ///
    /// Both halves matter and only having the first is what left the panel
    /// 379pt wide and still at x = -131.5. The container here reports ~697pt
    /// on a 402pt iPhone AND sits at a negative global origin, so clamping the
    /// SIZE fixed the width while `free.midX` -- computed in container
    /// coordinates -- still pointed off the left edge.
    ///
    /// `geo.frame(in: .global)` gives the offset, so the screen rectangle can
    /// be expressed locally: its local origin is minus the container's global
    /// origin. Intersecting with that yields a free rect whose coordinates the
    /// container understands and whose bounds the screen does.
    ///
    /// On iPad the container already matches the screen and this is the
    /// identity, which is why every iPad measurement is unchanged by it.
    private func onScreen(_ geo: GeometryProxy) -> CGRect {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        guard let screen = scenes.first?.screen.bounds, screen.width > 0 else {
            return CGRect(origin: .zero, size: geo.size)
        }
        let global = geo.frame(in: .global)
        return CGRect(x: -global.minX, y: -global.minY,
                      width: screen.width, height: screen.height)
    }

    /// Where the panel sits, before the live drag is added.
    private func resolved(size: CGSize, free: CGRect) -> CGPoint {
        let base = MixerLayout.origin(for: state.mixerPlacement, panel: size,
                                      in: free, lanesInset: lanesInset)
        guard translation != .zero else { return base }
        return MixerLayout.clamp(
            origin: CGPoint(x: base.x + translation.width,
                            y: base.y + translation.height),
            panel: size, in: free)
    }

    /// The drag, and the reason it is handed DOWN to the header rather than
    /// attached here: the gesture must live on the header's inert region and
    /// nowhere else, so the panel body's controls are never competing with it.
    ///
    /// `onChanged` moves it live -- that is the jump-on-release fix -- and
    /// `onEnded` converts the final centre to a unit point of the free rect,
    /// which is what survives a rotation.
    private func dragGesture(free: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in translation = value.translation }
            .onEnded { value in
                let size = measured == .zero
                    ? CGSize(width: MixerLayout.windowFloor,
                             height: MixerLayout.collapsedMinimum)
                    : measured
                let base = MixerLayout.origin(for: state.mixerPlacement,
                                              panel: size, in: free,
                                              lanesInset: lanesInset)
                let landed = MixerLayout.clamp(
                    origin: CGPoint(x: base.x + value.translation.width,
                                    y: base.y + value.translation.height),
                    panel: size, in: free)
                let centre = CGPoint(x: landed.x + size.width / 2,
                                     y: landed.y + size.height / 2)
                state.mixerPlacement = .free(
                    MixerLayout.unitPoint(centre: centre, in: free))
                translation = .zero
            }
    }
}

/// The panel's own measurement, reported upward.
///
/// A preference rather than a binding written during layout: writing state
/// from inside a layout pass is how "Modifying state during view update"
/// warnings and layout loops start.
struct MixerMeasuredSize: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

// MARK: - The panel

/// The window's shell: a header you can pick it up by, and the performance
/// under it.
struct MixerWindowPanel<G: Gesture>: View {
    @ObservedObject var playback: PlaybackEngine
    let tier: MixerLayout.Tier
    /// The width the panel has been given, so the header can tell whether it
    /// can afford its words (§12). Passed in rather than measured: the header
    /// asking its own drawn width is what the 0.6.12 fix had to work around,
    /// and the width is decided above by `MixerLayout.panelWidth`.
    var width: CGFloat = MixerLayout.windowFloor
    @Binding var picking: Int?
    @Binding var collapsed: Bool
    let placement: MixerLayout.Placement
    var onClose: () -> Void
    var onPark: () -> Void
    let drag: G

    /// One text scale for the whole panel, so the strip's width and its rows
    /// grow together rather than one outrunning the other.
    @ScaledMetric(relativeTo: .caption) private var textUnit: CGFloat = 64

    private var parts: [PlaybackTimeline.Part] { playback.timeline.parts }
    private var stripWidth: CGFloat {
        MixerLayout.stripWidth(textScale: textUnit / 64)
    }
    /// The window can be picked up; the other two tiers have nowhere to go, so
    /// they carry neither the grab bar nor the park button (§4.2).
    private var movable: Bool { tier == .window }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !collapsed {
                Rectangle().fill(Theme.Line.line).frame(height: 1)
                if let index = picking, let part = parts.first(where: { $0.index == index }) {
                    // The picker swaps the BODY and never the header, which is
                    // what keeps the ✕ alive at every size (§6). It was the
                    // rack that vanished with it before.
                    MixerSoundPicker(playback: playback, part: part,
                                     onDone: { picking = nil })
                } else if tier == .list {
                    listBody
                } else {
                    rackBody
                }
                Rectangle().fill(Theme.Line.line).frame(height: 1)
                tempoRow
            }
            Rectangle().fill(Theme.Line.line).frame(height: 1)
            scrubberRow
        }
        .background(Theme.Surface.panel)
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Metric.rPanel)
                .stroke(Theme.Line.line2, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.rPanel))
        .modifier(PanelShadow())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mixer")
    }

    // MARK: - Header (§1)

    /// The header, and the only place in the panel with a drag on it.
    ///
    /// The gesture is on a BACKGROUND layer spanning the whole header, with
    /// the three trailing buttons drawn above it: a touch that lands on a
    /// button is a button press, anywhere else in the header is a drag. That
    /// is the spec's rule and it is what makes the drag findable -- the old
    /// panel's draggable surface was two small text labels.
    private var header: some View {
        ZStack {
            if movable {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(drag)
                    .accessibilityHidden(true)
            }
            HStack(spacing: 0) {
                if movable { grabBar }
                // §2's rule is VERTICAL fixedSize only. Bare `.fixedSize()`
                // fixes BOTH axes, so the header refused to compress and the
                // whole panel took its intrinsic width -- measured on iPhone
                // 17 at accessibility text: 681pt on a 402pt screen, 139.5pt
                // off each side. A parent cannot compress a child that will
                // not, so `.frame(maxWidth:)` above could do nothing about it.
                // THE WORDS APPEAR ONLY WHERE THE RACK HAS BOUGHT THE ROOM
                // (§12). At the floor -- a two-channel score, 184pt -- the
                // header is exactly its four 44pt controls and nothing else:
                // no title, no summary, no inert middle. Those words were the
                // whole reason the floor used to be 280, and 280 on a phone is
                // most of the screen, which is what made the panel full-width
                // and so anchored and so undraggable.
                if MixerLayout.headerShowsTitle(width: width) {
                    Text("MIXER").typeRole(.label)
                        .foregroundStyle(Theme.Accent.clayStrong)
                        .lineLimit(1)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(2)
                        .padding(.leading, movable ? 0 : Theme.Metric.s12)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("mixer-title")
                }
                // The identifier outlives the wording. It said "all voices"
                // and now says "3 of 4 voices", which is the spec's §1 header
                // -- but two older tests read `mixer-summary` to check the
                // mixer says what will be heard, and that contract is about
                // the element rather than its text.
                // The summary gives way first: the controls beside it and the
                // word MIXER are what the header cannot lose.
                if MixerLayout.headerShowsTitle(width: width) {
                    Text(voicesSummary).typeRole(.meta)
                    .foregroundStyle(Theme.Ink.ink3)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(0)
                    .padding(.leading, Theme.Metric.s8)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("mixer-summary")
                }
                Spacer(minLength: Theme.Metric.s8)
                collapseButton
                if movable { parkButton }
                closeButton
            }
        }
        .frame(minHeight: MixerLayout.headerMinimum)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mixer-header")
    }

    /// Three bars in a 44pt square, and NOT a button (§1.1).
    ///
    /// Accessibility-hidden on purpose: it duplicates the park button, and
    /// VoiceOver cannot drag anyway. That is exactly why the two are separate
    /// controls rather than one control with two meanings -- which is what the
    /// old ☰ was, and why a drag on it did nothing.
    private var grabBar: some View {
        VStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { _ in
                Rectangle().fill(Theme.Ink.ink3).frame(width: 20, height: 2)
            }
        }
        .frame(width: MixerLayout.controlSide, height: MixerLayout.controlSide)
        .background {
            RoundedRectangle(cornerRadius: Theme.Metric.rCtl)
                .fill(Theme.Surface.well)
                .frame(width: 32, height: 32)
                .opacity(0)
        }
        .contentShape(Rectangle())
        .gesture(drag)
        .accessibilityHidden(true)
        .accessibilityIdentifier("mixer-grab")
    }

    /// Park, with a glyph that previews where it is going (§1.2).
    private var parkButton: some View {
        Button(action: onPark) {
            ZStack {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Theme.Line.line2, lineWidth: 1)
                    .frame(width: 16, height: 12)
                Rectangle().fill(Theme.Accent.clay)
                    .frame(width: 6, height: 5)
                    .offset(x: nextCorner.previewOffset.x * 5,
                            y: nextCorner.previewOffset.y * 3.5)
            }
            .frame(width: MixerLayout.controlSide, height: MixerLayout.controlSide)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("mixer-park")
        .accessibilityLabel("Park the mixer")
        .accessibilityValue(currentCornerLabel)
        .accessibilityHint("Moves it to the next corner")
    }

    private var collapseButton: some View {
        Button { collapsed.toggle() } label: {
            Image(systemName: collapsed ? "chevron.up" : "chevron.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Ink.ink2)
                .frame(width: MixerLayout.controlSide,
                       height: MixerLayout.controlSide)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("mixer-collapse")
        .accessibilityLabel(collapsed ? "Expand the mixer" : "Collapse the mixer")
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Ink.ink2)
                .frame(width: MixerLayout.controlSide,
                       height: MixerLayout.controlSide)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("mixer-close")
        .accessibilityLabel("Close the mixer")
    }

    /// What will be heard, from the model rather than recomputed here.
    ///
    /// `PlaybackVoices.summary(in:metronome:)` already said this and the
    /// rebuild wrote its own version, which lost a product decision the older
    /// tests encode: every voice off is "metronome only" with the click on and
    /// "silent" with it off, because claiming a click that is not playing
    /// sends a reader hunting for a broken speaker. Two notions of one
    /// sentence is how that kind of thing goes missing.
    private var voicesSummary: String {
        playback.voices.summary(in: parts, metronome: playback.metronome)
    }

    private var nextCorner: MixerLayout.Corner {
        if case .corner(let corner) = placement { return corner.next }
        return .bottomTrailing
    }

    private var currentCornerLabel: String {
        if case .corner(let corner) = placement { return corner.label }
        return "moved"
    }

    // MARK: - The rack (§1.5, §3)

    /// The master column, then the strips, then the horizontal scroll.
    ///
    /// `All on` / `All off` sit OUTSIDE the scroll at the rack's leading edge:
    /// they operate every channel, so they must not scroll away with whichever
    /// strips happen to be in view. They left the header because the header
    /// cannot hold them at every width -- which is the fault this rebuild is
    /// for -- and this is where a mixer keeps its master anyway.
    private var rackBody: some View {
        HStack(spacing: 0) {
            masterColumn
            Rectangle().fill(Theme.Line.line).frame(width: 1)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(parts.enumerated()), id: \.element.index) { position, part in
                        if position > 0 {
                            Rectangle().fill(Theme.Line.line)
                                .frame(width: MixerLayout.dividerWidth)
                        }
                        MixerChannelStrip(playback: playback, part: part,
                                          label: label(for: part, at: position),
                                          width: stripWidth,
                                          onPickSound: { picking = part.index })
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var masterColumn: some View {
        VStack(spacing: 0) {
            masterButton("ALL\nON", identifier: "voices-all-on", on: true)
            Rectangle().fill(Theme.Line.line).frame(height: 1)
            masterButton("ALL\nOFF", identifier: "voices-all-off", on: false)
        }
        .frame(width: MixerLayout.masterColumnWidth)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mixer-master")
    }

    private func masterButton(_ title: String, identifier: String,
                              on: Bool) -> some View {
        Button {
            playback.voices.setAll(on: on, parts: parts)
        } label: {
            Text(title).typeRole(.label)
                .foregroundStyle(Theme.Accent.clayStrong)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .frame(minHeight: MixerLayout.masterButtonMinimum)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(on ? "All voices on" : "All voices off")
    }

    /// Distinct labels, the same rule the shipped panel used.
    private func label(for part: PlaybackTimeline.Part, at position: Int) -> String {
        let names = parts.map(\.name)
        _ = names
        let labels = PlaybackChannels.labels(for: parts)
        return labels[safe: position] ?? part.name
    }

    // MARK: - The list tier (§4.3)

    /// One channel per row, with a HORIZONTAL fader.
    ///
    /// A vertical fader with 33pt labels is not an object anyone can use, so
    /// at accessibility sizes the layout changes rather than the type
    /// shrinking. The DAW rack is a rendering of the model, not the model.
    private var listBody: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 0) {
                ForEach(Array(parts.enumerated()), id: \.element.index) { position, part in
                    if position > 0 {
                        Rectangle().fill(Theme.Line.line).frame(height: 1)
                    }
                    MixerChannelRow(playback: playback, part: part,
                                    label: label(for: part, at: position),
                                    onPickSound: { picking = part.index })
                }
                HStack(spacing: 0) {
                    masterButton("ALL ON", identifier: "voices-all-on", on: true)
                    Rectangle().fill(Theme.Line.line).frame(width: 1)
                    masterButton("ALL OFF", identifier: "voices-all-off", on: false)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("mixer-master")
            }
        }
        .frame(maxHeight: 420)
    }

    // MARK: - Tempo and the scrubber

    private var tempoRow: some View {
        HStack(spacing: Theme.Metric.s8) {
            Text("TEMPO").typeRole(.label)
                .foregroundStyle(Theme.Ink.ink3)
                .fixedSize(horizontal: false, vertical: true)
            MixerTempoSlider(playback: playback)
            // A minWidth for "300" at the current text size, not a flat 26pt:
            // the readout is the thing that truncated to "…" on Ali's iPad.
            Text("\(Int(playback.tempoBPM.rounded()))")
                .typeRole(.data)
                .foregroundStyle(Theme.Ink.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 30, alignment: .trailing)
                .accessibilityIdentifier("mixer-tempo-value")
        }
        .padding(.horizontal, Theme.Metric.s12)
        .frame(minHeight: MixerLayout.tempoRowMinimum)
    }

    private var scrubberRow: some View {
        HStack(spacing: Theme.Metric.s8) {
            Text(clock(playback.beat)).typeRole(.data)
                .foregroundStyle(Theme.Ink.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("mixer-elapsed")
            MixerScrubber(playback: playback)
            Text(clock(playback.timeline.beats)).typeRole(.data)
                .foregroundStyle(Theme.Ink.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("mixer-total")
        }
        .padding(.horizontal, Theme.Metric.s12)
        .frame(minHeight: MixerLayout.scrubberRowMinimum)
    }

    private func clock(_ beats: Double) -> String {
        let seconds = Int((beats / max(playback.tempoBPM, 1) * 60).rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension MixerLayout.Corner {
    /// Which way the park glyph's block sits, as a unit offset.
    var previewOffset: CGPoint {
        switch self {
        case .bottomTrailing: return CGPoint(x: 1, y: 1)
        case .bottomLeading:  return CGPoint(x: -1, y: 1)
        case .topLeading:     return CGPoint(x: -1, y: -1)
        case .topTrailing:    return CGPoint(x: 1, y: -1)
        }
    }
}

/// The panel's shadow, through the design system's own helper rather than a
/// second set of numbers beside it.
private struct PanelShadow: ViewModifier {
    func body(content: Content) -> some View { Theme.Elevation.panel(content) }
}
