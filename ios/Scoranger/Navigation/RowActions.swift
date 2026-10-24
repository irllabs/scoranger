import SwiftUI

// A row's own actions, inside the row (design/DESIGN_SYSTEM.md §7.3, [C4]).
//
// ☰ becomes ✕ and the actions take the meta line's slot as 36pt `paper`
// capsules; the row is a flat `clayTint` band the width of the page, its
// contents do not move, and the action whose panel is open is lit. Delete
// becomes "Delete? [Delete] [Keep]" in the same slot (L8). The finger moves
// along the row, never off it (§3 Travel); the next level opens beside.

/// One action on a row.
struct RowActionItem: Identifiable {
    let id: String
    let title: String
    var glyph: String?
    var count: Int?
    var destructive = false
    var enabled = true
    /// Lit: the panel this action opens is the one showing (§7.5).
    var lit = false
    /// The question the inline confirm asks, for a destructive action that
    /// confirms in place. nil acts at once.
    var confirm: String?
    var action: () -> Void
}

/// The actions, as one line of capsules in the row's slot.
struct RowActionsBar: View {
    let actions: [RowActionItem]
    /// The action that is asking "Delete? [Delete] [Keep]" right now.
    @State private var confirming: String?

    var body: some View {
        ScrollViewReader { strip in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Metric.s6) {
                    ForEach(actions) { item in
                        if confirming == item.id, let question = item.confirm {
                            confirmInPlace(item, question: question)
                        } else {
                            capsule(item)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            // The question replaces the capsule and is wider than it, and on a
            // narrow row it opened past the strip's edge where nobody could
            // see it (Delete on the piece screen, 0.23.4).
            .onChange(of: confirming) { _, id in
                guard let id else { return }
                withAnimation { strip.scrollTo(id, anchor: .trailing) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("row-actions")
    }

    private func capsule(_ item: RowActionItem) -> some View {
        Button {
            if item.confirm != nil { confirming = item.id } else { item.action() }
        } label: {
            HStack(spacing: Theme.Metric.s4) {
                if let glyph = item.glyph {
                    Image(systemName: glyph).font(.system(size: 11, weight: .semibold))
                }
                Text(item.title).typeRole(.control).lineLimit(1)
                if let count = item.count {
                    Text("\(count)").typeRole(.dataS).foregroundStyle(Theme.Ink.ink3)
                }
            }
            .foregroundStyle(item.destructive ? Theme.Status.danger
                             : (item.lit ? Theme.Accent.clayStrong : Theme.Ink.ink))
            .padding(.horizontal, Theme.Metric.s12)
            .frame(height: 36)
            .background(item.lit ? Theme.Accent.clayTint : Theme.Surface.paper)
            .overlay {
                if item.lit { Capsule().strokeBorder(Theme.Accent.clay, lineWidth: 1.5) }
            }
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!item.enabled)
        .opacity(item.enabled ? 1 : 0.45)
        .accessibilityIdentifier(item.id)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(item.lit ? [.isSelected] : [])
    }

    private func confirmInPlace(_ item: RowActionItem, question: String) -> some View {
        HStack(spacing: Theme.Metric.s6) {
            Text(question).typeRole(.control).foregroundStyle(Theme.Ink.ink).lineLimit(1)
            Button { confirming = nil; item.action() } label: {
                Text(item.title).typeRole(.control).foregroundStyle(Theme.Surface.paper)
                    .padding(.horizontal, Theme.Metric.s12).frame(height: 32)
                    .background(Theme.Status.danger).clipShape(Capsule()).contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("\(item.id)-confirm")
            Button { confirming = nil } label: {
                Text("Keep").typeRole(.control).foregroundStyle(Theme.Ink.ink)
                    .padding(.horizontal, Theme.Metric.s12).frame(height: 32)
                    .background(Theme.Surface.paper).clipShape(Capsule()).contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("\(item.id)-keep")
        }
        .padding(.leading, Theme.Metric.s8)
        .padding(.trailing, 2)
        .frame(height: 36)
        .background(Theme.Accent.clayTint)
        .clipShape(Capsule())
    }
}

/// A row that taps like a button and still holds live controls.
///
/// A `Button` folds its whole label into one accessibility element and owns
/// every tap inside it, so action capsules drawn in a row's meta slot could
/// be neither reached nor pressed. This makes the row a tap gesture with a
/// button's traits instead: a tap anywhere else on the row is the row's
/// action, the capsules keep their own taps, and while they are shown the
/// row is a container so each is an element (§7.3). A long press, when
/// given, enters Edit with the row checked [C11] and swallows the tap that
/// would otherwise follow it.
struct RowTappable: ViewModifier {
    let label: String
    let identifier: String
    var isSelected = false
    var container = false
    let action: () -> Void
    var onLongPress: (() -> Void)?
    @State private var longPressed = false

    func body(content: Content) -> some View {
        let tapped = content
            .contentShape(Rectangle())
            .onTapGesture {
                if longPressed { longPressed = false; return }
                action()
            }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                    guard let onLongPress else { return }
                    longPressed = true
                    onLongPress()
                },
                including: onLongPress == nil ? .subviews : .all)
        if container {
            // Still a button to the tree (the tests and VoiceOver address
            // the row as one), and a container so the capsules are its own
            // children.
            tapped
                .accessibilityElement(children: .contain)
                .accessibilityLabel(label)
                .accessibilityIdentifier(identifier)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
        } else {
            tapped
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityIdentifier(identifier)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
                .accessibilityAction { action() }
        }
    }
}

extension View {
    func rowTappable(label: String, identifier: String, isSelected: Bool = false,
                     container: Bool = false, action: @escaping () -> Void,
                     onLongPress: (() -> Void)? = nil) -> some View {
        modifier(RowTappable(label: label, identifier: identifier, isSelected: isSelected,
                             container: container, action: action, onLongPress: onLongPress))
    }
}
