import PDFKit
import PencilKit
import OSLog
import SwiftUI

/// The score as a vertical stack of pages with a PencilKit canvas over each:
/// the Apple Pencil draws, fingers scroll. Drawings persist per score+version+page.
/// Two-finger pinch zooms (0.5×–3×) about the midpoint between the fingers,
/// via UIScrollView; when the pinch settles the pages re-render crisply at the
/// new size.
/// Highlight mode (score gear menu) turns strokes on a page into an
/// estimated bar range handed to the chat as targeting context.
struct ScorePagesView: View {
    let document: PDFDocument
    let annotationKey: String  // "<score uid>/<version id>", see DrawingStore
    /// The band's marks, by page index, when this score is open as an entry in
    /// a shared set list. Empty for an arrangement of your own and for every
    /// signed-out reader (design/FIREBASE.md §6.3).
    var sharedInk: [Int: [SharedInk.Layer]] = [:]
    /// The same page, named the way a person names it: "<slug>/<version id>".
    ///
    /// It exists because `annotationKey` stopped being readable. Markup is
    /// filed under the score's uid so it survives a rename and means the same
    /// thing on the device a bundle is opened on (DrawingStore), and the
    /// canvas's accessibility identifier was built out of that same key --
    /// so it turned into `canvas-01M1QV99.../01M1.../p0`, which no test can
    /// predict and no human can read.
    ///
    /// Identity for the store, a readable name for the identifier: the same
    /// split the version rows make between an opaque id and `v012`.
    let canvasIdentity: String

    @EnvironmentObject var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Settled zoom scale, used ONLY to raise the raster resolution of the
    /// rendered pages. Geometry is fixed and the live zoom is UIScrollView's
    /// transform, which is what keeps the canvas from jumping on release.
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var rasterZoom: CGFloat = 1.0
    /// The canvas under the fingertip while a press is live (§9.2).
    @State private var loupe: LoupeSample?
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverRunning
    /// The viewport in content coordinates, and the rows worth drawing at
    /// depth. Everything else renders at a cheap scale.
    /// The visible rect, observed by the few views that need it rather than
    /// held here (see `ViewportModel`).
    @StateObject private var viewport = ViewportModel()
    /// The unit last shown, so a turn knows which way it is going before the
    /// new unit's slide is chosen (`PageTurn.slide`).
    @State private var shownIndex = 0
    /// Continuous mode's tap zones ask the scroll view to move directly, since
    /// there is no page index for them to change. The token makes the same
    /// destination asked for twice still move.
    @State private var scrollToken = 0
    @State private var scrollTargetX: CGFloat = 0
    /// The laid-out width of the continuous strip, so a tap knows where the
    /// end of the music is.
    @State private var surfaceWidth: CGFloat = 0
    /// Surface points per unit of the ENGRAVING's own coordinates, kept here so
    /// the sync chip -- which lives outside the GeometryReader that computes it
    /// -- measures against the same strip the canvas drew.
    @State private var engravedScale: CGFloat = 1
    /// Pencil markup: the shared controller, driven from the top bar.
    private var annotation: AnnotationController { state.annotation }
    /// What the Pencil means right now (§6). Selection is OFF in performance
    /// mode, which is what frees the Pencil to turn pages.
    var mode: ScoreMode = .read
    /// Where the sound has got to. OBSERVED, because AppState publishes nothing
    /// when the play head moves and a canvas reading it through AppState would
    /// never follow -- the same fix the ink bar needed.
    @ObservedObject var playback: PlaybackEngine
    /// Where a page turn is scrolling to, if one is in flight.
    @State private var scrollTarget: CGFloat?
    /// The channel the play head moves the strip through. Not SwiftUI state:
    /// following the music must not invalidate this view twenty times a second
    /// (see CanvasScroller).
    @State private var scroller = CanvasScroller()
    /// The viewport the continuous strip is FITTED to, which is not always the
    /// viewport it has -- see `ContinuousTiles.fittingViewport`. A panel that
    /// takes height off the canvas must not re-scale the music, because a
    /// re-scaled strip is a fresh raster for every tile of it.
    @State private var fittedTo: CGSize = .zero
    @State private var fittedDocument: String = ""

    /// Fit to twelve, ON A PAGE.
    ///
    /// The floor is FIT, not 0.5: the unit on screen is sized to fit the
    /// viewport, so zooming out below 1 would only add ground around it -- and
    /// it is what makes "you can never see more than two pages" true without
    /// anything enforcing it. The ceiling stays 12 so a notehead can be
    /// inspected; the page re-rasters at the settled scale.
    private static let zoomRange: ClosedRange<CGFloat> =
        PagedCanvas.minimumZoom...PagedCanvas.maximumZoom

    /// And the range the SCROLL view gets, which is not the same range.
    ///
    /// The paragraph above is a paged argument and it was being applied to the
    /// strip, where it is false: the strip is fitted by HEIGHT and runs off
    /// the screen sideways, so below 1 there is not ground, there is more
    /// music. The reader was stopped at one system filling the canvas and
    /// UIScrollView bounced anything past it straight back -- one cause, and
    /// the two things Ali described.
    ///
    /// `ContinuousTiles.minimumZoom` derives the floor from the strip's own
    /// fitted height, so it goes as far out as the music allows and no
    /// further.
    private func zoomRange(continuous: Bool,
                           stripHeight: CGFloat) -> ClosedRange<CGFloat> {
        guard continuous else { return Self.zoomRange }
        let floor = ContinuousTiles.minimumZoom(fittedStripHeight: stripHeight)
        return floor...PagedCanvas.maximumZoom
    }

    /// Room the canvas keeps clear at the bottom: 50pt of pill, its 20pt bottom
    /// padding and 12 of breathing room. The pill floats over the canvas and
    /// the score must never be under it.
    ///
    /// Read by BOTH the fit and the scroll view, from here, because when the
    /// two disagreed the page was fitted to height the scroll view had already
    /// given away: the unit filled the canvas, the scroll view added this as a
    /// bottom inset anyway, and the top of the page scrolled off (L21).
    /// Moved to SpreadLayout, where the margin already lived and where the
    /// test bundle can see it. Kept as a spelling so the call sites below read
    /// the way they always did.
    static var bottomChrome: CGFloat { SpreadLayout.bottomChrome }

    static func bottomChrome(for viewport: CGSize) -> CGFloat {
        SpreadLayout.bottomChrome(for: viewport)
    }

    var body: some View {
        GeometryReader { geo in
            let continuous = state.layout.isContinuous
            // The strip is ONE Verovio page with no system breaks; page 0 is
            // the whole score.
            let stripPage = continuous ? document.page(at: 0) : nil
            let stripBox = stripPage?.bounds(for: .mediaBox).size ?? .zero
            // NOT geo.size. The strip is fitted by height, so a band or a bar
            // opening over the canvas would otherwise re-scale the whole score
            // and redraw every tile of it.
            let fitViewport = fittedTo == .zero ? geo.size : fittedTo
            let stripScale = ContinuousTiles.fittedScale(
                pageSize: stripBox, viewport: fitViewport,
                bottomChrome: Self.bottomChrome(for: fitViewport))
            let surface = CGSize(width: stripBox.width * stripScale,
                                 height: stripBox.height * stripScale)
            // The geometry is in the SVG's viewBox units, not the PDF's points
            // -- 383690 wide against 16970 for the same strip. Everything that
            // meets the geometry (the play head, the bar readout) converts
            // through THIS, and everything that meets the PDF (the tiles) uses
            // stripScale. Mixing them put the play head 22 times too far into
            // the piece: it left the screen in the first bar.
            let strip = state.geometry?.page(0)
            let engraved = surface.width / max(strip?.size.width ?? 0, 1)
            let spread = state.twoPageSpread
            let unit = PagedCanvas.unit(at: state.pageIndex,
                                        pageCount: document.pageCount, spread: spread)
            let width = PagedCanvas.fittedPageWidth(
                viewport: geo.size, pageAspect: aspect(of: unit.first),
                pages: max(unit.count, 1), gutter: SpreadLayout.gutter,
                margin: SpreadLayout.margin(for: geo.size),
                // the same reserve the scroll view below is given, from one
                // function: the two disagreeing is the whole of L21
                bottomChrome: Self.bottomChrome(for: geo.size))
            ZoomableScroll(contentWidth: continuous
                               ? surface.width
                               : width * CGFloat(max(unit.count, 1))
                                   + SpreadLayout.gutter * CGFloat(max(unit.count - 1, 0)),
                           onLasso: { page, path, adding in
                               select(path: path, onPage: page, adding: adding)
                           },
                           onUndoTap: { _ = annotation.undo() },
                           onTap: { page, point, taps, fingerHeld in
                               state.handleTap(at: point, onPage: page, taps: taps,
                                               modifierFingerDown: fingerHeld)
                           },
                           onWillReplaceSelection: { state.clearSelection() },
                           onCanvasTap: { touch in
                               canvasTap(touch)
                           },
                           // The recogniser has already asked the same
                           // question -- `allowsPress` -- before raising a
                           // press at all, so this is the sample arriving,
                           // not a second policy.
                           onLoupe: { sample in loupe = sample },
                           // SWIPE-TO-TURN, wired in 0.8.0 build 196 (Ali, in
                           // performance mode: "I can't swipe to the next page").
                           // It was left unwired in 0.6.14 as half-finished;
                           // the two halves it lacked are here now. The edge
                           // rule is read when the gesture BEGINS
                           // (`PagedCanvas.swipeMayTurn`, `limitAtStart`), so
                           // a pan across a zoomed page is a pan; and the page
                           // readout follows the INDEX (`step(by:)`), so a
                           // swipe from a zoomed page cannot leave "p. 1" over
                           // page 2. The tap on the right edge stays; this is a
                           // second way to the same turn, through the same
                           // step, which stops at either end.
                           onSwipeTurn: { direction in step(by: direction) },
                           // a scan has no geometry to hit-test, so a lasso
                           // would draw and catch nothing -- worse than not
                           // offering it
                           mode: mode,
                           voiceOverRunning: voiceOverRunning,
                           selectionEnabled: mode != .performance
                               && state.displayedArtifact == .notation,
                           lassoArmed: state.lassoArmed
                               && mode != .performance
                               && state.displayedArtifact == .notation,
                           resetPanToken: panToken,
                           annotationActive: annotation.isOn,
                           scrollTarget: (scrollToken, scrollTargetX),
                           bottomChrome: Self.bottomChrome(for: geo.size),
                           onVisibleRectChange: { rect, content, live in
                               viewport.update(rect: rect, live: live,
                                               tiles: continuous ? ContinuousTiles.tiles(surface: surface) : [])
                               // The bar readout's rects go on AppState, which
                               // every view of the score screen observes, and
                               // ZoomableScroll re-roots the whole page stack
                               // when this view re-evaluates: 30 to 60ms on an
                               // iPhone 15 Pro, measured. While a finger or its
                               // momentum moves the score, NOTHING is published
                               // to AppState; the scroll view reports once more
                               // when it settles, and the readout catches up
                               // then. A readout, not a cursor.
                               guard !live else { return }
                               if continuous {
                                   publishVisibleStrip(contentRect: rect,
                                                       scale: engraved,
                                                       pageSize: strip?.size ?? .zero)
                               } else {
                                   publishVisibleBars(contentRect: rect,
                                                      contentSize: content,
                                                      unit: unit, width: width)
                               }
                               // The unit IS what is visible now: no bands, no
                               // boundary arithmetic, no mapping a scroll
                               // offset back to a page.
                               if state.visiblePageIndices != unit {
                                   state.visiblePageIndices = unit
                               }
                           },
                           scroller: scroller,
                           onUserScroll: { readerScrolled() },
                           zoomRange: zoomRange(continuous: continuous,
                                                stripHeight: surface.height)) { settled in
                // round so small wobbles don't re-raster every gesture
                // finer steps than before: at 12x, half-scale rounding threw
                // away most of the resolution the zoom had asked for
                let stepped = (settled * 4).rounded() / 4
                if stepped != rasterZoom { rasterZoom = stepped }
            } content: {
                if continuous, let stripPage {
                    continuousStrip(stripPage, surface: surface, scale: stripScale,
                                    engraved: engraved)
                } else {
                    pageUnit(unit, width: width)
                }
            }
            // A turn slides the new unit in, out to the left and in from the
            // right, reversed going back. It is a transition on the unit, not
            // a scroll to an offset, which is why there is no offset to keep.
            .onChange(of: surface.width, initial: true) { _, new in
                surfaceWidth = new
            }
            .onChange(of: engraved, initial: true) { _, new in
                engravedScale = new
            }
            .id(continuous ? -1 : state.pageIndex)
            // The slide follows the direction of the turn: forward, the new
            // page comes in from the right; BACK, from the left. Both turns
            // slid the same way until 0.8.0 build 196 (Ali, item E). The
            // direction is read against the unit last shown, so a turn from
            // the rail or the scrubber slides the right way too.
            .transition(PageTurn.slide(forward: state.pageIndex >= shownIndex))
            .animation(Theme.Motion.overlay(reduced: reduceMotion), value: state.pageIndex)
            .onChange(of: state.pageIndex) { _, index in shownIndex = index }
            .onAppear {
                viewport.seed(CGRect(origin: .zero, size: geo.size))
            }
            // The finger is covering what it is selecting, at every scale
            // (§9.2). Drawn over the canvas rather than in it, so nothing it
            // magnifies can magnify the loupe.
            .overlay {
                if let loupe {
                    LoupeView(sample: loupe, safeAreaTop: geo.safeAreaInsets.top)
                }
            }
            // The latch. Kept here rather than computed in the body, because a
            // view's body may not write its own state -- and one frame drawn
            // at the previous fit is exactly what is wanted anyway: the frame
            // a panel opens on is the frame that must NOT re-scale.
            .onChange(of: geo.size, initial: true) { _, size in
                let next = ContinuousTiles.fittingViewport(
                    now: size, latched: fittedTo,
                    sameDocument: fittedDocument == state.engravingKey)
                if next != fittedTo { fittedTo = next }
                // Only when it differs. Assigning the same value to @State
                // still invalidates the view, and this view being invalidated
                // is the thing the whole pass is about.
                if fittedDocument != state.engravingKey {
                    fittedDocument = state.engravingKey
                }
            }
            // A different engraving is a different score on the canvas, and
            // whatever the last one was fitted to says nothing about it.
            .onChange(of: state.engravingKey) { _, key in
                fittedDocument = key
                if fittedTo != geo.size { fittedTo = geo.size }
            }
            // Follow the sound. Only on a CHANGE of bar: the engine publishes
            // a beat twenty times a second and re-deciding the scroll that
            // often would fight every pan the reader makes.
            .onChange(of: playback.soundingBar) { _, bar in
                follow(bar: bar, stripScale: stripScale, surface: surface)
            }
        }
        // At the BOTTOM of the canvas on a phone (§9.6). At the top it lands
        // on the first system, which on a portrait phone is a quarter of the
        // music -- and the chip appears exactly when the reader is looking at
        // what they just selected. Below the page there is room and nothing
        // to cover.
        .overlay(alignment: hSize == .compact ? .bottom : .top) { selectionChip }
        .overlay(alignment: .bottom) {
            // `-perfNoChip`: an experiment -- the chip and its reader left out.
            if !ProcessInfo.processInfo.arguments.contains("-perfNoChip") {
                ViewportReader(viewport: viewport) { visibleRect in
                    continuousSyncChip(visibleRect: visibleRect)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            TouchDiagnosticsOverlay(diagnostics: TouchDiagnostics.shared)
        }
        // Wrapped in a child that OBSERVES the controller. This view reads
        // `state.annotation` through AppState, which publishes nothing when the
        // controller's own state changes -- so the bar's visibility only
        // updated when something else happened to redraw the score pane, and
        // turning edit mode off from the pill left the tools on screen. The
        // pill itself has observed the controller since it was written; this is
        // the same fix, in the one place that was missing it.
        // The ink bar's layer is NOT here any more. It docked at the bottom of
        // the page canvas, which stops above the thumbnail strip -- so the bar
        // could not be moved over the strip or the transport, which is the
        // clamp Ali ran into (#46). It hangs off the whole score screen now.
    }

    /// The same question for the continuous strip, which has no pages.
    ///
    /// It used to be answered by `publishVisibleBars` -- the paged arithmetic,
    /// run over a page frame that does not exist here and a content size that
    /// is the whole score. The badge read "bar 68" on a score whose transport
    /// read bar 1. The strip is ONE engraving, so the slice is the viewport
    /// divided by the scale it was laid out at, and nothing else.
    private func publishVisibleStrip(contentRect: CGRect, scale: CGFloat,
                                     pageSize: CGSize) {
        guard let slice = ContinuousTiles.visibleSlice(contentRect: contentRect,
                                                      scale: scale,
                                                      pageSize: pageSize) else { return }
        let out = [0: slice]
        if out != state.visibleBarRects { state.visibleBarRects = out }
    }

    /// Turn the scroll view's visible rect into "which slice of each page is on
    /// screen", in page (SVG user) coordinates, for the bar readout.
    ///
    /// Two spaces meet here. `contentRect` is the scroll view's and moves as
    /// the reader pans and zooms; each page's own frame is computed from the
    /// layout, not measured -- a GeometryReader inside this scroll view never
    /// reported, because SwiftUI is not re-laid-out as UIKit scrolls it.
    /// Intersecting them gives the visible slice of each page, and the page's
    /// own scale converts it into the coordinates the geometry index uses.
    private func publishVisibleBars(contentRect: CGRect, contentSize: CGSize,
                                    unit: [Int], width: CGFloat) {
        guard contentSize.width > 0, contentSize.height > 0 else { return }
        // The scroll view's content coordinates are NOT the SwiftUI layout's,
        // so the two are reconciled by proportion rather than by assuming a
        // shared unit -- assuming one made the visible slice eight pages wide.
        let layoutWidth = CGFloat(unit.count) * width
            + CGFloat(max(unit.count - 1, 0)) * SpreadLayout.gutter
        let layoutHeight = width * (unit.compactMap { aspect(of: $0) }.max() ?? 1.414)
            + SpreadLayout.gutter * 2
        let kx = layoutWidth / contentSize.width
        let ky = layoutHeight / contentSize.height
        let visible = CGRect(x: contentRect.minX * kx, y: contentRect.minY * ky,
                             width: contentRect.width * kx, height: contentRect.height * ky)
        var out: [Int: CGRect] = [:]
        for (position, index) in unit.enumerated() {
            guard let size = state.geometry?.page(index)?.size,
                  size.width > 0, size.height > 0 else { continue }
            let frame = BarPosition.pageFrame(position: position, width: width,
                                              aspect: aspect(of: index),
                                              gutter: SpreadLayout.gutter)
            let slice = frame.intersection(visible)
            guard !slice.isNull, !slice.isEmpty else { continue }
            let sx = size.width / frame.width
            let sy = size.height / frame.height
            out[index] = CGRect(x: (slice.minX - frame.minX) * sx,
                                y: (slice.minY - frame.minY) * sy,
                                width: slice.width * sx,
                                height: slice.height * sy)
        }
        if out != state.visibleBarRects { state.visibleBarRects = out }
    }

    /// POSITION ◀ ▲ ▼ ▶ │ SIZE A⁻ 1.4× A⁺ │ Reset, the caption, the pending
    /// line, and the PLACE row that sends the mark to another bar.
    ///
    /// The words are the model's: what a size means, what the mark is called
    /// and what the engine refused are all sentences `ChordAdjustSession`,
    /// `AddedMark` and `MoveDestination` hold, so the row and its summary
    /// cannot say different things.
    @ViewBuilder
    private var adjustRow: some View {
        if let session = state.adjustSession {
            VStack(alignment: .leading, spacing: 4) {
                // TWO lines, not one. Photographed at iPad width the single
                // row ran out of space and SwiftUI wrapped the words inside
                // it -- "POSI/TION" and "Rese/t" -- which is the panel
                // reporting that it does not fit by mangling its own labels.
                // Each line here is short enough that nothing can wrap.
                HStack(spacing: Theme.Metric.s6) {
                    Text("POSITION").typeRole(.label).foregroundStyle(Theme.Ink.ink3)
                        .fixedSize()
                    nudge(.left, "chevron.left", "left")
                    nudge(.up, "chevron.up", "up")
                    nudge(.down, "chevron.down", "down")
                    nudge(.right, "chevron.right", "right")
                    Spacer(minLength: 0)
                }
                HStack(spacing: Theme.Metric.s6) {
                    Text("SIZE").typeRole(.label).foregroundStyle(Theme.Ink.ink3)
                        .fixedSize()
                    resize(.smaller, "textformat.size.smaller", "smaller")
                    Text(session.metric.readout(session.pending.size))
                        .typeRole(.data).foregroundStyle(Theme.Ink.ink)
                        .frame(minWidth: 40)
                        .fixedSize()
                        .accessibilityLabel(session.metric.spoken(session.pending.size))
                        .accessibilityIdentifier("adjust-size")
                    resize(.bigger, "textformat.size.larger", "bigger")

                    Divider().frame(height: 16)

                    Button("Reset") { state.adjust { $0.reset() } }
                        .typeRole(.meta)
                        .foregroundStyle(Theme.Accent.clayStrong)
                        .buttonStyle(.plain)
                        .fixedSize()
                        .accessibilityIdentifier("adjust-reset")
                    Spacer(minLength: 0)
                }
                if let caption = session.metric.caption {
                    Text(caption)
                        .typeRole(.meta).foregroundStyle(Theme.Ink.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("adjust-size-caption")
                }
                if let pending = session.pendingDescription {
                    HStack(spacing: Theme.Metric.s8) {
                        Text("pending: \(pending)")
                            .typeRole(.meta).foregroundStyle(Theme.Ink.ink2)
                            .accessibilityIdentifier("adjust-pending")
                        Button("Revert") { state.adjust { $0.revert() } }
                            .typeRole(.meta)
                            .foregroundStyle(Theme.Accent.clayStrong)
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("adjust-revert")
                        Spacer(minLength: 0)
                    }
                }
                placeRow
            }
        }
    }

    /// PLACE [Move…] [Duplicate…], and then the destination itself.
    ///
    /// Only for a selection of ONE: move and duplicate address a single
    /// element, and a row that offered to move four and moved one would be
    /// lying about what it did.
    @ViewBuilder
    private var placeRow: some View {
        if let destination = state.placing {
            placing(destination)
        } else if (state.activeSelection?.addresses.count ?? 0) == 1 {
            HStack(spacing: Theme.Metric.s6) {
                Text("PLACE").typeRole(.label).foregroundStyle(Theme.Ink.ink3)
                    .fixedSize()
                Button("Move…") { state.beginPlacing(.move) }
                    .typeRole(.meta).foregroundStyle(Theme.Accent.clayStrong)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("adjust-move")
                Button("Duplicate…") { state.beginPlacing(.duplicate) }
                    .typeRole(.meta).foregroundStyle(Theme.Accent.clayStrong)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("adjust-duplicate")
                Spacer(minLength: 0)
            }
        }
    }

    /// Aiming: the prompt until a bar is tapped, then the bar, the offset
    /// stepper, and whatever the engine last refused.
    @ViewBuilder
    private func placing(_ destination: MoveDestination) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(destination.summary ?? destination.prompt)
                .typeRole(.meta)
                .foregroundStyle(destination.isReady ? Theme.Ink.ink : Theme.Accent.clayStrong)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("place-summary")
            if destination.isReady {
                HStack(spacing: Theme.Metric.s6) {
                    Text("OFFSET").typeRole(.label).foregroundStyle(Theme.Ink.ink3)
                        .fixedSize()
                    stepOffset(-MoveDestination.step, "minus", "earlier", destination)
                    Text(MoveDestination.quarters(destination.offset))
                        .typeRole(.data).foregroundStyle(Theme.Ink.ink)
                        .frame(minWidth: 44)
                        .accessibilityIdentifier("place-offset")
                    stepOffset(MoveDestination.step, "plus", "later", destination)
                    Spacer(minLength: 0)
                }
            }
            if let note = destination.refusalNote {
                Text(note)
                    .typeRole(.meta).foregroundStyle(Theme.Status.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("place-refusal")
            }
            if !destination.onsets.isEmpty {
                HStack(spacing: Theme.Metric.s6) {
                    ForEach(destination.onsets, id: \.self) { onset in
                        Button(MoveDestination.quarters(onset)) {
                            state.snapPlacement(to: onset)
                        }
                        .typeRole(.meta)
                        .foregroundStyle(Theme.Accent.clayStrong)
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("place-onset-\(onset)")
                    }
                    Spacer(minLength: 0)
                }
            }
            HStack(spacing: Theme.Metric.s8) {
                PanelButton(title: destination.confirmTitle, kind: .primary) {
                    state.commitPlacement()
                }
                .disabled(!destination.isReady)
                .opacity(destination.isReady ? 1 : 0.42)
                .accessibilityIdentifier("place-confirm")
                Button("Cancel") { state.cancelPlacing() }
                    .typeRole(.meta)
                    .foregroundStyle(Theme.Accent.clayStrong)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("place-cancel")
                Spacer(minLength: 0)
            }
        }
    }

    private func stepOffset(_ delta: Double, _ glyph: String, _ word: String,
                            _ destination: MoveDestination) -> some View {
        let enabled = destination.canStep(by: delta)
        return Button {
            state.stepPlacement(by: delta)
        } label: {
            Image(systemName: glyph)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 32, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.42)
        .accessibilityLabel("An eighth note \(word)")
        .accessibilityIdentifier("place-\(word)")
    }

    /// One nudge button. Press-and-hold repeats, but a plain tap always works
    /// on its own -- the repeat is a convenience, never the only way.
    private func nudge(_ direction: ChordAdjustSession.Direction,
                       _ glyph: String, _ word: String) -> some View {
        let enabled = state.adjustSession?.canNudge(direction) ?? false
        return Button {
            state.adjust { $0.nudge(direction) }
        } label: {
            Image(systemName: glyph)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 32, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.42)
        .accessibilityLabel("Move \(word) half a staff space")
        .accessibilityIdentifier("adjust-\(word)")
    }

    private func resize(_ step: ChordAdjustSession.SizeStep,
                        _ glyph: String, _ word: String) -> some View {
        let enabled = state.adjustSession?.canResize(step) ?? false
        return Button {
            state.adjust { $0.resize(step) }
        } label: {
            Image(systemName: glyph)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 32, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.42)
        .accessibilityLabel("Make it \(word)")
        .accessibilityIdentifier("adjust-\(word)")
    }

    /// What one finished single-finger touch meant.
    ///
    /// The decision is `CanvasTap`'s, entirely: this asks once and does what it
    /// is told. There is no second gesture to lose to, which is the point (§12).
    private func canvasTap(_ touch: CanvasTap.Touch) {
        let hit = touch.page.map { state.hasElement(at: $0.unit, onPage: $0.index) } ?? false
        let outcome = CanvasTap.tap(touch, mode: mode, lassoArmed: state.lassoArmed,
                                    hit: hit)
        // While a move is being aimed a tap names the DESTINATION BAR. The
        // selection must not move: it is still pointing at the mark being
        // sent, and the op is addressed by it.
        if state.isPlacingMark, case .select = outcome, let page = touch.page {
            if let bar = state.barNumber(at: page.unit, onPage: page.index) {
                state.aimPlacement(atBar: bar)
            }
            return
        }
        switch outcome {
        case .turn(let zone):
            turn(zone)
        case .select:
            guard let page = touch.page else { return }
            select(at: page.unit, onPage: page.index)
        case .clear:
            state.clearSelection()
        case .none:
            break
        }
    }

    /// The bar, or the note, under the finger.
    ///
    /// Which one is the zoom's answer (§9.1): at fit a fingertip covers most of
    /// a bar and picking one note out of it would be a guess, so the tap takes
    /// the bar; zoomed in far enough to see a notehead, it takes the note. A
    /// tap ON an existing selection always means the note, because the reader
    /// has already said which bar they meant.
    private func select(at unit: CGPoint, onPage index: Int) {
        let onSelected = state.selectionContains(unit, onPage: index)
        switch TapSelection.granularity(atZoom: rasterZoom, onSelected: onSelected) {
        case .measure:
            _ = state.selectBar(at: unit, onPage: index, allStaves: false)
        case .note:
            _ = state.addToSelection(at: unit, onPage: index)
        }
    }

    /// A turn, wherever the decision came from.
    private func turn(_ zone: PageTurn.Zone) {
        let direction = zone == .next ? 1 : -1
        // No pages to turn in continuous mode: a tap moves the reader on by
        // what is on screen (designer's spec). Performance mode keeps the same
        // horizontal advance, which is what it already meant.
        guard !state.layout.isContinuous else {
            scrollTargetX = ContinuousTiles.advanced(from: viewport.rect.minX,
                                                     by: viewport.rect.width,
                                                     direction: direction,
                                                     surfaceWidth: surfaceWidth)
            scrollToken += 1
            return
        }
        step(by: direction)
    }

    /// Step the unit. Rapid turns coalesce to the latest rather than queueing
    /// animations, or the score keeps sliding after the reader stops.
    private func step(by direction: Int) {
        guard let next = PagedCanvas.step(from: state.pageIndex, by: direction,
                                          pageCount: document.pageCount,
                                          spread: state.twoPageSpread) else { return }
        // A page turned BY THE READER hands following over to them. The music
        // is not stopped and the page is not taken back: a Sync chip appears
        // and waits to be asked.
        state.readerTurnedPage()
        state.pageIndex = PagedCanvas.coalesce(pending: nil, latest: next)
        // And the readout follows the INDEX, not the scroll.
        //
        // `visiblePageIndices` is normally published by the canvas when its
        // visible rect changes, which is true for a turn at fit -- the new
        // unit lays out, the rect changes, the counter follows. It is NOT
        // true after a swipe-turn from a zoomed page: the scroll view is
        // already where the new unit wants it, nothing moves, nothing is
        // reported, and the counter goes on naming the page the reader has
        // just left. Photographed on an iPad: page 2's music on screen under
        // "p. 1 / 9", with the rail still marking page 1.
        //
        // The index is the truth about which unit is shown -- the canvas is
        // keyed on it -- so the readout is set from it here rather than
        // waited for.
        state.visiblePageIndices = PagedCanvas.unit(
            at: state.pageIndex, pageCount: document.pageCount,
            spread: state.twoPageSpread)
    }

    /// "Take me back", for the strip.
    ///
    /// The paged chip is `SyncChipLayer`, and its visibility predicate is the
    /// page one: in continuous mode there is a single page and it is always on
    /// screen, so that chip can never appear here however far the reader has
    /// scrolled. This is the same control, the same label, the same state and
    /// the same identifier, decided by the horizontal rule instead -- the two
    /// cannot both be on screen. It belongs in `SyncChipLayer` beside its twin
    /// as soon as that file can be edited.
    @ViewBuilder
    private func continuousSyncChip(visibleRect: CGRect) -> some View {
        let shows = state.layout.isContinuous
            && PageFollow.showsSync(isPlaying: playback.isPlaying,
                                        isFollowing: state.pageFollow.isFollowing,
                                        playheadX: playheadSurfaceX,
                                        visible: visibleRect,
                                        isPerformanceMode: mode == .performance)
        if shows {
            Button {
                state.pageFollow.syncTapped()
                scroller.forget()
                // Move now rather than on the next beat: the reader asked, and
                // a paused transport ticks nothing.
                if let x = playheadSurfaceX {
                    scrollTargetX = Playhead.stripOffset(playheadX: x,
                                                         viewportWidth: visibleRect.width,
                                                         surfaceWidth: surfaceWidth)
                    scrollToken += 1
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.uturn.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text(PageFollow.syncLabel(bar: playback.soundingBar))
                        .typeRole(.label)
                }
                .foregroundStyle(Theme.Surface.panel)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(Theme.Accent.clayPress)
                .clipShape(Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.bottom, Self.bottomChrome(for: fittedTo))
            .accessibilityIdentifier("sync-to-playback")
            .accessibilityLabel(PageFollow.syncLabel(bar: playback.soundingBar))
            .transition(.opacity)
        }
    }

    /// The line's place on the strip, in surface points.
    private var playheadSurfaceX: CGFloat? {
        guard state.layout.isContinuous, let page = state.geometry?.page(0),
              let progress = playback.timeline.progress(atBeat: playback.beat),
              let position = Playhead.position(measure: progress.measure,
                                               fraction: CGFloat(progress.fraction),
                                               bars: BarPosition.bars(onPage: page))
        else { return nil }
        return position.x * engravedScale
    }

    /// A hand on the score during playback.
    ///
    /// The music does NOT stop -- this cannot stop it -- and the score is not
    /// taken back. Following yields, and the Sync chip appears and waits to be
    /// asked. The same rule as a page turned by the reader in paged mode, and
    /// deliberately the same state, so there is one answer to "who is driving".
    private func readerScrolled() {
        guard state.layout.isContinuous else { return }
        scroller.forget()
        state.readerTurnedPage()
    }

    /// Keep the sounding bar readable, without taking the score away from a
    /// reader who has just panned somewhere to look at it.
    ///
    /// `PlaybackFollow` returns nil while the bar is comfortably on screen,
    /// and that nil is the feature: the strip holds still through most of a
    /// phrase and moves in one decisive step when the music has run to the
    /// edge.
    private func follow(bar: Int?, stripScale: CGFloat, surface: CGSize) {
        guard bar != nil else { return }
        // Continuous is not driven from here any more. A bar change is twice a
        // second at best and the strip has to move with the BEAT, or the line
        // jumps ahead and re-jumps -- which is what it did.
        // `ContinuousPlayheadLayer` follows the sound itself, off the same
        // clock that draws the line.
        if state.layout.isContinuous { return }
        // Paged: there is nothing to scroll, so the unit turns -- and only
        // when the bar is on a page that is not already showing.
        //
        // AND only while following is still the app's job. Without this guard
        // the reader pages ahead, the very next play-head tick turns the page
        // straight back, and the score fights them -- which is the exact
        // behaviour the revised rule in design/PLAYBACK.md exists to remove.
        // Caught in a screenshot: the rail and the badge said page 7 while the
        // canvas had been dragged back to page 1.
        guard state.pageFollow.isFollowing else { return }
        guard let sounding = bar, let geometry = state.geometry,
              let page = geometry.pages.first(where: { candidate in
                  BarPosition.frame(ofBar: sounding,
                                    among: BarPosition.bars(onPage: candidate)) != nil
              }),
              let unit = PlaybackFollow.turn(toPage: page.index,
                                             showing: state.visiblePageIndices,
                                             spread: state.twoPageSpread)
        else { return }
        state.pageIndex = unit
    }

    /// What sends the canvas back to the beginning.
    ///
    /// A page turn, a change of layout, and a document with a different number
    /// of pages -- which is how a re-engrave for a NEW layout announces itself.
    /// Switching to continuous keeps the pages up until the strip arrives, so
    /// the content grows from one page wide to the whole score in one step;
    /// without this the scroll view kept the reader's proportional place across
    /// that step and opened the strip in the middle of the piece.
    ///
    /// An op that re-engraves the same music to the same number of pages does
    /// NOT reset: the reader keeps their place, which is #44.
    private var panToken: Int {
        let layoutIndex = ScoreLayout.allCases.firstIndex(of: state.layout) ?? 0
        return (state.pageIndex &* 31 &+ layoutIndex) &* 31 &+ document.pageCount
    }

    private func aspect(of page: Int?) -> CGFloat {
        guard let page, let pdf = document.page(at: page) else { return 1.414 }
        let bounds = pdf.bounds(for: .mediaBox)
        return bounds.height / max(bounds.width, 1)
    }

    /// The unit on screen: one page, or two with the spread on.
    ///
    /// Nothing else is rendered. That is the whole change -- the vertical stack
    /// of every page is gone, and with it the raster window that existed to
    /// stop a twelve-page score drawing itself twelve times over. One or two
    /// pages can afford full resolution.
    @ViewBuilder
    private func pageUnit(_ unit: [Int], width: CGFloat) -> some View {
        HStack(alignment: .top, spacing: SpreadLayout.gutter) {
            ForEach(unit, id: \.self) { index in
                if let page = document.page(at: index) {
                    pageView(page, index: index, width: width, atDepth: true)
                }
            }
        }
        .padding(.vertical, SpreadLayout.gutter)
    }

    /// The continuous strip: the whole score in one line, cut into tiles.
    ///
    /// Only the tiles near the viewport are drawn at full resolution. The
    /// alternative -- one image of the whole strip, the way a page is drawn --
    /// is a 21000pt-wide raster, and `PDFPageImage.maxRasterWidth` records what
    /// happens when this app asks for that much bitmap.
    @ViewBuilder
    private func continuousStrip(_ page: PDFPage, surface: CGSize,
                                 scale: CGFloat, engraved: CGFloat) -> some View {
        let tiles = ContinuousTiles.tiles(surface: surface)
        HStack(spacing: 0) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { index, tile in
                ContinuousTileView(page: page, document: state.engravingKey,
                                   index: index, tile: tile, scale: scale,
                                   depth: viewport.depth)
            }
        }
        // The strip's lasso anchor. Its absence WAS bug 7: the recognizer picks
        // the `LassoAnchorView` whose frame contains the touch, and continuous
        // mode had none in the tree at all -- so `beginLasso` returned before it
        // began and the Pencil did nothing whatever the reader drew. The same
        // lookup serves the tap that drops an element, so taps were dead here
        // too.
        //
        // It goes on the TILE ROW, which is the surface exactly, and not on the
        // padded container around it: the anchor reports unit (0…1) points of
        // its own bounds, and `LassoPath.onPage` multiplies those by the
        // engraving's own size. Twelve points of margin inside the anchor would
        // shift every selection down the staff.
        .overlay(alignment: .topLeading) {
            SelectionHighlight(frames: selectedFrames(onPage: 0),
                               pageSize: state.geometry?.page(0)?.size ?? .zero,
                               zoom: rasterZoom)
                .frame(width: surface.width, height: surface.height)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) {
            LassoAnchor(pageIndex: 0,
                        committed: state.selectionPaths[0] ?? [],
                        zoom: rasterZoom)
                .frame(width: surface.width, height: surface.height)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) {
            ContinuousPlayheadLayer(playback: playback, clock: playback.clock,
                                    page: state.geometry?.page(0),
                                    scale: engraved,
                                    surfaceWidth: surface.width,
                                    isFollowing: state.pageFollow.isFollowing,
                                    scroller: scroller,
                                    showsHandle: mode != .performance,
                                    zoom: rasterZoom)
                .frame(width: surface.width, height: surface.height)
        }
        .padding(.vertical, ContinuousTiles.margin)
        // NO page shadow. A page is a sheet lying on a surface and its shadow
        // says so; the strip is one ribbon, and the shadow was being drawn at
        // every tile join, banding the music at each one.
    }

    /// One page, with its own lasso anchor. The anchor is what makes a lasso
    /// land on the page it was drawn on: the recognizer picks the anchor whose
    /// frame contains the touch, so the right-hand page of a spread selects
    /// from itself and not from its neighbour.
    private func pageView(_ page: PDFPage, index: Int, width: CGFloat,
                          atDepth: Bool) -> some View {
        PageView(page: page,
                 document: state.engravingKey,
                 index: index,
                 width: width,
                 rasterZoom: atDepth ? rasterZoom : 1,
                 drawingStore: DrawingStore.shared,
                 drawingKey: "\(annotationKey)/p\(index)",
                 identityKey: "\(canvasIdentity)/p\(index)",
                 sharedInk: sharedInk[index] ?? [],
                 annotation: annotation)
            .overlay {
                // What was caught, drawn over the page. Until this, a working
                // selection looked like nothing had happened: the only signs
                // were the lasso outline, a chip at the top, and chat opening.
                SelectionHighlight(frames: selectedFrames(onPage: index),
                                   pageSize: state.geometry?.page(index)?.size ?? .zero,
                                   zoom: rasterZoom)
                    .allowsHitTesting(false)
            }
            .overlay {
                LassoAnchor(pageIndex: index,
                            committed: state.selectionPaths[index] ?? [],
                            zoom: rasterZoom)
                    .allowsHitTesting(false)
            }
            .overlay {
                // The cursor goes ABOVE the selection and the lasso, so it is
                // never hidden behind a highlight -- and takes no input, so it
                // costs them nothing.
                PlayheadLayer(playback: playback, clock: playback.clock,
                              bars: state.geometry?.page(index)
                                  .map(BarPosition.bars(onPage:)) ?? [],
                              pageSize: state.geometry?.page(index)?.size ?? .zero,
                              zoom: rasterZoom,
                              showsHandle: mode != .performance)
            }
            .shadow(color: Color(hex: 0x1A1917).opacity(0.14), radius: 5, y: 2)
    }

    /// The frames of everything selected on one page, in page coordinates.
    /// Addresses are durable across re-renders; the frames are looked up fresh
    /// from whatever geometry is on screen now.
    /// The boxes to draw on one page, each with the KIND it marks.
    ///
    /// The kind rides along because a bar's fill is lighter than a notehead's
    /// (§11): a bar box is about fifty times the area, and the same opacity
    /// across it is a wash. `SelectionInk.fillOpacity(for:)` is the rule.
    private func selectedFrames(onPage index: Int) -> [SelectionBox] {
        guard let selection = state.activeSelection,
              let geometry = state.geometry else { return [] }
        let members: [SelectionMerge.Member] = selection.addresses.compactMap { address in
            guard let element = geometry.element(at: address),
                  element.pageIndex == index else { return nil }
            return SelectionMerge.Member(address: address, frame: element.frame)
        }
        // A whole bar is ONE mark, not one per note: multiplied fills compound
        // where they overlap, so the lightest mark on the page was coming out
        // the heaviest (§13).
        return SelectionMerge.boxes(selected: members,
                                    population: state.barPopulations)
    }

    // MARK: selection chip

    /// What is selected, in the user's terms, and what can be done with it.
    ///
    /// The Replace/Add/Subtract modes are gone. Adding is a finger of the other
    /// hand held down while the Pencil draws -- a thing the hands do rather
    /// than a mode to be in -- and the modes were a trap: Subtract emptied the
    /// selection, an empty selection hid the chip, and the chip was the only
    /// way back out.
    ///
    /// Nothing reaches the chat box until "Use in chat" is tapped. A lasso is
    /// not a request to start typing.
    @ViewBuilder
    private var selectionChip: some View {
        if let selection = state.activeSelection, !selection.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Metric.s6) {
                HStack(spacing: Theme.Metric.s8) {
                    Text(selection.headline).typeRole(.label)
                        .foregroundStyle(Theme.Accent.clayStrong)
                        // named here rather than on the container: an
                        // identifier on a container is inherited by every child
                        .accessibilityIdentifier("selection-chip")
                    Spacer(minLength: Theme.Metric.s8)
                    Button {
                        state.clearSelection()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.Ink.ink2)
                            .frame(width: Theme.Metric.hitTarget,
                                   height: Theme.Metric.hitTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear selection")
                }
                if let place = selection.placeLine {
                    Text(place).typeRole(.meta)
                        .foregroundStyle(Theme.Ink.ink3)
                        .accessibilityIdentifier("selection-place")
                }
                if let note = state.selectionCarryNote {
                    Text(note).typeRole(.meta)
                        .foregroundStyle(Theme.Status.warn)
                        .accessibilityIdentifier("selection-carry-note")
                }
                // Position and size, for a selection of chord symbols. One
                // row, docked with the chip rather than floating beside the
                // element: a cluster that followed the selection would sit on
                // the music, land off the page near an edge, and move under the
                // thumb as the symbol moved -- and the symbol is the thing you
                // need to watch while you nudge it.
                if selection.isAdjustable, state.adjustSession != nil {
                    adjustRow
                }
                HStack(spacing: Theme.Metric.s8) {
                    PanelButton(title: "Use in chat", kind: .primary) {
                        state.confirmSelectionForChat()
                    }
                    .accessibilityIdentifier("selection-confirm")
                    Spacer(minLength: 0)
                }
                Text("Hold a finger down to add · tap an element to drop it")
                    .typeRole(.meta)
                    .foregroundStyle(Theme.Ink.ink3)
                    // wrap rather than set the panel's width: this line is the
                    // longest thing in the chip and on a phone it is wider
                    // than the screen, so left to itself it decided how wide
                    // the panel was and the panel hung off BOTH edges -- the
                    // headline, the place line and "Use in chat" all clipped
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Theme.Metric.s12)
            .padding(.vertical, Theme.Metric.s8)
            .background(Theme.Surface.panel)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.rPanel))
            .modifier(ChipShadow())
            // A ceiling on a wide canvas, and a margin on a narrow one. Both
            // are needed: the ceiling stops it spanning an iPad, the margin
            // stops it touching the edges of a phone.
            .frame(maxWidth: Theme.Metric.alertWidth)
            .padding(.horizontal, Theme.Metric.s12)
            .padding(.top, Theme.Metric.s12)
        }
    }

    private func select(path: [CGPoint], onPage index: Int, adding: Bool) {
        guard let page = state.geometry?.page(index) else {
            state.selectionPaths = [index: path]
            return
        }
        // Unit coordinates -> page (SVG user) coordinates, by the page's OWN
        // size. In continuous mode that page is the whole strip, and this is
        // the only place the two spaces meet: the surface is in PDF points and
        // the geometry in SVG viewBox units, twenty-two times apart, and
        // neither number appears here.
        let caught = page.elements(
            caughtBy: LassoPath.onPage(unit: path, pageSize: page.size))
        state.commitSelection(caught, path: path, page: index, adding: adding)
    }

}

/// The ink tools, on screen only while edit mode is on.
///
/// Its whole reason for existing is `@ObservedObject`: the bar has to appear and
/// disappear with the mode, and only a view that observes the controller is
/// redrawn when the mode changes.
/// Where the sound is, on the strip.
///
/// A band behind the bar rather than a line at its left edge: a line says
/// "here is an instant", and what a player glancing up needs is "here is the
/// bar you are in". Behind the music and unfilled at the edges, so it never
/// competes with a notehead for the eye.
/// The playhead: where the sound has got to, on the engraved page.
///
/// OBSERVES the engine rather than being handed a value. The play head moves
/// twenty times a second, and a position passed down from `ScorePagesView`
/// would invalidate the whole page -- the rasterised PDF, the ink layer, the
/// selection boxes -- on every tick. Observing here means only this view
/// redraws, which is the same fix the ink bar needed.
///
/// Driven by (MEASURE, FRACTION), never by elapsed time: see `Playhead`.
private struct PlayheadLayer: View {
    @ObservedObject var playback: PlaybackEngine
    /// The beat at display rate (`PlaybackClock`): this layer and the strip's
    /// are its only observers, so a frame's tick redraws a line, not a page.
    @ObservedObject var clock: PlaybackClock
    let bars: [BarPosition.Bar]
    let pageSize: CGSize
    /// The scroll view's zoom, so the constants below stay sizes on SCREEN.
    let zoom: CGFloat
    let showsHandle: Bool

    /// The bar the finger has already been given, so a drag across one bar
    /// does not re-seek to its downbeat twenty times. Nil when nothing is
    /// being dragged.
    @State private var scrubbed: Int?
    /// The last position drawn, so a tick with none cannot blank the line
    /// mid-performance (`Playhead.hold`).
    @State private var lastDrawn: Playhead.Position?

    var body: some View {
        GeometryReader { geo in
            if let position = Playhead.hold(current: position, last: lastDrawn,
                                            isPlaying: playback.isPlaying),
               pageSize.width > 0, pageSize.height > 0 {
                let sx = geo.size.width / pageSize.width
                let sy = geo.size.height / pageSize.height
                let over = Playhead.onScreen(Playhead.overshoot, zoom: zoom)
                let top = position.top * sy - over
                let height = position.height * sy + over * 2
                let x = position.x * sx
                ZStack(alignment: .topLeading) {
                    // Clay, and flat. No glow and no gradient (§4 of the design
                    // system): a moving hairline and a tinted outlined box are
                    // not confusable, so the cursor does not need a colour of
                    // its own to stay distinct from a selection.
                    Rectangle()
                        .fill(Theme.Accent.clay)
                        .frame(width: Playhead.onScreen(Playhead.weight, zoom: zoom),
                               height: height)
                        .position(x: x, y: top + height / 2)
                    if showsHandle {
                        RoundedRectangle(
                            cornerRadius: Playhead.onScreen(Playhead.handleRadius, zoom: zoom))
                            .fill(Theme.Accent.clay)
                            .frame(width: Playhead.onScreen(Playhead.handle, zoom: zoom),
                                   height: Playhead.onScreen(Playhead.handle, zoom: zoom))
                            .position(x: x, y: top)
                    }
                }
                // The DRAWING takes no touch, exactly as before: the line and
                // the square are pictures, and a cursor that swallowed a
                // stroke would make selection fail wherever the music happened
                // to be playing.
                .allowsHitTesting(false)
                .onChange(of: clock.beat, initial: true) { _, beat in
                    if let now = self.position {
                        lastDrawn = now
                    } else if playback.isPlaying {
                        Logger(subsystem: "com.irllabs.scoranger", category: "playhead")
                            .notice("no position at beat \(beat, privacy: .public); holding the last one")
                    }
                }
                .accessibilityHidden(true)
                // The handle is the one exception, and it is a view of its
                // own so that "the only hit-testable thing in this layer" is
                // a fact about the code rather than a promise in a comment.
                .overlay(alignment: .topLeading) {
                    if showsHandle {
                        let target = Playhead.onScreen(Playhead.handleTouchTarget,
                                                       zoom: zoom)
                        PlayheadHandle(
                            target: target,
                            bar: playback.soundingBar,
                            // The recogniser reports in the HANDLE's own
                            // coordinates now, so the corner it sits at is
                            // added back to get the layer's.
                            onScrub: { point in
                                scrub(to: CGPoint(x: x - target / 2 + point.x,
                                                  y: top - target / 2 + point.y),
                                      sx: sx, sy: sy)
                            },
                            onEnded: { scrubbed = nil },
                            onStep: { step($0) })
                            .frame(width: target, height: target)
                            .offset(x: x - target / 2, y: top - target / 2)
                    }
                }
            }
        }
    }

    /// The finger has moved: put the play head on the bar it is over.
    ///
    /// BAR granularity, and not an interpolation across the bar, for the same
    /// reason the mixer's scrubber chip reads `bar 21` rather than `2:14`:
    /// musicians seek by bar. It goes through `PlaybackEngine.seek(toBar:)`,
    /// which is the path the scrubber and a tap on a bar already take -- a
    /// second way to move the play head would be a second place for the
    /// repeat-expansion rule in `PlaybackTimeline.firstBeat(ofBar:)` to be got
    /// wrong.
    ///
    /// STOPPED and PLAYING are the same operation, deliberately. Dragging
    /// while stopped moves the cursor, the transport's readout and the mixer's
    /// scrubber and starts nothing; dragging while playing keeps playing, from
    /// there. Neither starts nor stops the transport, because the handle is
    /// not the play button and a scrub that started the music would make
    /// looking at a bar an act of performing it.
    private func scrub(to point: CGPoint, sx: CGFloat, sy: CGFloat) {
        guard sx > 0, sy > 0 else { return }
        let onPage = CGPoint(x: point.x / sx, y: point.y / sy)
        guard let bar = Playhead.bar(at: onPage, bars: bars), bar != scrubbed
        else { return }
        scrubbed = bar
        playback.seek(toBar: bar)
    }

    /// One bar either way, for a reader who cannot drag. VoiceOver's
    /// `.adjustable` swipe, which is the same path the mixer's grip offers
    /// for moving a panel.
    private func step(_ direction: Int) {
        guard let now = playback.soundingBar else { return }
        playback.seek(toBar: max(now + direction, 1))
    }

    private var position: Playhead.Position? {
        guard playback.isPlaying || playback.soundingBar != nil,
              let progress = playback.timeline.progress(atBeat: clock.beat)
        else { return nil }
        return Playhead.position(measure: progress.measure,
                                 fraction: CGFloat(progress.fraction), bars: bars)
    }
}

/// The grab handle at the top of the cursor: the ONLY thing in the cursor
/// layer a touch can reach.
///
/// A UIKit recogniser and not a SwiftUI `DragGesture`, and the reason decides
/// the whole design. This layer is inside `ZoomableScroll`'s UIScrollView, and
/// the scroll view carries the pan, the lasso recogniser and three Pencil taps
/// -- all of which see a touch that lands here too. A SwiftUI gesture has no
/// way to tell those to stand down, so the canvas would scroll while the
/// handle scrubbed. `shouldBeRequiredToFailBy` says it, to every one of them
/// at once, from a delegate this file owns.
///
/// And it is SCOPED by being the size of the handle. The view used to span
/// the layer and return nil from `hitTest` everywhere but the target, which
/// kept touches out but left a full-page view sitting over the canvas -- and
/// that OCCLUDED it: the two-finger undo tap could not resolve a point on the
/// score at all, proven by the gate in testOneUndoTapRemovesExactlyOneStroke
/// and testTwoFingerTapUndoesEvenWithMarkupOff, and proven to be this view by
/// the same test passing with the handle taken away. Hit testing keeps
/// touches out; it does not stop a view being in the way. So the view is now
/// 32pt square and positioned, and the rest of the page has nothing over it
/// -- which is what leaves the lasso and the Pencil untouched, the thing
/// `testThePlayheadDrawsAndTheLassoStillSelectsUnderIt` exists to catch.
///
/// FINGERS ONLY (`allowedTouchTypes`). Outside markup mode a Pencil drag is a
/// lasso and inside it a Pencil drag is ink; taking either away over a 32pt
/// square would be a gesture that silently eats a stroke. So Pencil behaviour
/// is exactly what it was, and what the drag costs is a finger pan that begins
/// on the handle itself.
private struct PlayheadHandle: UIViewRepresentable {
    /// How wide the handle is. The view IS this square; the caller places it.
    let target: CGFloat
    /// What the play head reads as, for VoiceOver.
    let bar: Int?
    /// Where the finger is, in the layer's coordinates.
    var onScrub: (CGPoint) -> Void
    var onEnded: () -> Void
    /// One bar forward or back, for a reader who cannot drag.
    var onStep: (Int) -> Void

    func makeUIView(context: Context) -> PlayheadHandleView {
        let view = PlayheadHandleView()
        view.backgroundColor = .clear
        let pan = UIPanGestureRecognizer(
            target: view, action: #selector(PlayheadHandleView.panned(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        pan.delegate = view
        view.addGestureRecognizer(pan)
        return view
    }

    func updateUIView(_ view: PlayheadHandleView, context: Context) {
        view.bar = bar
        view.onScrub = onScrub
        view.onEnded = onEnded
        view.onStep = onStep
    }
}

final class PlayheadHandleView: UIView, UIGestureRecognizerDelegate {
    var bar: Int?
    var onScrub: ((CGPoint) -> Void)?
    var onEnded: (() -> Void)?
    var onStep: ((Int) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityIdentifier = "playhead-handle"
        accessibilityLabel = "Play head"
        accessibilityTraits = [.adjustable]
        accessibilityHint = "Drag to move the play head"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("PlayheadHandleView is not from a nib") }

    override var accessibilityValue: String? {
        get { bar.map(BarName.text) ?? "start" }
        set { super.accessibilityValue = newValue }
    }

    override func accessibilityIncrement() { onStep?(1) }
    override func accessibilityDecrement() { onStep?(-1) }

    @objc func panned(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began, .changed: onScrub?(pan.location(in: self))
        case .ended, .cancelled, .failed: onEnded?()
        default: break
        }
    }

    // MARK: - Standing the scroll view, the lasso and the taps down

    /// Everything else waits for this to fail. It only ever fails when the
    /// touch was not a drag of the handle -- and it only ever sees touches
    /// that landed on the handle in the first place, so this costs the rest of
    /// the canvas nothing.
    func gestureRecognizer(_ recogniser: UIGestureRecognizer,
                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        true
    }

    /// Never alongside. A scrub that also scrolled the page would move the
    /// music out from under the finger driving it.
    func gestureRecognizer(_ recogniser: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }
}


/// The play head on the continuous strip: the line, the note under it, and the
/// scroll that keeps the line still (design/PLAYBACK_0.6.md 2, bug 6).
///
/// OBSERVES the engine, like `PlayheadLayer` and for the same reason: the beat
/// arrives twenty times a second and a position handed down from the canvas
/// would redraw the rasterised strip, the selection boxes and the tiles at that
/// rate. Only this view redraws, and the scroll it asks for goes through
/// `CanvasScroller`, which is not SwiftUI state at all.
///
/// The line is drawn where the music is, in the strip's own coordinates, and
/// the SCORE is moved so that place sits a third of the way across the screen.
/// Drawing a line fixed to the viewport instead would need the two to agree
/// about the scroll offset every frame, and they would not.
private struct ContinuousPlayheadLayer: View {
    /// Rate limit for the "not following" log line.
    nonisolated(unsafe) static var lastFollowLog = Date.distantPast
    @ObservedObject var playback: PlaybackEngine
    /// The beat at display rate -- see `PlayheadLayer.clock`. Following is
    /// driven from it too, so the strip glides with the line.
    @ObservedObject var clock: PlaybackClock
    /// The strip's engraving: one page, the whole score.
    let page: ScorePage?
    /// Surface points per unit of the engraving's own coordinates.
    let scale: CGFloat
    let surfaceWidth: CGFloat
    /// False once the reader has scrolled: the line keeps moving, the score
    /// stops being taken away from them.
    let isFollowing: Bool
    let scroller: CanvasScroller
    let showsHandle: Bool
    /// The scroll view's settled zoom. The strip is inside the same zoomable
    /// scroll view a page is, and this layer used to draw its constants raw --
    /// so the line that is a hairline at fit was a slab at 12x, which is
    /// exactly the fault `PlayheadLayer` divides to avoid.
    let zoom: CGFloat

    /// The bar the finger has already been given, and the flag that stops
    /// FOLLOWING while it is down: seeking moves the strip, the strip moves
    /// the music out from under the finger, and the next touch reading is of
    /// somewhere the reader never pointed at.
    @State private var scrubbed: Int?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let position {
                // The notes the line is crossing, under it rather than over it,
                // so a notehead is tinted and never covered.
                ForEach(Array(lit.enumerated()), id: \.offset) { _, frame in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.Accent.clay.opacity(0.28))
                        .frame(width: max(frame.width * scale, 6) + 4,
                               height: max(frame.height * scale, 6) + 4)
                        .position(x: frame.midX * scale, y: frame.midY * scale)
                }
                let over = Playhead.onScreen(Playhead.overshoot, zoom: zoom)
                let x = position.x * scale
                let top = position.top * scale - over
                let height = position.height * scale + over * 2
                Group {
                    Rectangle()
                        .fill(Theme.Accent.clay)
                        .frame(width: Playhead.onScreen(Playhead.weight, zoom: zoom),
                               height: height)
                        .position(x: x, y: top + height / 2)
                    if showsHandle {
                        RoundedRectangle(
                            cornerRadius: Playhead.onScreen(Playhead.handleRadius, zoom: zoom))
                            .fill(Theme.Accent.clay)
                            .frame(width: Playhead.onScreen(Playhead.handle, zoom: zoom),
                                   height: Playhead.onScreen(Playhead.handle, zoom: zoom))
                            .position(x: x, y: top)
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                if showsHandle {
                    let target = Playhead.onScreen(Playhead.handleTouchTarget, zoom: zoom)
                    PlayheadHandle(
                        target: target,
                        bar: playback.soundingBar,
                        // In the handle's own coordinates now; its corner puts
                        // them back in the layer's.
                        onScrub: { point in
                            scrub(to: CGPoint(x: x - target / 2 + point.x,
                                              y: top - target / 2 + point.y))
                        },
                        onEnded: { scrubbed = nil },
                        onStep: { step($0) })
                        .frame(width: target, height: target)
                        .position(x: x, y: top)
                }
            }
        }
        // Following happens on the same tick that draws the line, off the same
        // position, so the two can never disagree about where the music is.
        .onChange(of: clock.beat, initial: true) { _, _ in follow() }
    }

    /// The strip's own scrub. Same rule as the paged one, and one conversion
    /// less: the strip is a single engraved page, so the layer's coordinates
    /// are the engraving's multiplied by `scale`.
    private func scrub(to point: CGPoint) {
        guard let page, scale > 0 else { return }
        let onPage = CGPoint(x: point.x / scale, y: point.y / scale)
        guard let bar = Playhead.bar(at: onPage, bars: BarPosition.bars(onPage: page)),
              bar != scrubbed else { return }
        scrubbed = bar
        playback.seek(toBar: bar)
    }

    private func step(_ direction: Int) {
        guard let now = playback.soundingBar else { return }
        playback.seek(toBar: max(now + direction, 1))
    }

    private var progress: (measure: Int, fraction: Double)? {
        guard playback.isPlaying || playback.soundingBar != nil else { return nil }
        return playback.timeline.progress(atBeat: clock.beat)
    }

    private var position: Playhead.Position? {
        guard let page, let progress else { return nil }
        return Playhead.position(measure: progress.measure,
                                 fraction: CGFloat(progress.fraction),
                                 bars: BarPosition.bars(onPage: page))
    }

    /// The noteheads sounding right now, in ENGRAVED coordinates.
    private var lit: [CGRect] {
        guard let page, let progress, let position else { return [] }
        let notes: [(staff: Int, frame: CGRect)] = page.elements.compactMap { element in
            guard let address = element.address,
                  address.measure == progress.measure,
                  address.kind == .note || address.kind == .chord else { return nil }
            return (address.staff, element.frame)
        }
        return Playhead.sounding(notes: notes, x: position.x)
    }

    /// Not while the handle is being dragged. Following moves the strip so the
    /// line parks a third of the way in; do that while a finger is holding the
    /// handle and the music slides out from under it, the next touch reading
    /// lands somewhere the reader never pointed at, and that seeks again --
    /// a loop, driven at the beat rate, that ends wherever it happens to stop.
    /// Following resumes on release, which is when the reader wants to be
    /// shown where they landed.
    private func follow() {
        guard scrubbed == nil, isFollowing, playback.isPlaying, let position
        else {
            // Which gate closed, about once a second, so a strip that does not
            // scroll can say why from the device log.
            let now = Date()
            if now.timeIntervalSince(Self.lastFollowLog) > 1 {
                Self.lastFollowLog = now
                Logger(subsystem: "com.irllabs.scoranger", category: "follow").notice(
                    "not following: scrubbed=\(scrubbed.map(String.init) ?? "nil", privacy: .public) isFollowing=\(isFollowing, privacy: .public) playing=\(playback.isPlaying, privacy: .public) position=\(position == nil ? "nil" : "ok", privacy: .public) page=\(page == nil ? "nil" : "ok", privacy: .public) beat=\(clock.beat, privacy: .public)")
            }
            return
        }
        // Only WHERE the line is. The scroll view turns that into an offset
        // from its live bounds; the cached viewport this used to pass could
        // be zero and stayed zero (CanvasScroller).
        scroller.follow(playheadX: position.x * scale)
    }
}

/// Boxes over the selected elements, scaled from page coordinates to the size
/// the page is drawn at.
///
/// The BOX tracks the notehead and so scales with the zoom; its outline, its
/// padding, its corner and its minimum size are sizes ON SCREEN and so are
/// divided by it (`SelectionInk`). Undivided they are what Ali photographed:
/// at 12x a 1pt outline is a 12pt band and a 3pt overhang is 36, so a selected
/// chord came back as one orange blob with no music visible inside it.
/// One selection box: where it is, and what granularity it marks.
private struct SelectionHighlight: View {
    let frames: [SelectionBox]
    let pageSize: CGSize
    /// The scroll view's settled zoom. Same source as the playhead's.
    let zoom: CGFloat

    var body: some View {
        GeometryReader { geo in
            if !frames.isEmpty, pageSize.width > 0, pageSize.height > 0 {
                let sx = geo.size.width / pageSize.width
                let sy = geo.size.height / pageSize.height
                let corner = SelectionInk.onScreen(SelectionInk.highlightCorner,
                                                   zoom: zoom)
                let weight = SelectionInk.onScreen(SelectionInk.highlightWeight,
                                                   zoom: zoom)
                ForEach(Array(frames.enumerated()), id: \.offset) { _, box in
                    let frame = box.frame
                    // THE FILL MULTIPLIES; THE BORDER DOES NOT (§11).
                    //
                    // Multiply is what "behind the glyph" asked for without
                    // restructuring the layers: over white paper it leaves the
                    // tint unchanged, and over a black notehead the notehead
                    // stays black. The normal-blend fill shipping today washes
                    // a selected notehead to brown -- #41281C, 13.6:1 against
                    // paper, where multiply keeps it #191513 at 18.1:1. So it
                    // fixes a live legibility defect as well as putting the
                    // tint where it belongs.
                    //
                    // The BORDER keeps normal blending: multiplied it would
                    // darken unevenly wherever it crossed a stem or a staff
                    // line, and the border is what carries definition once the
                    // fill lets go.
                    RoundedRectangle(cornerRadius: corner)
                        .fill(Theme.Accent.clay
                                .opacity(SelectionInk.fillOpacity(for: box.kind)))
                        .blendMode(.multiply)
                        .overlay {
                            RoundedRectangle(cornerRadius: corner)
                                .stroke(Theme.Accent.clayStrong
                                            .opacity(SelectionInk.borderOpacity),
                                        lineWidth: weight)
                        }
                        .frame(width: SelectionInk.highlightExtent(
                                    engraved: frame.width, scale: sx, zoom: zoom),
                               height: SelectionInk.highlightExtent(
                                    engraved: frame.height, scale: sy, zoom: zoom))
                        .position(x: frame.midX * sx, y: frame.midY * sy)
                }
            }
        }
    }
}

private struct PageView: View {
    let page: PDFPage
    /// Which engraving, for the raster cache's key.
    let document: String
    let index: Int
    let width: CGFloat
    let rasterZoom: CGFloat
    let drawingStore: DrawingStore
    let drawingKey: String
    /// What the canvas calls itself out loud. See `ScorePagesView.canvasIdentity`.
    let identityKey: String
    /// The other participants' marks on this page, when the score is being
    /// read as part of a shared set list. Empty otherwise, which is every
    /// signed-out reader and every arrangement of your own
    /// (design/FIREBASE.md §6.3).
    var sharedInk: [SharedInk.Layer] = []
    @ObservedObject var annotation: AnnotationController

    var body: some View {
        let bounds = page.bounds(for: .mediaBox)
        let height = width * bounds.height / max(bounds.width, 1)
        ZStack {
            PDFPageImage(page: page, document: document, index: index,
                         size: CGSize(width: width, height: height),
                         rasterZoom: rasterZoom)
            // The canvas is laid out at the zoomed size and scaled back down,
            // so PencilKit magnifies the ink itself instead of the outer
            // transform stretching a picture of it. See InkSharpness.
            let ink = InkSharpness.canvasZoom(zoom: rasterZoom)
            // BENEATH the canvas, so my own pencil is always on top of it: ink
            // appearing under somebody else's scribble as you write reads as
            // the pencil failing (§6.3, and `InkLayers.drawOrder`).
            if !sharedInk.isEmpty {
                SharedInkOverlay(layers: sharedInk,
                                 pageSize: CGSize(width: width, height: height))
            }
            PencilCanvas(store: drawingStore, key: drawingKey, identity: identityKey,
                         controller: annotation, canvasZoom: ink)
                .frame(width: width * ink, height: height * ink)
                .scaleEffect(1 / ink, anchor: .topLeading)
                .frame(width: width, height: height, alignment: .topLeading)
        }
        .frame(width: width, height: height)
        .background(Theme.Surface.paper)
        // the warm ground sits close to paper white in luminance, so without an
        // edge the gap between pages reads as a hole rather than a page break
    }
}

private struct PDFPageImage: View {
    let page: PDFPage
    /// Which engraving, for the raster cache's key.
    let document: String
    let index: Int
    let size: CGSize
    /// Settled zoom: the page is drawn at the same size but rasterised finer,
    /// so zooming in sharpens without moving anything.
    let rasterZoom: CGFloat

    /// The last picture drawn, kept across a change of zoom so the page never
    /// blanks while the sharper one is being made.
    @State private var image: UIImage?

    var body: some View {
        // NEVER rasterised in the body. The raster used to be made right here
        // on the main thread, so a settled pinch stalled the frame for as
        // long as CoreGraphics took -- tens of milliseconds on a phone -- and
        // the same was true of every tile of the strip as the reader
        // scrolled it into view (0.8.0 build 195, measured at 3 fps). What
        // is held is drawn now; what is not is drawn off the main thread and
        // arrives when it is ready, the previous picture standing in.
        Group {
            if let image {
                Image(uiImage: image).resizable().interpolation(.high)
            } else {
                Theme.Surface.paper
            }
        }
        .frame(width: size.width, height: size.height)
        .task(id: key) {
            let wanted = key
            if let held = CanvasRasters.shared.held(wanted) { image = held; return }
            let page = self.page, size = self.size, scale = self.scale
            let make: @Sendable () -> UIImage = {
                PerfMetrics.shared.measure(PerfMetrics.Name.canvasPage) {
                    page.thumbnail(
                        of: CGSize(width: size.width * scale, height: size.height * scale),
                        for: .mediaBox)
                }
            }
            // The FIRST picture is drawn here and now, as it always was: with
            // nothing to stand in, a blank page is worse than a late frame,
            // and the machine is not asked to raster in parallel with the
            // engine that is preparing the same score's playback. Only a
            // SHARPER picture -- after a pinch -- is made off the main thread,
            // behind the one already showing.
            if image == nil {
                image = CanvasRasters.shared.value(for: wanted, cost: CanvasRasters.bytes, make: make)
                return
            }
            let made = await RasterWork.image(for: wanted, make: make)
            if !Task.isCancelled { image = made }
        }
    }

    /// The widest a page may be rastered, in pixels.
    ///
    /// This was 3000 while EVERY page rastered at the settled zoom: eight of
    /// them at that width is around 380MB, and the watchdog has killed this app
    /// for less. Now only the rows near the viewport draw at depth (see
    /// SpreadLayout.visibleRows), so the budget buys resolution where it can be
    /// seen instead of spreading it over pages that are off screen. Three rows
    /// at 5200px is roughly 320MB in the worst case and typically far less,
    /// while the pages nobody is looking at cost about 2MB each.
    private static let maxRasterWidth: CGFloat = 5200

    /// 2x for crispness, scaled up with the settled zoom, still bounded.
    private var scale: CGFloat {
        min(2.0 * rasterZoom, Self.maxRasterWidth / max(size.width, 1))
    }

    /// Drawn once per (engraving, page, size, zoom) and remembered.
    private var key: RasterKey {
        RasterKey(document: document, page: index,
                  tile: CGRect(origin: .zero, size: size), scale: 1, detail: scale)
    }
}

/// One tile of the continuous strip.
///
/// `PDFPageImage` rasters a whole page; this rasters a WINDOW onto one, by
/// putting the tile's left edge at the origin before asking the page to draw.
/// Tiles away from the viewport still draw, coarsely -- a blank gap where the
/// music should be reads as a broken score, and a cheap raster does not.
private struct ContinuousTileView: View {
    let page: PDFPage
    /// Which engraving this tile belongs to (`AppState.engravingKey`), so the
    /// picture can be remembered without keying on a pointer that outlives
    /// nothing.
    let document: String
    let index: Int
    /// The tile in SURFACE points (the strip as laid out on screen).
    let tile: CGRect
    /// Surface points per PDF point.
    let scale: CGFloat
    /// Which tiles draw at depth, published only when the set changes, so a
    /// drag re-evaluates the tiles a few times a second at most and never
    /// the strip.
    @ObservedObject var depth: TileDepthModel

    private var atDepth: Bool { depth.deep.contains(index) }

    /// The last picture drawn: the shallow raster stands in while the deep
    /// one is made, and the deep one stays when the tile leaves the depth.
    @State private var image: UIImage?

    var body: some View {
        // Off the main thread, as `PDFPageImage`: a tile coming into view
        // asked for its deep raster in the body, and thirty of them across a
        // drag put the strip at 3 fps on an iPhone 15 Pro (0.8.0 build 195).
        // What is held is drawn now; what is not arrives when it is ready.
        Group {
            if let image {
                Image(uiImage: image).resizable().interpolation(.high)
            } else {
                Theme.Surface.paper
            }
        }
        .frame(width: tile.width, height: tile.height)
        .task(id: key) {
            let wanted = key
            if let held = CanvasRasters.shared.held(wanted) { image = held; return }
            // Whatever is held at the other depth is better than paper.
            if image == nil, let other = CanvasRasters.shared.held(key(atDepth: !atDepth)) { image = other }
            let page = self.page, tile = self.tile, scale = self.scale, atDepth = self.atDepth
            let make: @Sendable () -> UIImage = {
                ContinuousTiles.raster(page: page, tile: tile, scale: scale, atDepth: atDepth)
            }
            // The first picture of a tile is drawn now, on the main thread, as
            // before (see PDFPageImage); the shallow one is cheap. Only the
            // deep raster a drag brings a tile into is made off-main, behind
            // the shallow one already showing -- which is the case the frame
            // probe measured at 3 fps.
            if image == nil {
                image = CanvasRasters.shared.value(for: wanted, cost: CanvasRasters.bytes, make: make)
                return
            }
            let made = await RasterWork.image(for: wanted, make: make)
            if !Task.isCancelled { image = made }
        }
    }

    /// Drawn once per (engraving, tile, scale, depth) and remembered: this
    /// body runs on every rebuild of the canvas, and the canvas is rebuilt
    /// by every publish on AppState, because `ZoomableScroll` swaps its
    /// hosting controller's root view whenever `ScorePagesView`'s body is
    /// re-evaluated.
    private var key: RasterKey { key(atDepth: atDepth) }

    private func key(atDepth deep: Bool) -> RasterKey {
        RasterKey(document: document, page: index, tile: tile, scale: scale,
                  detail: ContinuousTiles.detail(atDepth: deep))
    }
}

/// PencilKit canvas: pencil-only input so fingers keep scrolling the score.
/// Interactive only while annotation mode is on — with the mode off the canvas
/// still renders existing marks but passes every touch through, so the score
/// behaves like a plain document.
private struct PencilCanvas: UIViewRepresentable {
    let store: DrawingStore
    let key: String
    /// Only ever the accessibility identifier. Never a storage key.
    let identity: String
    @ObservedObject var controller: AnnotationController
    /// What PencilKit is asked to magnify the ink by. The view is laid out
    /// this much larger and scaled back down, so the strokes are RE-DRAWN at
    /// the zoom rather than stretched with everything else.
    var canvasZoom: CGFloat = 1

    /// The simulator has no Pencil, so UI tests ask for finger drawing to be
    /// able to exercise strokes and undo at all.
    private static let allowFingerDrawing =
        ProcessInfo.processInfo.arguments.contains("-annotateWithFinger")

    func makeUIView(context: Context) -> UndoableCanvas {
        let canvas = UndoableCanvas()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = Self.allowFingerDrawing ? .anyInput : .pencilOnly
        canvas.tool = controller.pkTool
        canvas.delegate = context.coordinator
        canvas.drawingKey = key
        canvas.drawing = store.drawing(for: key)
        canvas.isUserInteractionEnabled = controller.isOn
        // Loading a drawing must not look like an edit: clear anything
        // PencilKit registered while we assigned it.
        canvas.ownUndoManager.removeAllActions()

        if !Self.allowFingerDrawing {
            // drawingPolicy .pencilOnly governs what draws, but the canvas's
            // gesture recognizers still claim finger touches — which ate the
            // two-finger pinch. Restrict every recognizer to pencil touches so
            // finger scrolls and pinches pass through to the scroll view.
            let pencilOnly = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
            canvas.drawingGestureRecognizer.allowedTouchTypes = pencilOnly
            for recognizer in canvas.gestureRecognizers ?? [] {
                recognizer.allowedTouchTypes = pencilOnly
            }
        }

        // Two-finger tap undoes, the way it does in Apple's own note apps.
        // Declared simultaneous so it never cancels the scroll view's pinch.
        let undoTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTwoFingerTap))
        undoTap.numberOfTouchesRequired = 2
        undoTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        undoTap.delegate = context.coordinator
        undoTap.cancelsTouchesInView = false
        canvas.addGestureRecognizer(undoTap)

        context.coordinator.key = key
        context.coordinator.identity = identity
        context.coordinator.store = store
        context.coordinator.controller = controller
        context.coordinator.publishStrokeCount(canvas)
        // its own scrolling would fight the score's; only the zoom is wanted,
        // and only the zoom WE set
        canvas.isScrollEnabled = false
        canvas.bouncesZoom = false
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = InkSharpness.maximumFactor
        Self.disableOwnZoom(canvas)
        Self.sharpen(canvas, to: canvasZoom)
        return canvas
    }

    /// Hand the magnification to PencilKit.
    ///
    /// Setting `contentScaleFactor` -- on the canvas, on every subview, with
    /// the drawing reassigned to force a repaint -- was tried first and
    /// changed nothing on screen: PencilKit renders its strokes on its own
    /// terms and does not take that as an instruction to redraw. Its own
    /// `zoomScale` does, which is what laying the canvas out large and scaling
    /// it back down is for.
    private static func sharpen(_ canvas: PKCanvasView, to zoom: CGFloat) {
        let wanted = max(1, min(zoom, InkSharpness.maximumFactor))
        guard InkSharpness.isWorthRedrawing(from: canvas.zoomScale,
                                            to: wanted) else { return }
        canvas.zoomScale = wanted
    }

    func updateUIView(_ canvas: UndoableCanvas, context: Context) {
        if context.coordinator.key != key {
            context.coordinator.key = key
            context.coordinator.identity = identity
        context.coordinator.identity = identity
            canvas.drawingKey = key
            canvas.drawing = store.drawing(for: key)
            canvas.ownUndoManager.removeAllActions()
            context.coordinator.publishStrokeCount(canvas)
        }
        context.coordinator.controller = controller
        canvas.isUserInteractionEnabled = controller.isOn
        canvas.tool = controller.pkTool
        Self.sharpen(canvas, to: canvasZoom)
        // Again here, not only at creation: a UIScrollView makes its pinch
        // recognizer lazily, so the one set up in makeUIView was often not
        // there yet to be turned off (#45).
        Self.disableOwnZoom(canvas)
    }

    /// The canvas may be zoomed BY US and never by the reader.
    ///
    /// PKCanvasView is a UIScrollView, and giving it a zoom range so PencilKit
    /// would re-render the ink crisply also handed it a working pinch. In ink
    /// mode, where the canvas takes touches, a two-finger pinch then zoomed the
    /// INK on its own -- off-centre, sliding over a score that stayed put
    /// (#45). The score's own scroll view owns zooming; this one is only ever
    /// told what scale to draw at.
    private static func disableOwnZoom(_ canvas: PKCanvasView) {
        canvas.pinchGestureRecognizer?.isEnabled = false
        canvas.panGestureRecognizer.isEnabled = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, PKCanvasViewDelegate, UIGestureRecognizerDelegate {
        var key: String = ""
        var identity: String = ""
        var store: DrawingStore?
        var controller: AnnotationController?

        /// Stroke count as an accessibility value: the only way a UI test can
        /// observe what the canvas actually holds.
        func publishStrokeCount(_ canvas: PKCanvasView) {
            canvas.isAccessibilityElement = true
            canvas.accessibilityIdentifier = "canvas-\(identity)"
            canvas.accessibilityValue = "\(canvas.drawing.strokes.count) strokes"
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            store?.save(canvasView.drawing, for: key)
            publishStrokeCount(canvasView)
            guard let canvas = canvasView as? UndoableCanvas else { return }
            MainActor.assumeIsolated {
                controller?.noteChange(on: canvas)
            }
        }

        @objc func handleTwoFingerTap(_ sender: UITapGestureRecognizer) {
            guard let canvas = sender.view as? UndoableCanvas else { return }
            MainActor.assumeIsolated {
                _ = controller?.undo(on: canvas)
                publishStrokeCount(canvas)
            }
        }

        // the score scrolls and pinches under the canvas; never block that
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

struct ChipShadow: ViewModifier {
    func body(content: Content) -> some View { Theme.Elevation.pill(content) }
}

/// The scroll view's visible rect, kept OFF `ScorePagesView`'s own state.
///
/// As `@State` on the pages view, every 24pt of a drag re-evaluated the whole
/// score body, and `ZoomableScroll` swaps its hosting root view whenever that
/// body changes -- the page stack, the ink canvases and the strip laid out
/// again mid-gesture. Measured on an iPhone 15 Pro (0.8.0 build 195): 97 fps
/// with the reports on, 118 with them off, out of 120. Here the rect is an
/// observable of its own, and only the views that need it -- the strip's
/// tiles deciding their depth, the Sync chip -- observe it.
@MainActor
final class ViewportModel: ObservableObject {
    @Published private(set) var rect: CGRect = .zero
    /// Which tiles of the strip draw at depth (`ContinuousTiles.atDepth`),
    /// published on its own object so the tiles observe THIS and not every
    /// 24pt of the viewport.
    let depth = TileDepthModel()
    private var lastLivePublish: CFTimeInterval = 0
    private var lastLiveDepth: CFTimeInterval = 0

    /// A report from the scroll view. While the score is moving under a
    /// finger or its momentum, the rect is published at most ten times a
    /// second and the depth set at most twice, so a drag costs a handful of
    /// small re-evaluations instead of one per frame; at rest, both at once.
    func update(rect: CGRect, live: Bool, tiles: [CGRect]) {
        let now = CACurrentMediaTime()
        if !live || now - lastLivePublish >= 0.1 {
            lastLivePublish = now
            if self.rect != rect { self.rect = rect }
        }
        guard !tiles.isEmpty else { return }
        // `-perfFreezeDepth`: an experiment -- no depth changes while live.
        if live, Self.freezeDepthWhileLive { return }
        if !live || now - lastLiveDepth >= 0.5 {
            lastLiveDepth = now
            let deep = ContinuousTiles.atDepth(tiles: tiles, visible: rect)
            if deep != depth.deep { depth.deep = deep }
        }
    }

    /// The first frame, before the scroll view has reported.
    func seed(_ rect: CGRect) { if self.rect == .zero { self.rect = rect } }

    private static let freezeDepthWhileLive =
        ProcessInfo.processInfo.arguments.contains("-perfFreezeDepth")
}

@MainActor
final class TileDepthModel: ObservableObject {
    @Published var deep: Set<Int> = []
}

/// Draws `content` for the viewport's rect, re-evaluating itself alone when
/// the rect moves.
private struct ViewportReader<Content: View>: View {
    @ObservedObject var viewport: ViewportModel
    @ViewBuilder let content: (CGRect) -> Content
    var body: some View { content(viewport.rect) }
}
