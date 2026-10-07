import SwiftUI

/// A pushed screen's chrome (NAV_MODAL_FREE_0.4.2 §1, §3).
///
/// A nav bar that NAMES where back goes. "‹ My library" rather than a bare
/// chevron: a stack you can trust is one where you never count taps to get out.
struct Screen<Content: View, Trailing: View>: View {
    let title: String
    let backLabel: String
    var subtitle: String?
    var onBack: () -> Void
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content
    /// False for content that scrolls itself (the settings split).
    var scrolls = true
    @Environment(\.inPanel) private var inPanel
    @Environment(\.panelTitle) private var panelTitle

    var body: some View {
        VStack(spacing: 0) {
            if inPanel {
                // 0.8: inside the panel the screen IS a panel state (§7.2):
                // its header is the panel's -- ‹ when the panel opened from
                // another state, the name, Done -- and there is no nav bar.
                PanelHeader(title: title.isEmpty ? (panelTitle ?? "") : title,
                            subtitle: subtitle, trailing: trailing)
            } else {
                navBar
            }
            if scrolls {
                ScrollView {
                    // The content column: capped and centred on a pushed page
                    // (a row's label and its chevron 1300pt apart is not a row),
                    // the panel's own width inside the panel.
                    content()
                        .frame(maxWidth: inPanel ? .infinity : Theme.Metric.readingColumn)
                        .frame(maxWidth: .infinity)
                }
            } else {
                content().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.Surface.panel)
    }

    private var navBar: some View {
        HStack(spacing: Theme.Metric.s8) {
            Button(action: onBack) {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    // One line: on a phone bar with three controls beside
                    // it, "Library" wrapped to "Librar / y" (0.19.0).
                    Text(backLabel).typeRole(.control).lineLimit(1).fixedSize()
                }
                .foregroundStyle(Theme.Accent.clayStrong)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // collapsed to ONE element: a Button whose label is a stack is
            // reported as a container, and the identifier lands on
            // something untappable -- the selection chip's bug, third time
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Back to \(backLabel)")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("screen-back")

            Spacer(minLength: Theme.Metric.s8)
            VStack(spacing: 0) {
                Text(title).typeRole(.titleS).foregroundStyle(Theme.Ink.ink)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle).typeRole(.meta).foregroundStyle(Theme.Ink.ink3)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Theme.Metric.s8)
            trailing()
        }
        .padding(.horizontal, Theme.Metric.s16)
        .frame(height: Theme.Metric.scoreTopBar)
        .background(Theme.Surface.panel)
        .overlay(alignment: .bottom) {
            Theme.Rule()
        }
    }
}

extension Screen where Trailing == EmptyView {
    init(title: String, backLabel: String, subtitle: String? = nil,
         onBack: @escaping () -> Void, scrolls: Bool = true,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, backLabel: backLabel, subtitle: subtitle,
                  onBack: onBack, trailing: { EmptyView() }, content: content, scrolls: scrolls)
    }
}

/// A row of a screen: a label, an optional current answer, and a chevron when
/// it leads somewhere.
///
/// The trailing value is what makes these screens read as a summary rather than
/// a menu (§3.2) -- `Move to piece › Cavatina` answers the question before you
/// tap it.
struct ScreenRow: View {
    let title: String
    var value: String?
    var leads: Bool = true
    var isDestructive: Bool = false
    /// The row stands for what is on screen right now -- one version of many,
    /// one arrangement of a piece. Marked, not just tinted, so a test and a
    /// screen reader can both tell which one it is.
    var isSelected: Bool = false
    var identifier: String
    var action: () -> Void
    @Environment(\.inPanel) private var inPanel

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Metric.s8) {
                Text(title).typeRole(.row)
                    .foregroundStyle(isDestructive ? Theme.Status.danger : Theme.Ink.ink)
                    // WRAPS rather than overflowing (§6.3 rule 1): an HStack
                    // that cannot fit its children draws them outside itself.
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Theme.Metric.s8)
                if let value {
                    Text(value).typeRole(.data).foregroundStyle(Theme.Ink.ink3).lineLimit(1)
                }
                if leads {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.Ink.ink3)
                }
            }
            .padding(.horizontal, Theme.Metric.s16)
            .padding(.vertical, Theme.Metric.s8)
            .frame(minHeight: 44)
            // A panel item (§7.2): a `band` capsule, `clayTint` when it is the
            // current one, transparent with `danger` text when destructive.
            .background(isSelected ? Theme.Accent.clayTint
                        : (isDestructive ? Color.clear : Theme.Surface.band))
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, inPanel ? Theme.Metric.panelSide : Theme.Metric.s16)
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(value.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityIdentifier(identifier)
    }
}

/// The inline confirm (§7.9).
///
/// A destructive item becomes, in place, a `clayTint` block the panel's
/// width: the question, one sentence naming the consequence, and two buttons,
/// the verb on `danger` and Keep. No alert, no sheet, nothing to dismiss.
/// Used for Delete, Delete for everybody, Leave, Remove a person, Delete a
/// piece. `what` is the question; `consequence` the sentence.
struct ConfirmDeleteStrip: View {
    let what: String
    var consequence: String?
    var verb: String = "Delete"
    var identifier: String
    var onDelete: () -> Void
    var onKeep: () -> Void
    @Environment(\.inPanel) private var inPanel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metric.s8) {
            Text(what).typeRole(.titleS).foregroundStyle(Theme.Ink.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let consequence, !consequence.isEmpty {
                Text(consequence).typeRole(.body).foregroundStyle(Theme.Ink.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Theme.Metric.s8) {
                Button(action: onDelete) {
                    Text(verb).typeRole(.control)
                        .foregroundStyle(Theme.Surface.paper)
                        .padding(.horizontal, Theme.Metric.s16)
                        .frame(height: 40)
                        .background(Theme.Status.danger)
                        .clipShape(Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(identifier)
                Button(action: onKeep) {
                    Text("Keep").typeRole(.control)
                        .foregroundStyle(Theme.Ink.ink)
                        .padding(.horizontal, Theme.Metric.s16)
                        .frame(height: 40)
                        .background(Theme.Surface.panel)
                        .clipShape(Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("\(identifier)-keep")
            }
            .padding(.top, Theme.Metric.s4)
        }
        .padding(Theme.Metric.s16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Accent.clayTint)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.rInner))
        .padding(.horizontal, inPanel ? Theme.Metric.panelSide : Theme.Metric.s16)
        .padding(.vertical, Theme.Metric.s4)
        .accessibilityElement(children: .contain)
    }
}

struct InlineRenameRow: View {
    @Binding var text: String
    /// "Piece name", "Set list name", or "Name" for a rename.
    var placeholder: String = "Name"
    /// `inline-create-row` for a new thing, `inline-rename-row` for a rename,
    /// so the two purposes are separable in tests.
    var containerIdentifier: String = "inline-rename-row"
    /// The list's title edge: `s20`, plus the checkbox gutter in Edit mode.
    var leading: CGFloat = Theme.Metric.s20
    /// A proposed name arrives selected whole, so one keystroke replaces it.
    var selectAll: Bool = false
    var onSave: () -> Void
    var onCancel: () -> Void

    @FocusState private var focused: Bool
    @ScaledMetric(relativeTo: .body) private var scaledControl: CGFloat = 34

    /// One height for the field and both buttons: `max(34, scaled)`, so no
    /// literal survives at accessibility sizes. The row's 92 follows.
    private var control: CGFloat { max(34, scaledControl) }
    private var canSave: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        // Two lines, not one (REDESIGN_BRIEF_0.8 §7.2). At 393pt a single row
        // left the field 189pt; two lines give it 365 and let both lines sit
        // on the list's own grid: the field at the title edge, Save at the
        // ☰ column's edge. The row fill is the app's in-progress tint, the
        // field is paper, and there is no third fill.
        VStack(alignment: .trailing, spacing: Theme.Metric.s8) {
            field
                .frame(maxWidth: .infinity)
            HStack(spacing: Theme.Metric.s8) {
                Button(action: onCancel) {
                    Text("Cancel").typeRole(.control).foregroundStyle(Theme.Ink.ink2)
                        .padding(.horizontal, Theme.Metric.s12)
                        .frame(minWidth: 80, minHeight: control)
                        .background(Theme.Surface.paper)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.rCtl))
                        .contentShape(RoundedRectangle(cornerRadius: Theme.Metric.rCtl))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("inline-rename-cancel")
                Button(action: onSave) {
                    Text("Save").typeRole(.control).foregroundStyle(Theme.Surface.paper)
                        .padding(.horizontal, Theme.Metric.s12)
                        .frame(minWidth: 80, minHeight: control)
                        .background(Theme.Accent.clayPress)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.rCtl))
                        .contentShape(RoundedRectangle(cornerRadius: Theme.Metric.rCtl))
                }
                .buttonStyle(.plain)
                // Disabled, not hidden, so the row does not reflow as the
                // first character lands.
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.42)
                .accessibilityIdentifier("inline-rename-save")
            }
        }
        .padding(.leading, leading)
        .padding(.trailing, Theme.Metric.s8)
        .padding(.vertical, Theme.Metric.s8)
        .frame(maxWidth: .infinity)
        .background(Theme.Accent.clayTint)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(containerIdentifier)
        .onAppear { focused = true }
    }

    @ViewBuilder
    private var field: some View {
        Group {
            if #available(iOS 18.0, *) {
                SelectingTextField(placeholder: placeholder, text: $text,
                                   selectAll: selectAll, focused: $focused)
            } else {
                TextField(placeholder, text: $text).focused($focused)
            }
        }
        .typeRole(.body)
        .foregroundStyle(Theme.Ink.ink)
        .tint(Theme.Accent.clay)
        .textFieldStyle(.plain)
        .submitLabel(.done)
        .onSubmit { if canSave { onSave() } }
        .padding(.horizontal, Theme.Metric.s12)
        .frame(minHeight: control)
        .background(Theme.Surface.paper)
        .overlay { RoundedRectangle(cornerRadius: Theme.Metric.rCtl).strokeBorder(Theme.Accent.clay, lineWidth: 1) }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.rCtl))
        .accessibilityIdentifier("inline-rename-field")
    }
}

/// A text field that can arrive with its text SELECTED, so a proposed name is
/// replaced whole by the first keystroke (REDESIGN_BRIEF_0.8 §7.4 rule 4).
/// `TextSelection` is iOS 18; the row falls back to a plain field before it.
@available(iOS 18.0, *)
private struct SelectingTextField: View {
    var placeholder: String
    @Binding var text: String
    var selectAll: Bool
    var focused: FocusState<Bool>.Binding
    @State private var selection: TextSelection?

    var body: some View {
        TextField(placeholder, text: $text, selection: $selection)
            .focused(focused)
            .onChange(of: focused.wrappedValue) { _, isFocused in
                guard isFocused, selectAll else { return }
                // After the field has taken focus, or the caret placement
                // that comes with focusing lands on top of this.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    selection = TextSelection(range: text.startIndex..<text.endIndex)
                }
            }
    }
}

/// The undo bar (§5.2), in the action bar's slot.
///
/// A bar is not a modal: anchored, blocking nothing, and the list scrolls
/// behind it. It is offered because the engine marks rather than unlinks --
/// without the two-phase delete behind it this would be a button that lies.
/// What the app has to say when something did not happen.
///
/// It exists because `notice` was written in five places and read in none:
/// an import that found nothing, a PDF that would not transcribe, a missing OMR
/// service -- each set a message that no view ever showed, so the app answered
/// every one of them by returning to the library without a word. A message
/// stays until it is dismissed; it is shown BECAUSE something went wrong, and a
/// reader who looked away should still find it.
struct NoticeBar: View {
    let message: String
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Metric.s8) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Ink.ink2)
                .padding(.top, 2)
            Text(message).typeRole(.row).foregroundStyle(Theme.Ink.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("notice-text")
            Spacer(minLength: Theme.Metric.s8)
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Ink.ink2)
                    .frame(width: Theme.Metric.hitTarget, height: Theme.Metric.hitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
            .accessibilityIdentifier("notice-dismiss")
        }
        .padding(.horizontal, Theme.Metric.s16)
        .padding(.vertical, Theme.Metric.s12)
        .background(Theme.Surface.panel)
        .overlay(alignment: .top) { Theme.Rule() }
        .shadow(color: Color(hex: 0x1A1917).opacity(0.07), radius: 18, y: -6)
        .accessibilityIdentifier("notice-bar")
    }
}

/// What a bundle holds, and the one tap that takes it in.
///
/// Somebody AirDropped an arrangement or a setlist. Nothing has been imported
/// yet: this says what is in the file -- what it is called, how many pieces,
/// whose markup rides along -- and waits (design/FIREBASE.md §13.3).
///
/// A bar rather than a sheet, on the UndoBar's shape, because the no-modal rule
/// (NAV_MODAL_FREE_0.4.2 §1) applies to surfaces this app invents and this is
/// one. The reader can ignore it and it costs them nothing.
struct BundleOfferBar: View {
    let summary: String
    let detail: String
    var onImport: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Theme.Metric.s8) {
            Image(systemName: "shippingbox")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Ink.ink2)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary).typeRole(.row).foregroundStyle(Theme.Ink.ink)
                    .accessibilityIdentifier("bundle-offer-summary")
                Text(detail).typeRole(.data).foregroundStyle(Theme.Ink.ink3)
                    .accessibilityIdentifier("bundle-offer-detail")
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Metric.s8)
            PanelButton(title: "Add to my library", kind: .primary, action: onImport)
                .accessibilityIdentifier("bundle-import")
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Ink.ink2)
                    .frame(width: Theme.Metric.hitTarget, height: Theme.Metric.hitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
            .accessibilityIdentifier("bundle-dismiss")
        }
        .padding(.horizontal, Theme.Metric.s16)
        .padding(.vertical, Theme.Metric.s8)
        .frame(minHeight: 56)
        .background(Theme.Surface.panel)
        .overlay(alignment: .top) { Theme.Rule() }
        .shadow(color: Color(hex: 0x1A1917).opacity(0.07), radius: 18, y: -6)
        .accessibilityIdentifier("bundle-offer-bar")
    }
}

struct UndoBar: View {
    let what: String
    var seconds: Int = 10
    var onUndo: () -> Void
    var onDismiss: () -> Void

    @State private var remaining: Int = 10

    var body: some View {
        HStack(spacing: Theme.Metric.s8) {
            Text("Deleted \(what).").typeRole(.row).foregroundStyle(Theme.Ink.ink)
            Text("restorable for \(remaining)s").typeRole(.data)
                .foregroundStyle(Theme.Ink.ink3)
            Spacer(minLength: Theme.Metric.s8)
            PanelButton(title: "Undo", kind: .primary, action: onUndo)
                .accessibilityIdentifier("undo-delete")
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Ink.ink2)
                    .frame(width: Theme.Metric.hitTarget, height: Theme.Metric.hitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, Theme.Metric.s16)
        .frame(height: 56)
        .background(Theme.Surface.panel)
        .overlay(alignment: .top) { Theme.Rule() }
        .shadow(color: Color(hex: 0x1A1917).opacity(0.07), radius: 18, y: -6)
        .accessibilityIdentifier("undo-bar")
        .onAppear { remaining = seconds }
        .task {
            // A plain countdown, and it only decides when the BAR goes: the
            // engine's own window is what decides whether undo would work, and
            // it is deliberately longer so a slow tap still lands.
            while remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                remaining -= 1
            }
            onDismiss()
        }
    }
}

/// A name you edit by tapping it.
///
/// There is no Rename button anywhere any more: the value IS the control. A
/// button whose only job is to let you edit the thing next to it is a button
/// that exists because the thing next to it was not tappable -- so the thing is
/// tappable instead, and the button goes.
///
/// Commit on return, cancel on escape or by tapping away. Modal-free by
/// construction: the keyboard is the only thing that overlays, and that is the
/// OS (NAV_MODAL_FREE_0.4.2 §5.1).
struct EditableTitle: View {
    let text: String
    var role: Theme.Role = .titleS
    var identifier: String
    /// Opens straight into the field, for a row that is already being renamed.
    var startEditing = false
    var onCommit: (String) -> Void

    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("Name", text: $draft)
                    .typeRole(role)
                    .foregroundStyle(Theme.Ink.ink)
                    .tint(Theme.Accent.clay)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit { commit() }
                    .padding(.horizontal, Theme.Metric.s6)
                    .padding(.vertical, 3)
                    .background(Theme.Surface.paper)
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Metric.rCtl)
                            .stroke(Theme.Accent.clay, lineWidth: 1)
                    }
                    .accessibilityIdentifier("\(identifier)-field")
                    .onAppear { focused = true }
                    .onChange(of: focused) { _, isFocused in
                        // tapping away commits, the way a renamed file does
                        if !isFocused && editing { commit() }
                    }
            } else {
                Button {
                    draft = text
                    editing = true
                } label: {
                    Text(text).typeRole(role).foregroundStyle(Theme.Ink.ink)
                        .lineLimit(1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(identifier)
                .accessibilityLabel("\(text), tap to rename")
            }
        }
        .onAppear {
            if startEditing && !editing { draft = text; editing = true }
        }
    }

    private func commit() {
        editing = false
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != text else { return }
        onCommit(name)
    }
}
