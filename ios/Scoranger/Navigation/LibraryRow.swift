import SwiftUI

// The bottom tab bar is gone (§4C). It held Home, My Library and a disabled
// Shared placeholder -- one live tab and a stub, which is not a tab bar. The
// app opens on My Library, and the Pieces/Setlists segmented control is the
// only place-switcher. If sharing lands it returns as a third SEGMENT.

/// A search field (12.3). Paper fill so it reads as something to type into,
/// against the ground the rest of the screen sits on.
struct SearchField: View {
    let placeholder: String
    @Binding var text: String
    var identifier: String

    var body: some View {
        HStack(spacing: Theme.Metric.s8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Ink.ink3)
            TextField(placeholder, text: $text)
                .typeRole(.body)
                .foregroundStyle(Theme.Ink.ink)
                .tint(Theme.Accent.clay)
                .accessibilityIdentifier(identifier)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.Ink.ink3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Theme.Metric.s12)
        .padding(.vertical, 10)
        .background(Theme.Surface.paper)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.rCtl))
    }
}

/// One library row (12.4): thumbnail, title, subtitle, derived chips, and
/// the trailing meta in mono.
struct LRow: View {
    let row: LibraryRow
    var identifier: String
    var action: () -> Void
    /// The one control a row carries (§4): row tap opens the music, ☰ manages.
    var onMenu: (() -> Void)?
    /// Share this row, when it is shareable. §6A.2 puts it immediately
    /// LEADING of the `☰` and NOT inside the `☰` screen: a control in two
    /// places is what `optionsCarriesTransportToggle` exists to prevent.
    var onShare: (() -> Void)?
    /// Whether this row is already shared -- the button says so rather than
    /// offering to share again as if nothing had happened.
    var isShared: Bool = false
    /// Bring a shared set list into step with its members now (0.18.0). Nil
    /// on every row that is not a shared set list.
    var onSync: (() -> Void)?
    /// How that row stands, drawn on the Sync button.
    var syncStatus: SetlistSync.Status = .unknown
    /// Checked in Edit mode: a flat tint band [C4].
    var isSelected: Bool = false
    var menuIsOpen: Bool = false
    /// The row's own actions while its ☰ is open (§7.3): they take the meta
    /// line's slot, so the row's name does not move [C4].
    var actions: [RowActionItem] = []
    /// A long press enters Edit with this row checked [C11].
    var onLongPress: (() -> Void)?

    private var rowLabel: String {
        [row.title, row.subtitle, row.meta].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: Theme.Metric.s12) {
                PageThumb()
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.title).typeRole(.titleS).foregroundStyle(Theme.Ink.ink)
                        .lineLimit(1)
                    if !actions.isEmpty {
                        RowActionsBar(actions: actions)
                    } else {
                        if !row.subtitle.isEmpty {
                            Text(row.subtitle).typeRole(.meta).foregroundStyle(Theme.Ink.ink3)
                                .lineLimit(1)
                        }
                        if !row.chips.isEmpty {
                            HStack(spacing: Theme.Metric.s4) {
                                ForEach(Array(row.chips.enumerated()), id: \.offset) { _, chip in
                                    DerivedChip(chip: chip)
                                }
                            }
                        }
                    }
                }
                Spacer(minLength: Theme.Metric.s8)
                if !row.meta.isEmpty {
                    // Two mono lines at the right [C10]: the version and when
                    // it changed in ink2, over when it was added in ink3.
                    // Never wrapped, never squeezed by the title beside it.
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(row.meta).typeRole(.data).foregroundStyle(Theme.Ink.ink2)
                        if !row.added.isEmpty {
                            Text("added \(row.added)").typeRole(.dataS).foregroundStyle(Theme.Ink.ink3)
                        }
                    }
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                }
                // No chevron when there is a ☰. The row itself is still a
                // button; that is what its tap is for.
                if onMenu == nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.Ink.ink3)
                }
            }
            .padding(.leading, Theme.Metric.s20)
            // a row with a ☰ keeps its content clear of it; the overlay sits
            // outside the layout, so nothing else would
            .padding(.trailing, onMenu == nil
                     ? Theme.Metric.s20
                     : (onShare == nil ? Theme.Metric.rowMenuInset
                        : onSync == nil ? Theme.Metric.rowTwoControlInset
                                        : Theme.Metric.rowThreeControlInset))
            .padding(.vertical, Theme.Metric.s8)
            .frame(minHeight: 64)
            .background(isSelected ? Theme.Accent.clayTint : Color.clear)
            .rowTappable(label: rowLabel, identifier: identifier, isSelected: isSelected,
                         container: !actions.isEmpty, action: action, onLongPress: onLongPress)
        .overlay(alignment: .trailing) {
            HStack(spacing: 0) {
                if let onSync {
                    RowSyncButton(identifier: "row-sync-\(row.id)",
                                  title: row.title, status: syncStatus,
                                  action: onSync)
                }
                if let onShare {
                    RowShareButton(identifier: "row-share-\(row.id)",
                                   title: row.title,
                                   isShared: isShared,
                                   action: onShare)
                }
                if let onMenu {
                    RowMenuButton(identifier: "row-menu-\(row.id)",
                                  label: menuIsOpen ? "Close \(row.title)'s actions"
                                                    : "Manage \(row.title)",
                                  isOpen: menuIsOpen, action: onMenu)
                }
            }
            .padding(.trailing, Theme.Metric.s8)
        }
    }
}

/// A page-shaped placeholder. Real page-1 rasters need the thumbnail cache
/// (§7); until then this says "a score" without pretending to be one.
struct PageThumb: View {
    var width: CGFloat = 44
    var height: CGFloat = 57

    var body: some View {
        VStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { _ in
                Rectangle().fill(Theme.Line.line).frame(height: 1.5)
            }
        }
        .padding(.horizontal, 5)
        .frame(width: width, height: height, alignment: .top)
        .padding(.top, 8)
        .background(Theme.Surface.paper)
    }
}

/// A derived chip (12.5). Never a stored tag -- everything it can say is
/// computed from the manifest.
struct DerivedChip: View {
    let chip: LibraryRow.Chip

    var body: some View {
        Text(chip.text)
            .fixedSize()
            .typeRole(chip.kind == .count ? .data : .meta)
            .foregroundStyle(foreground)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(background)
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Metric.rCtl)
                    .stroke(border, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.rCtl))
    }

    private var foreground: Color {
        switch chip.kind {
        case .count:   return Theme.Accent.clayStrong
        case .warning: return Color(hex: 0x8A5A12)
        case .plain:   return Theme.Ink.ink2
        }
    }
    private var background: Color {
        switch chip.kind {
        case .count:   return Theme.Accent.clayTint
        case .warning: return Color(hex: 0xFBF2E6)
        case .plain:   return Theme.Surface.band
        }
    }
    private var border: Color {
        switch chip.kind {
        case .count:   return Theme.Accent.clayBorder
        case .warning: return Color(hex: 0xE8CFA6)
        case .plain:   return Theme.Line.line2
        }
    }
}

/// The share control on a set list row.
///
/// design/FIREBASE.md §6A.2: a 34pt bordered square inside a 44pt hit target,
/// immediately leading of the `☰`. The visible square is smaller than the
/// touchable one on purpose -- 44 is the smallest thing a finger reliably
/// hits, and 34 is what does not crowd the row next to another control.
///
/// It is the SAME control whether or not the set list is already shared, and
/// only its symbol changes. A second, differently-named control for
/// "share again" would be the same affordance in two places.
struct RowShareButton: View {
    let identifier: String
    let title: String
    var isShared: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isShared
                  ? "person.2.fill"          // already shared: who is in it
                  : "square.and.arrow.up")   // not yet: the iOS share glyph
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.Accent.clayStrong)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.clear, lineWidth: 0)
                )
                .frame(width: Theme.Metric.hitTarget,
                       height: Theme.Metric.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // One element, so the identifier lands on the tappable thing rather
        // than on a container -- the selection chip's lesson (Screen.swift).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isShared ? "Sharing for \(title)" : "Share \(title)")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(identifier)
    }
}

/// A shared set list's Sync button, leading of its share button (0.18.0).
///
/// The symbol IS the state -- in step, syncing, or a sync that failed -- so a
/// reader can see whether the list matches the band's without opening it,
/// and tapping it pulls and pushes now. Ali, of Echo: "there should be a
/// manual sync button so that Echo can pull it if he knows there should be
/// in there."
struct RowSyncButton: View {
    let identifier: String
    let title: String
    let status: SetlistSync.Status
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: status.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isTrouble ? Theme.Accent.clayStrong : Theme.Ink.ink3)
                .symbolEffect(.pulse, isActive: status == .syncing)
                .frame(width: Theme.Metric.hitTarget, height: Theme.Metric.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(status == .syncing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.label(for: title))
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(identifier)
    }

    private var isTrouble: Bool {
        if case .trouble = status { return true }
        return false
    }

    /// For the UI test, which waits on the state rather than on a symbol.
    private var accessibilityValue: String {
        switch status {
        case .inStep:   return "in step"
        case .syncing:  return "syncing"
        case .trouble:  return "trouble"
        case .unknown:  return "not synced"
        }
    }
}
