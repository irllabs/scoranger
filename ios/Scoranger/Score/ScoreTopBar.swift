import SwiftUI

/// The score view's top bar (NAVIGATION_SYSTEM.md §4.5, 12.9–12.11).
///
/// This is what the pill becomes. Its pieces go to their own places: library →
/// X and the tabs, `#N` → the title block, the version chip → the title
/// dropdown, gear → `…`, pencil → Edit, chat → Ask (§8).
///
/// The bar also STATES THE MODE, which is not decoration: the whole of §6 rests
/// on the Pencil meaning exactly one thing at a time, and a mode you cannot see
/// is a mode you cannot trust.
struct ScoreTopBar: View {
    @EnvironmentObject var state: AppState
    @Environment(\.horizontalSizeClass) private var hSize
    @ObservedObject var annotation: AnnotationController
    let number: Int?
    let title: String
    let subtitle: String
    /// Where the reader came from -- a set list's name, a piece's, or
    /// "Library" -- for the way out [C6]. The bar never leaves with ✕.
    var origin: String = "Library"
    @Binding var mode: ScoreMode
    @Binding var titleMenuOpen: Bool
    /// Which column the title band is showing. The versions dropdown opens the
    /// VERSIONS; the title block opens the arrangements of the piece. They used
    /// to open one two-column band, so "N versions" put a list of other pieces
    /// on screen beside the thing that was asked for (0.6.3 #8).
    @Binding var titleMenuMode: TitleBandLayout.Mode
    /// Measured, so the bar can say what it can seat (#60).
    ///
    /// Owned by `ContentView` since 0.6.8, because the Options screen has to
    /// read the SAME fit: it carries the two switches at exactly the widths
    /// this bar cannot seat them, and two independent notions of what fits
    /// would leave a width where a switch appears twice or not at all.
    @Binding var barWidth: CGFloat
    @Binding var moreOpen: Bool
    var chatOpen: Bool
    var onClose: () -> Void
    var onAsk: () -> Void
    /// Which of the phone's TWO rows this instance is (Ph4).
    ///
    /// One type, two instances, rather than a second view holding copies of
    /// the layout cells, Perform and the +. Copies are how the bar and the
    /// Options screen came to disagree about which of them owned a switch,
    /// and these three carry more state between them than that pair did.
    enum Row { case bar, second }
    var row: Row = .bar

    var body: some View {
        switch row {
        case .bar:
            if mode == .performance { performanceBar } else { fullBar }
        case .second:
            if mode != .performance && fit.secondRow { secondRow }
        }
    }

    /// The phone's second row: the layout control, Perform and the + , centred
    /// over the tray (Ph4). Everything in it came off the bar, so nothing here
    /// is a new control and nothing is in two places.
    private var secondRow: some View {
        HStack(spacing: Theme.Metric.s8) {
            Spacer(minLength: 0)
            // Each at its own width, so the row reads as three controls
            // side by side rather than one stretched capsule: an HStack
            // hands its slack to whatever will take it, and Perform's
            // label took all of it.
            layoutControl.fixedSize()
            performanceToggle.fixedSize()
            if ScoreBarLayout.secondRowFitsPlus(width: barWidth) {
                addToSetlistTrigger.fixedSize()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Metric.s12)
        .padding(.vertical, Theme.Metric.s6)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("score-second-row")
    }

    // MARK: - Reading and editing

    private var fullBar: some View {
        HStack(spacing: Theme.Metric.s8) {
            // FIXED, and first. Nothing added to this bar may push the way out
            // of the score off it -- on a phone that left no way back at all
            // (#60). The priority and the fixed size are belt and braces over
            // ScoreBarLayout's own arithmetic.
            barButton("chevron.left", word: fit.showsOriginName ? origin : nil,
                      label: "Back to \(origin)",
                      identifier: "score-close", action: onClose)
                .fixedSize()
                .layoutPriority(2)
            Spacer(minLength: Theme.Metric.s8)
            titleBlock
                // On a narrow bar the title takes the slack instead of the
                // spacers taking it; on a wide one the spacers still centre it.
                .frame(maxWidth: fit.titleExpands ? .infinity : nil,
                       alignment: .leading)
            if fit.showsVersions { versionsTrigger }
            Spacer(minLength: Theme.Metric.s8)
            if fit.showsEdit {
                barButton("pencil", label: "Edit", identifier: "score-edit",
                          active: mode == .edit) {
                    mode = (mode == .edit) ? .read : .edit
                    annotation.isOn = (mode == .edit)
                }
            }
            selectArm
            barButton("bubble.left", label: "Ask", identifier: "score-ask",
                      active: chatOpen, action: onAsk)
            if fit.showsAddToSetlist { addToSetlistTrigger }
            // Print (0.17.0): on the pages, never on the strip, which is one
            // endless system a printer cannot take. Present in the fit either
            // way, so switching layout does not reflow the bar.
            if fit.showsPrint {
                barButton("printer", label: "Print", identifier: "score-print") {
                    ScorePrinting.present(state.pdfDocument, title: title)
                }
                .disabled(!ScorePrinting.available(in: state.layoutChoice)
                          || state.pdfDocument == nil)
                .opacity(ScorePrinting.available(in: state.layoutChoice) ? 1 : 0.35)
            }
            // On a phone these three are the second row's (Ph4); everywhere
            // else they are the bar's, as they have always been.
            if !fit.secondRow {
                layoutControl
                if fit.showsPerformanceToggle { performanceToggle }
            }
            if fit.showsOMRProgress {
                OMRProgressChip(control: omr) { moreOpen = true; titleMenuOpen = false }
            }
            barButton("ellipsis", label: "More", identifier: "score-more",
                      active: moreOpen) { moreOpen.toggle(); titleMenuOpen = false }
        }
        .padding(.horizontal, Theme.Metric.s12)
        // minHeight at the size class's own number: 44 on a phone, 52 on an
        // iPad (§9.6). A minimum rather than a height, because every label in
        // the bar scales with Dynamic Type and a fixed height is what cuts
        // them off (§6.3 rule 1).
        .frame(minHeight: Theme.Metric.scoreTopBar(compact: hSize == .compact))
        .fixedSize(horizontal: false, vertical: true)
        // The width is measured by the SCORE SCREEN's own GeometryReader
        // (`ContentView.body`) and not here. A `.background` is given the
        // same size as the content it sits behind, so a bar that overflows
        // reports its OVERFLOWED width -- and then seats more, because the fit
        // believes it has the room. It is a loop that settles wherever the
        // content happens to land: on a 402pt iPhone it seated the numeral,
        // the pencil and the subtitle, and the title itself collapsed to "S…".
        //
        // It is the same mistake the mixer made in a different place. A
        // surface measured against its own ideal size always reports that it
        // fits.
        .background(Theme.Surface.panel)
        .overlay(alignment: .bottom) {
            Theme.Rule()
        }
    }

    /// Performance mode collapses the bar to a strip (§4.5, N10): the score
    /// gets the screen, and the only things left are the way out and a
    /// statement of what mode you are in.
    ///
    /// It said what the Pencil was for, too, until Ali asked for that label
    /// gone from every size class and both devices -- for the second time. It
    /// is a reminder and not a feature: what mode you are in is the word
    /// PERFORMANCE beside it.
    private var performanceBar: some View {
        HStack(spacing: Theme.Metric.s8) {
            barButton("chevron.left", label: "Leave performance mode",
                      identifier: "score-close") { mode = .read }
            Text("PERFORMANCE").typeRole(.label)
                .foregroundStyle(Theme.Accent.clayStrong)
            Spacer()
            // A transcription started before the reader went into performance
            // mode is still running, and this bar was the one place with no
            // sign of it at all.
            if state.omrBusy { OMRProgressChip(control: omr, action: nil) }
            // Performance mode strips the bar to the way out and the mode, but
            // switching version is what a player does mid-rehearsal and there
            // was NO route to it here at all.
            versionsTrigger
        }
        .padding(.horizontal, Theme.Metric.s12)
        .frame(height: Theme.Metric.scoreTopBarPerformance)
        .background(Theme.Surface.panel)
        .overlay(alignment: .bottom) {
            Theme.Rule()
        }
        // .contain, or the identifier on this stack takes its children with it:
        // the bar became one element and the version control inside it did not
        // exist to a tap. The title band carries the same note for the same
        // reason.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("performance-bar")
    }

    /// The + that puts this arrangement in a set list (0.6.11 #1).
    ///
    /// It opens the title band in its third mode rather than a panel of its
    /// own -- the band already knows how tall to be, when to scroll and how to
    /// get out of the way (`TitleBandLayout`), and a floating checklist beside
    /// it would be a second answer to all three.
    ///
    /// The direction is what makes this worth a control at all: the library
    /// files arrangements INTO a set list, one set list at a time, and this
    /// asks the opposite question -- where does THIS arrangement belong? Both
    /// routes stay; neither replaces the other.
    private var addToSetlistTrigger: some View {
        barButton("plus", label: "Add to set list", identifier: "score-add-setlist",
                  active: setlistsOpen) {
            titleMenuOpen = (titleMenuMode == .setlists) ? !titleMenuOpen : true
            titleMenuMode = .setlists
            moreOpen = false
        }
        .accessibilityValue(SetlistMembership.summary(
            for: state.selectedScore?.slug ?? "",
            in: state.manifest?.setlists ?? []))
    }

    private var setlistsOpen: Bool { titleMenuOpen && titleMenuMode == .setlists }

    /// What OMR is doing, read from the one signal the app keeps for it
    /// (`AppState.omrHere`, the status of THIS arrangement's job). No
    /// second notion: the Make editable switch in Options reads exactly this.
    private var omr: OMRControl {
        MakeEditable.control(status: state.omrHere)
    }

    /// Performance mode, on the bar (0.6.8).
    ///
    /// It was the top row of the Options screen -- two taps and a screen away
    /// from the music, for the one control that changes what every input on
    /// that music means. The bar already STATES the mode; this is the switch
    /// that sets it, beside the other two controls that say what you are
    /// looking at.
    ///
    /// Only the way IN. The way out is the performance bar's own ✕, which has
    /// always been there and reads "Leave performance mode" -- and once
    /// performance mode is on, this bar is not the bar on screen.
    private var performanceToggle: some View {
        // A labelled button, glyph and word [C5]; §6 says the perform glyph
        // never appears without its word.
        barButton("rectangle.expand.vertical", word: "Perform", label: "Perform",
                  identifier: "score-performance",
                  active: mode == .performance) {
            mode = .performance
            // The same line the Options row ran: performance mode and ink are
            // the same Pencil, and it cannot mean both (§6).
            annotation.isOn = false
        }
        .accessibilityValue(mode == .performance ? "on" : "off")
    }

    /// Page / spread / continuous, as one segmented control.
    ///
    /// It REPLACES the two-page-spread button: they are three answers to one
    /// question, and as separate toggles they could both be on -- a state with
    /// no meaning (see `ScoreLayout`). Absent in performance mode, which is
    /// the bar that has nothing but the way out.
    ///
    /// The spec asked for ONE `.adjustable` element here. It is three buttons
    /// instead, deliberately: `.accessibilityElement(children: .ignore)` on a
    /// container collapses its children, and a collapsed cell cannot be tapped
    /// -- by a UI test or by anyone using Switch Control or Full Keyboard
    /// Access. This codebase has been caught by exactly that three times (the
    /// title block, the title band, and the performance bar earlier today).
    /// Three labelled buttons read fine in VoiceOver and can actually be
    /// pressed.
    private var layoutControl: some View {
        HStack(spacing: 0) {
            ForEach(Array(ScoreLayout.available(
                            isCompact: isCompact || fit.layoutCells <= 2).enumerated()),
                    id: \.element) { index, option in
                if index > 0 {
                    Theme.Rule(vertical: true).frame(height: 34)
                }
                layoutCell(option)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.rCtl))
        // Three answers to ONE question, so they are drawn as one thing: the
        // app's dashed rule closed around the group (Ali, 2026-09-14 #7).
        // The boundary is the group's, not a cell's -- the active cell keeps
        // the single clean shape build 195 gave it.
        .dashedBoundary()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("score-layout")
    }

    /// Continuous re-engraves the score with no system breaks, which only
    /// Verovio can do. A scan has no engraving, so the cell is shown disabled
    /// rather than removed -- a control that appears and disappears with the
    /// arrangement is harder to trust than one that is plainly unavailable.
    private func isAvailable(_ option: ScoreLayout) -> Bool {
        option != .continuous || state.displayedArtifact == .notation
    }

    private func layoutCell(_ option: ScoreLayout) -> some View {
        // The CHOICE, not what is drawn: the cell lights the moment it is
        // pressed, while the canvas keeps the pages it has until the new
        // engraving lands (`AppState.layout`).
        let active = state.layoutChoice == option
        let available = isAvailable(option)
        return Button {
            guard state.layoutChoice != option else { return }
            state.layoutChoice = option
            // continuous has no pages to be on, and coming back from it the
            // reader should be at the top of the score rather than at an index
            // the strip never had
            state.pageIndex = 0
            Task { await state.renderIfNeeded() }
        } label: {
            // ONE shape for the active cell: the segment itself, tinted, with
            // the glyph in clayStrong. A pill stroke used to be drawn inside
            // the tinted rectangle, so the rectangle's corners showed past
            // the pill and the outer capsule's clip left a second sliver of
            // tint beside it -- three layers where Ali saw "things that
            // should not be visible" (0.8.0 build 195, item A).
            Image(systemName: option.glyph)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(!available ? Theme.Ink.ink3
                                 : (active ? Theme.Accent.clayStrong : Theme.Ink.ink2))
                .frame(width: 40, height: 34)
                .background(active ? Theme.Accent.clayTint : Theme.Surface.panel)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .accessibilityLabel(option.label)
        .accessibilityHint(available ? "" : ScoreArtifact.whyNotEditable())
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : [.isButton])
        .accessibilityIdentifier("layout-\(option.rawValue)")
    }

    /// "N versions" -- the control that opens the version dropdown.
    ///
    /// A SIBLING of the title button, never a child of it: `titleBlock`
    /// collapses its children into one accessibility element, so a button
    /// drawn inside it is findable and untappable (the same trap the title
    /// block's own comment records). It opens the same band the title does,
    /// because the band IS the dropdown -- one surface, two ways in.
    @ViewBuilder
    private var versionsTrigger: some View {
        if let label = ScoreTitle.versionsLabel(count: versionCount) {
            Button {
                // Always the VERSIONS column, and OPENED rather than toggled
                // shut when the band is already showing arrangements -- a
                // control that closes the thing you asked it for is a control
                // nobody presses twice.
                // The named complaint: "clicking on the drop-down for
                // versions can take a second". The flip below returns at once;
                // what is waited for is the rebuild it triggers, so the FRAME
                // is what is timed.
                PerfMetrics.shared.measureUntilPresented(PerfMetrics.Name.versionMenu)
                titleMenuOpen = (titleMenuMode == .versions) ? !titleMenuOpen : true
                titleMenuMode = .versions
                moreOpen = false
            } label: {
                HStack(spacing: 4) {
                    Text(label).typeRole(.data)
                        .foregroundStyle(versionsOpen ? Theme.Accent.clayStrong
                                                      : Theme.Ink.ink3)
                        .lineLimit(1).fixedSize()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(versionsOpen ? Theme.Accent.clayStrong
                                                      : Theme.Ink.ink3)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(versionsOpen ? Theme.Surface.well : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.rCtl))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityHint("Switch to another version")
            .accessibilityAddTraits(versionsOpen ? [.isButton, .isSelected] : [.isButton])
            .accessibilityIdentifier("score-versions")
        }
    }

    /// The band is open AND showing versions. Two facts now, because the band
    /// has two things it can be showing and only one of them lights this
    /// control.
    private var versionsOpen: Bool { titleMenuOpen && titleMenuMode == .versions }
    private var arrangementsOpen: Bool { titleMenuOpen && titleMenuMode == .arrangements }

    private var versionCount: Int { state.selectedScore?.versions.count ?? 0 }

    /// A phone is offered page and continuous only: a spread across 390pt is
    /// two thumbnails, and this bar has no room for a third cell there.
    private var isCompact: Bool { hSize == .compact }

    /// What this bar can seat. See `ScoreBarLayout` for the order things yield
    /// in -- ✕ never does (#60).
    private var fit: ScoreBarLayout.Fit {
        ScoreBarLayout.fit(barWidth: barWidth, omrBusy: state.omrBusy,
                           compact: isCompact)
    }

    private var titleBlock: some View {
        Button {
            PerfMetrics.shared.measureUntilPresented(PerfMetrics.Name.titleMenu)
            // On a bar too narrow to seat the version count, the title block
            // opens VERSIONS instead -- restoring the invariant ScoreBarLayout
            // still states: dropping the count "drops a shortcut, never a
            // feature". 0.6.3 #8 split the band into two columns and ended that
            // guarantee without noticing, leaving a phone with no route to
            // versions at reading width at all. Arrangements stay reachable
            // from the library; versions are reachable from nowhere else.
            let wanted: TitleBandLayout.Mode = fit.showsVersions ? .arrangements : .versions
            titleMenuOpen = (titleMenuMode == wanted) ? !titleMenuOpen : true
            titleMenuMode = wanted
            moreOpen = false
        } label: {
            HStack(spacing: Theme.Metric.s8) {
                if let number, fit.showsNumeral {
                    NumeralBadge(number: number, role: .numeralM)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).typeRole(.titleS).foregroundStyle(Theme.Ink.ink)
                        .lineLimit(1)
                    HStack(spacing: Theme.Metric.s6) {
                        if fit.showsSubtitle {
                            Text(subtitle).typeRole(.data)
                                .foregroundStyle(Theme.Ink.ink3)
                                .lineLimit(1)
                        }
                        // The "Pencil: …" chip stood here until 0.6.10. Ali
                        // asked for it gone. What states the mode now: the
                        // Edit button's own active state, and Selection & chat
                        // in words. The bar keeps the 90pt.
                    }
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.Ink.ink3)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(arrangementsOpen ? Theme.Surface.well : Color.clear)
            .overlay {
                if arrangementsOpen {
                    RoundedRectangle(cornerRadius: Theme.Metric.rCtl)
                        .stroke(Color.clear, lineWidth: 0)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.rCtl))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // one element, not a stack. A Button whose label is a stack is reported
        // as a CONTAINER: it is findable, and a tap on it reaches the container
        // rather than the button -- so the title band never opened. VoiceOver
        // reads the parts separately for the same reason.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(subtitle)")
        .accessibilityHint("Switch to another arrangement of this piece")
        .accessibilityAddTraits(arrangementsOpen ? [.isButton, .isSelected] : [.isButton])
        .accessibilityIdentifier("score-title")
    }

    /// Arm the lasso, beside Ask (§9.3).
    ///
    /// Tapping needs no mode. A lasso does: a one-finger drag is already pan
    /// and page turn, and this app separates inputs by mode rather than by a
    /// guess at timing or distance. On a phone there is no Pencil to carry
    /// the loop, so the finger needs the mode the Pencil never did.
    ///
    /// One tap arms it for a single loop; a second latches it for several.
    /// The label says which, because a mode the reader cannot see is the one
    /// that eats their next pan.
    @ViewBuilder
    private var selectArm: some View {
        let arming = state.lassoArming
        barButton("scope", label: arming.label, identifier: "score-select",
                  active: arming.isArmed) { state.toggleLasso() }
            .overlay(alignment: .topTrailing) {
                // Latched is a different state from armed and has to look
                // different: the difference is what happens to the NEXT
                // gesture, and there is nothing else on screen saying so.
                if arming == .latched {
                    Circle().fill(Theme.Accent.clayStrong)
                        .frame(width: 6, height: 6)
                        .offset(x: -2, y: 2)
                        .accessibilityHidden(true)
                }
            }
    }

    /// A capsule control in the bar (§7.5). Glyph alone is a 34pt circle;
    /// with a `word` it is a capsule carrying both, which is how Perform [C5]
    /// and the way out [C6] read. The lit state is tint plus a 1.5pt clay
    /// ring; at rest there is no border (§4).
    private func barButton(_ glyph: String, word: String? = nil, label: String,
                           identifier: String, active: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Metric.s6) {
                Image(systemName: glyph)
                    .font(.system(size: 15, weight: .regular))
                if let word {
                    // One line, an ellipsis, and a cap: a set list called
                    // "Tuesday at the Ship with everybody" is not allowed to
                    // push the bar's controls off the edge [C8, C16].
                    Text(word).typeRole(.control).lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 140, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
                .foregroundStyle(active ? Theme.Accent.clayStrong : Theme.Ink.ink2)
                .frame(minWidth: 34, minHeight: 34)
                .padding(.horizontal, word == nil ? 0 : Theme.Metric.s12)
                .background(active ? Theme.Accent.clayTint : Theme.Surface.well)
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Metric.rCtl)
                        .stroke(active ? Theme.Accent.clay : Color.clear, lineWidth: 1.5)
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.rCtl))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }
}

/// A transcription, running, at the trailing end of the top bar (0.6.8).
///
/// The reader could start OMR from the Options screen and then had NO sign in
/// the score view that it was running: the switch reported its own progress on
/// the screen that was left behind, and the score itself said nothing for the
/// minute or two the conversion takes. A reader who came back to the music saw
/// a PDF that was still a PDF.
///
/// It reads the SAME signal the Make editable switch does -- `AppState.omrHere`
/// and the stage of the pending import it started, through `MakeEditable` --
/// because two notions of "is OMR running" fall out of step the moment either
/// moves.
///
/// `action` opens Options, where the switch and its full report live. Nil where
/// there is nowhere to go: the performance bar has no `…`.
struct OMRProgressChip: View {
    let control: OMRControl
    var action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) { chip }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityHint("Open Options to see the transcription")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("score-omr-progress")
        } else {
            chip
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityIdentifier("score-omr-progress")
        }
    }

    private var label: String { "Transcribing, \(control.detail)" }

    private var chip: some View {
        HStack(spacing: Theme.Metric.s6) {
            ring
            Text(control.detail)
                .typeRole(.data)
                .foregroundStyle(Theme.Accent.clayStrong)
                .lineLimit(1)
                // FIXED. A Text yields before anything else in an HStack, so
                // reserving the width in ScoreBarLayout is not enough on its
                // own: the bar squeezed this one to "reading page 8…" while its
                // budget said it had room. ScoreBarLayout.omrWidth is what
                // keeps the fixed size from pushing anything off the bar.
                .fixedSize()
        }
        .padding(.horizontal, Theme.Metric.s8)
        .frame(height: 34)
        .background(Theme.Accent.clayTint)
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Metric.rCtl)
                .stroke(Theme.Accent.clayBorder, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.rCtl))
        .contentShape(Rectangle())
    }

    /// A ring rather than a bar: a bar wants a width the top bar has not got,
    /// and the words beside it already say how far along the job is. Drawn as
    /// a path for the determinate case for the same reason the whistle's
    /// circles are -- the fraction has to be visible at 16pt.
    @ViewBuilder
    private var ring: some View {
        if let fraction = control.fraction {
            ZStack {
                Circle()
                    .stroke(Theme.Accent.clayBorder, lineWidth: 2)
                Circle()
                    .trim(from: 0, to: max(0.02, min(fraction, 1)))
                    .stroke(Theme.Accent.clayStrong,
                            style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 16, height: 16)
        } else {
            ProgressView().controlSize(.small).tint(Theme.Accent.clay)
        }
    }
}

/// What the arrangement on screen IS: a PDF, or engraved notation (0.6.3 #5).
///
/// Top left of the canvas, opposite the page and bar counters, because it is
/// the same kind of fact -- something about what you are looking at rather
/// than a control. It is the fact that explains the rest of the screen: why
/// the pencil selects nothing, why continuous is greyed out, why the transport
/// says there is nothing to play. Every one of those was discoverable only by
/// trying it and failing.
///
/// It says the CONSEQUENCE as well as the format. "PDF" alone answers a
/// question nobody asked; "PDF · not editable" answers the one they have.
struct ArtifactMarker: View {
    let kind: ScoreArtifact.Kind

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: kind == .notation ? "music.note.list" : "doc.text")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(kind == .notation ? Theme.Accent.clayStrong
                                                   : Theme.Ink.ink3)
            Text(ArtifactTag.label(kind))
                .typeRole(.data)
                .foregroundStyle(kind == .notation ? Theme.Accent.clayStrong
                                                   : Theme.Ink.ink2)
            Text(ArtifactTag.markerDetail(kind))
                .typeRole(.meta)
                .foregroundStyle(Theme.Ink.ink3)
        }
        .padding(.horizontal, Theme.Metric.s8)
        .padding(.vertical, 4)
        .background(kind == .notation ? Theme.Accent.clayTint : Theme.Surface.panel)
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Metric.rCtl)
                .stroke(kind == .notation ? Theme.Accent.clayBorder : Color.clear, lineWidth: 1.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.rCtl))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(ArtifactTag.label(kind)), \(ArtifactTag.markerDetail(kind))")
        .accessibilityIdentifier("artifact-marker")
    }
}

/// Page and bar counters (12.11).
///
/// §7 expected `bar N` to wait on a parallel session for the geometry layer. It
/// does not: `ScoreGeometry` is already here -- selection is built on it -- and
/// every element it holds carries the measure it belongs to. The bar showing is
/// the lowest-numbered one actually on screen.
struct PositionCounters: View {
    /// Nil in continuous mode, which has no pages to count.
    let pages: String?
    let bar: Int?
    /// Test-only: the per-page SYSTEM count, passed in under `-geometryProbe`
    /// and nil otherwise. See `ScoreGeometry.probeDescription`.
    var probe: String? = nil

    var body: some View {
        HStack(spacing: Theme.Metric.s6) {
            if let pages { chip(pages, identifier: "counter-pages") }
            // Test-only, under -geometryProbe and nothing else: the per-page
            // SYSTEM count, which is the one thing that tells a collapsed
            // layout from a short piece that genuinely fits on a page. Same
            // shape as the seed flags; invisible and zero-sized, so it costs
            // a shipped build nothing but the branch.
            if let probe {
                Color.clear.frame(width: 0, height: 0)
                    .accessibilityIdentifier("geometry-probe")
                    .accessibilityLabel(probe)
            }
            // one place decides how a bar reads, and it is unit-tested
            if let label = BarPosition.label(for: bar) {
                chip(label, identifier: "counter-bar")
            }
        }
    }

    private func chip(_ text: String, identifier: String) -> some View {
        Text(text)
            .typeRole(.data)
            .foregroundStyle(Theme.Ink.ink2)
            .padding(.horizontal, Theme.Metric.s8)
            .padding(.vertical, 4)
            .background(Theme.Surface.panel)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.rCtl))
            .accessibilityIdentifier(identifier)
    }
}
