import SwiftUI

/// The chat overlay's body. Its subject line and model alias live in the
/// overlay header (§8 screen 03), so this is the transcript and the input only.
struct ChatView: View {
    @EnvironmentObject var state: AppState
    @State private var draft = ""
    @FocusState private var inputFocused: Bool
    @StateObject private var dictation = SpeechDictation()
    /// Draft text at the moment dictation started; recognized speech appends to it.
    @State private var dictationBase = ""
    /// How tall the input box is, in lines of text. Six by default: three was
    /// enough for "transpose down a third" and not for anything a person
    /// actually wants to say about a selection.
    /// Zero means AUTO: the box is the size of what is in it, one line to
    /// four, and grows as you type. The grip still overrides it.
    ///
    /// It used to default to six lines, so an empty chat opened with a 200pt
    /// box holding a one-line placeholder and the conversation above it was
    /// squeezed into what was left (L31). A NEW key, because the six is stored
    /// on every device that has run this app and the stored value is the bug.
    @AppStorage("chatInputLines2") private var inputLines: Double = 0
    /// The box's height while the grip is held, in POINTS, following the finger
    /// exactly; it snaps to whole lines only when the grip is let go (0.19.0).
    /// It used to be a whole number of lines computed afresh on every drag
    /// event, from a translation measured in the grip's OWN coordinates -- and
    /// the grip moves as the box grows, so each frame's resize fed back into the
    /// next frame's reading and the box juddered up and down (Ali's recording).
    @State private var dragHeight: CGFloat?
    /// Where the drag started, so the travel is added to a fixed height.
    @State private var dragStartHeight: CGFloat?
    /// The field's laid-out height, which is where a drag from an auto-sized
    /// box starts.
    @State private var fieldHeight: CGFloat = 21

    /// The range the grip can drag through. Two lines is still usable; above
    /// about fourteen the transcript has no room left on an iPad in a panel.
    private static let lineRange: ClosedRange<Double> = 2...14
    /// One line of the input's body text, near enough for the drag to feel
    /// like it is moving lines rather than pixels.
    private static let lineHeight: CGFloat = 21

    /// How many lines the box is DRAGGED to, or nil while it is auto-sized.
    private var draggedLines: Int? {
        if let dragHeight { return Int((dragHeight / Self.lineHeight).rounded()) }
        guard inputLines >= Self.lineRange.lowerBound else { return nil }
        return Int(min(inputLines, Self.lineRange.upperBound).rounded())
    }

    /// The height the box is held at: the finger's while dragging, the stored
    /// whole lines otherwise, nil while auto-sized.
    private var pinnedHeight: CGFloat? {
        dragHeight ?? draggedLines.map { CGFloat($0) * Self.lineHeight }
    }

    private static var heightRange: ClosedRange<CGFloat> {
        CGFloat(lineRange.lowerBound) * lineHeight...CGFloat(lineRange.upperBound) * lineHeight
    }

    /// What the grip reports, and the cap the text may grow to.
    private var effectiveLines: Int { draggedLines ?? Self.autoLines }

    /// The cap an auto-sized box grows to before it scrolls. Four lines is a
    /// sentence and a half -- past that the conversation above matters more
    /// than seeing the whole of what you are typing.
    private static let autoLines = 4

    private var slug: String? { state.selectedScore?.slug }
    /// How many arrangements the open one shares its piece with (1 = it's alone,
    /// so there is nothing to refer to by number).
    private var siblingCount: Int {
        slug.flatMap { state.placement(of: $0)?.piece.arrangements.count } ?? 0
    }
    private var messages: [ChatDisplayMessage] {
        slug.flatMap { state.chatMessages[$0] } ?? []
    }
    private var liveSteps: [ChatStep] {
        slug.flatMap { state.activeChatSteps[$0] } ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Metric.s12) {
                        if messages.isEmpty { primer }
                        ForEach(messages) { msg in
                            bubble(msg).id(msg.id)
                        }
                        if state.chatBusy {
                            opCard.id("live-progress")
                        }
                    }
                    .padding(.vertical, Theme.Metric.s12)
                }
                .onChange(of: messages.count) {
                    if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onChange(of: liveSteps.count) {
                    proxy.scrollTo("live-progress", anchor: .bottom)
                }
            }
            inputGrip
            inputBar
        }
        .background(Theme.Surface.panel)
    }

    private var primer: some View {
        VStack(alignment: .leading, spacing: Theme.Metric.s8) {
            Text("Ask for an arrangement — “drop the piano”, “transpose down a minor third”, “give the cello line to a viola”…")
            if siblingCount > 1 {
                Text("Refer to the other arrangements of this piece by number: “take the violin part from #2”.")
            }
        }
        .typeRole(.body)
        .foregroundStyle(Theme.Ink.ink2)
        .padding(.horizontal, Theme.Metric.panelPadding)
    }

    // MARK: - Bubbles (§7.7)

    /// A bordered card with a caps author label above the text: cheaper than
    /// tails, and it survives having no colour to spare.
    @ViewBuilder
    private func bubble(_ msg: ChatDisplayMessage) -> some View {
        HStack {
            if msg.role == .user { Spacer(minLength: Theme.Metric.s32) }
            VStack(alignment: .leading, spacing: Theme.Metric.s6) {
                Text(authorLabel(msg.role))
                    .typeRole(.label)
                    .foregroundStyle(msg.role == .error ? Theme.Status.danger
                                                        : Theme.Accent.clayStrong)
                if let steps = msg.steps, !steps.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Metric.s4) {
                        ForEach(steps) { step in stepRow(step) }
                    }
                    Theme.Rule()
                }
                Text(msg.text)
                    .typeRole(.body)
                    .foregroundStyle(Theme.Ink.ink)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 11)
            .background(fill(for: msg.role))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Metric.rPanel)
                    .stroke(border(for: msg.role), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.rPanel))
            .frame(maxWidth: 300, alignment: msg.role == .user ? .trailing : .leading)
            if msg.role != .user { Spacer(minLength: Theme.Metric.s32) }
        }
        .padding(.horizontal, Theme.Metric.panelPadding)
    }

    private func authorLabel(_ role: ChatDisplayMessage.Role) -> String {
        switch role {
        case .user:  return "You"
        case .agent: return "Agent"
        case .error: return "Failed"
        }
    }

    private func fill(for role: ChatDisplayMessage.Role) -> Color {
        switch role {
        case .user:  return Theme.Accent.clayTint
        case .agent: return Theme.Surface.panel
        case .error: return Theme.Status.errorFill
        }
    }

    private func border(for role: ChatDisplayMessage.Role) -> Color {
        switch role {
        case .user:  return Theme.Accent.clayBorder
        case .agent: return Theme.Line.line2
        case .error: return Theme.Status.errorBorder
        }
    }

    // MARK: - Op card (§7.8)

    /// The live checklist: a band header stating the count, one row per op, and
    /// a spinner tail. Keeps its final state in the transcript when the turn ends.
    private var opCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            BandHeader("Working · \(liveSteps.count) op\(liveSteps.count == 1 ? "" : "s")")
            VStack(alignment: .leading, spacing: Theme.Metric.s4) {
                ForEach(liveSteps) { step in stepRow(step) }
                HStack(spacing: Theme.Metric.s8) {
                    ProgressView().controlSize(.small).tint(Theme.Accent.clay)
                    Text(liveSteps.isEmpty ? "planning…" : "thinking…")
                        .typeRole(.meta)
                        .foregroundStyle(Theme.Ink.ink3)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.rPanel))
        .padding(.horizontal, Theme.Metric.panelPadding)
    }

    /// Status glyph, the op in prose, its arguments in mono.
    @ViewBuilder
    private func stepRow(_ step: ChatStep) -> some View {
        let failed = step.detail?.hasPrefix("⚠") ?? false
        HStack(alignment: .firstTextBaseline, spacing: Theme.Metric.s6) {
            Image(systemName: step.done ? (failed ? "exclamationmark.triangle" : "checkmark")
                                        : "circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(step.done ? (failed ? Theme.Status.warn : Theme.Status.ok)
                                           : Theme.Ink.ink3)
                .frame(width: 13)
            Text(step.title)
                .typeRole(.meta)
                .foregroundStyle(Theme.Ink.ink)
            if let detail = step.detail {
                Text(detail)
                    .typeRole(.data)
                    .foregroundStyle(failed ? Theme.Status.warn : Theme.Ink.ink2)
            }
        }
    }

    /// Move what the lasso caught into the input, where the user is about to
    /// type, so the selection is visibly in hand.
    private func consumePendingInsert() {
        guard let insert = state.pendingChatInsert, !insert.isEmpty else { return }
        let sep = draft.isEmpty || draft.hasSuffix(" ") ? "" : " "
        draft = draft + sep + insert
        state.pendingChatInsert = nil
        inputFocused = true
    }

    /// The divider between the transcript and the input, draggable.
    ///
    /// Dragging UP makes the box taller, which is why the sign is inverted: the
    /// grip is at the box's top edge, so moving it up grows the box downward
    /// into the space the transcript gives back.
    ///
    /// ONE mark (design/BOOK_EXTRACT_0.19.md §A): the dashed rule, broken
    /// around a handle sitting on it. It was a solid line, a capsule under it
    /// and the input bar's own dashed rule -- three marks in 20pt, two of them
    /// lines of different kinds, which Ali called awkward. The row is 20pt in
    /// the layout and 44pt to a finger: it reaches 12pt into the padding above
    /// and below, neither of which holds a control, and sits over the
    /// transcript so its scroll view never claims the touch first.
    private var inputGrip: some View {
        let dragging = dragHeight != nil
        return ZStack {
            Theme.Rule()
            Capsule()
                .fill(dragging ? Theme.Accent.clay : Theme.Ink.ink3)
                .frame(width: dragging ? 44 : 36, height: 4)
                .padding(.horizontal, Theme.Metric.s8)
                .background(Theme.Surface.panel)
                .animation(Theme.Motion.pillState, value: dragging)
        }
        .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20)
        .frame(height: Theme.Metric.hitTarget)
        .contentShape(Rectangle())
        .padding(.vertical, -(Theme.Metric.hitTarget - 20) / 2)
        .zIndex(1)
        .gesture(
            // GLOBAL coordinates: the grip moves as the box grows, so a
            // translation read in its own space is not the finger's travel.
            DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStartHeight ?? (pinnedHeight ?? fieldHeight)
                    if dragStartHeight == nil { dragStartHeight = start }
                    let wanted = start - value.translation.height
                    dragHeight = min(max(wanted, Self.heightRange.lowerBound),
                                     Self.heightRange.upperBound)
                }
                .onEnded { _ in
                    let lines = Double(draggedLines ?? Self.autoLines)
                    withAnimation(.snappy(duration: 0.18)) {
                        inputLines = lines
                        dragHeight = nil
                    }
                    dragStartHeight = nil
                }
        )
        .accessibilityIdentifier("chat-input-grip")
        .accessibilityLabel("Resize the message box")
        .accessibilityValue("\(effectiveLines) lines")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: inputLines = min(inputLines + 1, Self.lineRange.upperBound)
            case .decrement: inputLines = max(inputLines - 1, Self.lineRange.lowerBound)
            @unknown default: break
            }
        }
    }

    // MARK: - Input (§7.13)

    /// Half the height of the one-line field (9pt padding above and below a
    /// line), so one line is exactly a pill and more lines are not a stadium.
    private static let inputShape = RoundedRectangle(cornerRadius: 9 + lineHeight / 2,
                                                     style: .continuous)

    private var inputBar: some View {
        HStack(spacing: Theme.Metric.s8) {
            TextField(dictation.errorText ?? "Arrange…", text: $draft, axis: .vertical)
                // a stable name: the placeholder stops identifying the field
                // the moment there is text in it
                .accessibilityIdentifier("chat-input")
                .typeRole(.body)
                // explicit ink: an unstyled field takes the system foreground,
                // which is white wherever the OS thinks it is dark
                .foregroundStyle(Theme.Ink.ink)
                .tint(Theme.Accent.clay)
                // One line, growing to the cap -- or to whatever the grip was
                // dragged to, which is the one thing that pins the height.
                // A FIXED limit while the box is pinned: a limit that moved with
                // every line of a drag re-laid the field out each time it did.
                .lineLimit(1...(pinnedHeight == nil ? Self.autoLines
                                                    : Int(Self.lineRange.upperBound)))
                .frame(minHeight: pinnedHeight, alignment: .topLeading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fieldHeight = $0 }
                .focused($inputFocused)
                .onSubmit(send)
                .padding(.vertical, 9)
                .padding(.horizontal, 10)
                // ONE shape for the fill and the outline, with a radius of
                // half a single line's height: a pill on one line, a rounded
                // box when the grip makes it taller. The fill used to be a
                // plain rectangle under a capsule outline (rCtl is 999), so a
                // tall box showed square paper corners outside a stadium-
                // shaped ring -- Ali's "messy" (0.17.0).
                .background(Theme.Surface.paper, in: Self.inputShape)
                .overlay {
                    Self.inputShape
                        .stroke(inputFocused ? Theme.Accent.clay : Color.clear, lineWidth: 1.5)
                }
                .onChange(of: state.pendingChatInsert) { _, _ in consumePendingInsert() }
                // and on appear: a lasso sets the text and opens the panel in
                // the same breath, so the value is already there by the time
                // this view exists and no change event will ever arrive
                .onAppear { consumePendingInsert() }
                .onChange(of: dictation.transcript) {
                    guard !dictation.transcript.isEmpty else { return }
                    let sep = dictationBase.isEmpty || dictationBase.hasSuffix(" ") ? "" : " "
                    draft = dictationBase + sep + dictation.transcript
                }

            PanelIconButton(systemName: dictation.isRecording ? "mic.fill" : "mic",
                            label: dictation.isRecording ? "Stop dictation" : "Start dictation",
                            tint: dictation.isRecording ? Theme.Status.danger : Theme.Ink.ink2) {
                if dictation.isRecording {
                    dictation.stop()
                } else {
                    dictationBase = draft
                    dictation.start()
                }
            }

            // A GLYPH, not the word. "Send" was laid out beside a field that
            // takes the rest of the row, and at the panel's width the label was
            // clipped to "Sen…" (L32). An icon cannot be clipped.
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.Surface.paper)
                    .frame(width: 34, height: 34)
                    .background(Theme.Accent.clayPress)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.rCtl))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat-send")
            .accessibilityLabel("Send")
            .disabled(state.chatBusy || draft.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(state.chatBusy || draft.trimmingCharacters(in: .whitespaces).isEmpty
                     ? 0.42 : 1)
        }
        .padding(.horizontal, Theme.Metric.s12)
        .padding(.bottom, Theme.Metric.s12)
        .padding(.top, Theme.Metric.s8)
        .background(Theme.Surface.panel)
    }

    private func send() {
        if dictation.isRecording { dictation.stop() }
        let text = draft
        draft = ""
        state.sendChat(text)
    }
}
