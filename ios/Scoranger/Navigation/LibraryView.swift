import SwiftUI

/// My Library -- the app (NAVIGATION_SYSTEM.md §4.2-4.3, §4C).
///
/// Home is gone and this is what the app opens on. It took Home's actions as a
/// compact row under the search field rather than four large panels, and lost
/// the `+` FAB, which offered exactly what that row shows permanently.
///
/// Its top row is the gear alone. Help, the inbox and the engine chip came
/// across from Home and went again at Ali's word (#48-#50): two of them did
/// nothing when tapped, and the third restates a settled question on the screen
/// he reads music from.
///
/// Segmented Pieces/Setlists, search, the action row, the A-Z rail. The rail is
/// shown only under name sort -- under any other order the letters would not
/// agree with the rows, so it hides rather than lies.
struct LibraryView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var setlistSync: SharedSetlistSync
    @Binding var segment: LibrarySegment
    @Binding var search: String
    @Binding var sort: LibrarySort
    @Binding var filters: Set<LibraryFilter>
    @Binding var editing: Bool
    /// A new piece or set list being named in place; owned by the root so the
    /// New panel can start it.
    @Binding var creatingName: String?
    var onOpenPiece: (String) -> Void
    var onOpenArrangement: (String) -> Void
    var onOpenSetlist: (SetlistDoc) -> Void
    /// A shared set list, by its Firestore id. Defaulted so every existing
    /// construction of this view still compiles.
    var onOpenSharedSetlist: (String) -> Void = { _ in }
    /// Share the set list with this slug: promote it if it is not shared yet,
    /// then hand over the link. Defaulted for the same reason.
    var onShareSetlist: (String) -> Void = { _ in }
    /// A book opens its own screen: you do not read a book here, you take
    /// arrangements out of it.
    var onOpenBook: (String) -> Void = { _ in }
    /// The row's ☰. Pushes to the item's screen, or expands in place, by the
    /// rule in RowMenuBehaviour.
    /// The full piece screen and set list screen, from a row's actions.
    var onOpenPieceScreen: (String) -> Void = { _ in }
    var onOpenSetlistScreen: (String) -> Void = { _ in }
    var onCreate: (String) -> Void
    var onImport: () -> Void
    /// A whole exported library: one folder per piece. Planned before it is run.
    var onImportPhotos: () -> Void = {}
    var onImportFolder: () -> Void = {}
    /// A collection to take arrangements out of, rather than a piece.
    var onImportBook: () -> Void = {}
    var onSettings: () -> Void
    var onRowAction: (LibraryRow, RowAction) -> Void
    /// The selection in the LIST'S order, so a set list made from it keeps
    /// the order the reader saw.
    var onBarAction: (LibraryAction, [String], LibrarySelectionKind) -> Void
    /// The root asks the list to open a rename on this row -- the set list it
    /// just made from a selection, whose proposed name arrives selected
    /// (REDESIGN_BRIEF_0.8 §7.4 rule 4). Cleared once honoured.
    @Binding var renameRequest: String?

    /// Slugs of set lists that have already been promoted.
    ///
    /// From the MANIFEST, not from Firestore: `shareId` is a field on the
    /// local document (§6A.1), so a row knows it is shared without a network
    /// round trip and without being signed in.
    private var sharedSetlistIds: Set<String> {
        Set((state.manifest?.setlists ?? [])
            .filter(\.isShared).map(\.slug))
    }

    /// A shared set list row's Sync button, and nothing on any other row.
    private func syncAction(_ row: LibraryRow) -> (() -> Void)? {
        guard segment == .setlists, !editing,
              let setlist = state.manifest?.setlists?.first(where: { $0.slug == row.id }),
              let shareId = setlist.shareId else { return nil }
        return { setlistSync.syncNow(shareId) }
    }

    private func syncStatus(_ row: LibraryRow) -> SetlistSync.Status {
        guard let setlist = state.manifest?.setlists?.first(where: { $0.slug == row.id })
        else { return .unknown }
        return setlistSync.rowStatus(setlist)
    }

    /// The panel beside the page (§7.2): Sort, Filter, Import and New open
    /// there, and a row's actions open there too.
    @EnvironmentObject var panel: PanelModel
    /// The row whose ☰ is open, its actions in the row (§7.3) [C4].
    @State private var openRow: String?
    /// A set list being renamed in place (L8).
    @State private var renaming: String?
    @State private var renameDraft = ""
    /// The rename row's text arrives selected whole (a proposed name).
    @State private var renameSelectAll = false
    /// The name being typed for a NEW piece or set list. Kept apart from
    /// `creatingName`, which is only the flag that the row is up: with the
    /// TextField bound straight to the flag, Cancel set it nil and the field's
    /// own write-back on losing focus set it "" again -- an empty naming row
    /// that followed the reader from Set lists to Pieces (build 194's
    /// photographs caught it). The rename row has always worked this way.
    @State private var creatingDraft = ""
    /// The two verb bands (§14.3). Mutually exclusive with Sort and Filter,
    /// which is what makes them the pattern this row already had rather than
    /// a new one.
    @Environment(\.dynamicTypeSize) private var typeSize

    /// How tall the row's own slot is. It holds one line normally, two when
    /// the layout has run out of labels to give up, and as many as there are
    /// controls at an accessibility size -- so it is asked rather than fixed.
    private var rowHeight: CGFloat {
        let labels = LibraryBarMetrics.labels(sort: sort, filters: filters.count,
                                              editing: editing, size: typeSize)
        let fit = LibraryBarLayout.fit(width: measuredRowWidth, labels: labels,
                                       accessibilitySize: typeSize.isAccessibilitySize)
        let line = max(LibraryActionRow.height, labels.iconButton + 12)
        if fit.list { return line * 5 + LibraryActionRow.gap * 4 }
        if fit.wraps { return line * 2 + LibraryActionRow.gap }
        return line
    }

    /// The width the row was last given, measured by the row itself.
    @State private var measuredRowWidth: CGFloat = 0
    @State private var scrollTo: String?
    @State private var selected: Set<String> = []

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                topRow
                    .padding(.horizontal, Theme.Metric.s20)
                    .padding(.top, Theme.Metric.s12)
                segmented
                    .padding(.top, Theme.Metric.s12)
                header
                controlBar
                Theme.Rule()
                list
            }
            .background(Theme.Surface.panel)
        }
        .overlay(alignment: .bottom) {
            if editing && !selected.isEmpty { actionBar }
        }
        .onChange(of: editing) { _, on in if !on { selected = [] } }
        .onChange(of: segment) { _, _ in selected = []; openRow = nil; panel.done() }
        .onChange(of: renameRequest) { _, _ in honourRenameRequest() }
        .onChange(of: rows.map(\.id)) { _, _ in honourRenameRequest() }
    }

    /// The action bar (§2.2): what you can do to what is highlighted.
    ///
    /// The verbs are scoped by KIND, because they are not interchangeable -- a
    /// piece is a folder and cannot be duplicated or put in a set list. Actions
    /// needing exactly one row grey to 42% rather than vanishing, so the bar
    /// never re-flows under a finger.
    ///
    /// The COUNT is passed too, and the pieces bar is the only one that reads
    /// it: New arrangement and Combine cannot both apply, so it shows the one
    /// this selection can use rather than a fourth capsule that would push a
    /// phone's bar onto two rows.
    private var actionBar: some View {
        let kind = selectionKind
        let actions = LibraryActions.bar(for: kind, count: selected.count)
        return GeometryReader { geo in
            let labels = LibraryActionBarMetrics.labels(count: selected.count, kind: kind, size: typeSize)
            let rung = LibraryActionBarLayout.rung(width: geo.size.width, actions: actions, labels: labels)
            Group {
                if rung == .twoRows {
                    // Constructive above destructive: §6.3 rule 4 arriving one
                    // control early.
                    VStack(alignment: .trailing, spacing: Theme.Metric.s8) {
                        HStack(spacing: Theme.Metric.s8) {
                            Spacer(minLength: 0)
                            ForEach(actions.filter { !$0.isDestructive }, id: \.self) { barButton($0, kind: kind, rung: rung) }
                        }
                        HStack(spacing: Theme.Metric.s8) {
                            Spacer(minLength: 0)
                            ForEach(actions.filter(\.isDestructive), id: \.self) { barButton($0, kind: kind, rung: rung) }
                        }
                    }
                } else {
                    HStack(spacing: Theme.Metric.s8) {
                        if rung.showsReadout {
                            Text("\(selected.count) selected").typeRole(.data)
                                .foregroundStyle(Theme.Ink.ink2)
                                .accessibilityIdentifier("library-actionbar-count")
                        }
                        Spacer(minLength: Theme.Metric.s8)
                        ForEach(actions, id: \.self) { barButton($0, kind: kind, rung: rung) }
                    }
                }
            }
            .padding(.horizontal, Theme.Metric.s16)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // The bar yields by measurement, in a stated order, until it fits
        // (LibraryActionBarLayout); at accessibility sizes it is two rows.
        .frame(height: typeSize.isAccessibilitySize ? 112 : 56)
        .background(Theme.Surface.panel)
        .overlay(alignment: .top) { Theme.Rule() }
        .shadow(color: Color(hex: 0x1A1917).opacity(0.07), radius: 18, y: -6)
        // A container, or its identifier lands on every capsule in it and
        // `bar-new-setlist` cannot be addressed (the header lesson of 0.8).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library-actionbar")
    }

    private func barButton(_ action: LibraryAction, kind: LibrarySelectionKind,
                           rung: LibraryActionBarLayout.Rung) -> some View {
        let on = LibraryActions.isEnabled(action, count: selected.count)
        let label: String = action == .delete
            ? action.deleteTitle(count: selected.count, kind: kind, counted: rung.deleteIsCounted)
            : (rung.usesShortLabels ? action.shortTitle(count: selected.count, kind: kind)
                                    : action.title(count: selected.count, kind: kind))
        return Button {
            onBarAction(action, rows.map(\.id).filter(selected.contains), kind)
            if action == .delete { selected = [] }
        } label: {
            Text(label)
                .typeRole(.control)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(action.isDestructive ? Theme.Surface.paper : Theme.Ink.ink)
                .padding(.horizontal, Theme.Metric.s12)
                .padding(.vertical, Theme.Metric.s6)
                .background(action.isDestructive ? Theme.Status.danger : Theme.Surface.panel)
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Metric.rCtl)
                        .stroke(action.isDestructive ? Theme.Status.danger : Color.clear, lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.rCtl))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!on)
        .opacity(on ? 1 : 0.42)
        // The visible label may be a noun; VoiceOver gets the sentence.
        .accessibilityLabel(action.accessibilityTitle(count: selected.count, kind: kind))
        .accessibilityIdentifier(action.identifier)
    }

    private var selectionKind: LibrarySelectionKind {
        LibraryActions.kind(of: selected,
                            pieces: Set((state.manifest?.pieces ?? []).map(\.slug)),
                            setlists: Set((state.manifest?.setlists ?? []).map(\.slug)))
    }

    // MARK: - Chrome

    private var segmented: some View {
        HStack(spacing: 0) {
            ForEach(LibrarySegment.allCases, id: \.self) { option in
                Button { segment = option } label: {
                    Text(option.title)
                        .typeRole(.row)
                        .foregroundStyle(segment == option ? Theme.Accent.clayStrong
                                                           : Theme.Ink.ink2)
                        .padding(.horizontal, Theme.Metric.s20)
                        .padding(.vertical, Theme.Metric.s6)
                        .background(segment == option ? Theme.Accent.clayTint : Color.clear)
                        .overlay {
                            if segment == option {
                                RoundedRectangle(cornerRadius: Theme.Metric.rCtl)
                                    .stroke(Theme.Accent.clay, lineWidth: 1)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.rCtl))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("segment-\(option.rawValue)")
                .accessibilityAddTraits(segment == option ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(Theme.Surface.well)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.rPanel))
    }

    /// The library's top row: the gear at the trailing edge, and nothing else
    /// (#48-#50, and item 14 of 2026-09-14).
    ///
    /// Help and the inbox were drawn and inert -- a "?" that opened nothing and
    /// a tray whose count was the only true thing about it. The engine chip
    /// went with them at Ali's word: which engine is running is a settled
    /// question he does not want restated on the screen he reads music from,
    /// and Settings still says it (and says it properly, with the mode and the
    /// reachability separated).
    private var topRow: some View {
        HStack(spacing: Theme.Metric.s8) {
            Spacer()
            // TOP RIGHT, and bigger (item 14). The trailing edge is where a
            // settings control sits in every other app, and it is the corner
            // the reading hand is nearest on an iPad held in one hand.
            PanelIconButton(systemName: "gearshape", label: "Settings",
                            size: 40, glyphSize: 18,
                            action: onSettings)
                .accessibilityIdentifier("library-settings")
        }
        // Centred on the ROW rather than placed in it, so the gear's width
        // does not push it off centre -- and as an overlay it cannot make the
        // row taller either.
        .overlay { BuildStampLine() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Metric.s8) {
            Text("Library").typeRole(.title).foregroundStyle(Theme.Ink.ink)
            // a phrase, not a bare number: "My library 1" names nothing, and
            // "My library 0" is a count where a new reader needs a sentence
            Text(LibraryModel.countPhrase(segment: segment, rows: rows))
                .typeRole(.data).foregroundStyle(Theme.Ink.ink3)
                .accessibilityIdentifier("library-count")
            Spacer()
        }
        .padding(.horizontal, Theme.Metric.s20)
        .padding(.top, Theme.Metric.s12)
    }

    /// Search, then the action row: the library's own actions on the left, the
    /// list's controls on the right (§4C). One bar, two clusters -- what you
    /// can MAKE, and how you are LOOKING at what you have.
    private var controlBar: some View {
        VStack(spacing: LibraryActionRow.spaceAboveRow) {
            SearchField(placeholder: "Search \(segment.title.lowercased())…",
                        text: $search, identifier: "library-search")
            GeometryReader { geo in
                // What the row can DRAW, measured at the text size in force.
                // It used to strip five labels below 700pt and then draw
                // whatever was left, however wide -- so a phone got five
                // unlabelled squares AND an overflow off both edges (§14).
                let labels = LibraryBarMetrics.labels(
                    sort: sort, filters: filters.count, editing: editing,
                    size: typeSize)
                let fit = LibraryBarLayout.fit(
                    width: geo.size.width, labels: labels,
                    accessibilitySize: typeSize.isAccessibilitySize)
                actionRow(fit, labels: labels)
                    .frame(width: geo.size.width, alignment: .leading)
                    .onAppear { measuredRowWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, new in
                        measuredRowWidth = new
                    }
            }
            .frame(height: rowHeight)

        }
        .padding(.horizontal, LibraryActionRow.sidePadding)
        .padding(.top, Theme.Metric.s12)
        .padding(.bottom, LibraryActionRow.spaceBelowRow)
    }

    /// The row, in whatever shape it fits.
    ///
    /// Five of the seven controls were two verbs (§14.2): three flavours of
    /// Import and two of New, drawn at compact width as five unlabelled
    /// squares -- two of whose glyphs, a plain square and three lines, name
    /// nothing at all. They collapse into `Import ▾` and `New ▾`, each opening
    /// a band beneath the row that lists its variants in words. That is the
    /// pattern Sort and Filter already use IN THIS ROW, so it costs no new
    /// concept, no scroll, no menu and no permanent second row.
    @ViewBuilder
    private func actionRow(_ fit: LibraryBarLayout.Fit,
                           labels: LibraryBarLayout.Labels) -> some View {
        let controls = [LibraryVerb.importing, .creating]
        if fit.list {
            // §6.3 rule 4: at an accessibility size a row of more than three
            // controls is a vertical list.
            VStack(alignment: .leading, spacing: LibraryActionRow.gap) {
                ForEach(controls) { verb in verbButton(verb, labelled: true, labels: labels) }
                sortButton(fit, labels: labels)
                filterButton(fit, labels: labels)
                editButton(fit, labels: labels)
            }
        } else if fit.wraps {
            // The FLOOR, not the fix: every label has yielded and it still
            // does not fit.
            VStack(alignment: .leading, spacing: LibraryActionRow.gap) {
                HStack(spacing: LibraryActionRow.gap) {
                    ForEach(controls) { verb in verbButton(verb, labelled: false, labels: labels) }
                    Spacer(minLength: 0)
                }
                HStack(spacing: LibraryActionRow.gap) {
                    sortButton(fit, labels: labels)
                    filterButton(fit, labels: labels)
                    editButton(fit, labels: labels)
                    Spacer(minLength: 0)
                }
            }
        } else {
            HStack(spacing: LibraryActionRow.gap) {
                verbButton(.importing, labelled: fit.importLabelled, labels: labels)
                verbButton(.creating, labelled: fit.newLabelled, labels: labels)
                Spacer(minLength: LibraryActionRow.clusterGap)
                sortButton(fit, labels: labels)
                filterButton(fit, labels: labels)
                editButton(fit, labels: labels)
            }
        }
    }

    /// `+ New` makes the thing the segment is SHOWING (item 13).
    ///
    /// It used to open a band asking which kind, and Ali struck that band out
    /// twice -- once from Pieces ("this should just create a new piece") and
    /// once from Set lists. The segmented control above the row already says
    /// which kind he is looking at, so asking again is a second answer to a
    /// question already answered on screen.
    ///
    /// Books have no New. A book is a PDF somebody already owns; it arrives
    /// through Import's Book row, which sits in the same cluster two controls
    /// to the left. A `+ New` on that segment could only be an import wearing
    /// the wrong verb, or a button that does nothing.
    @ViewBuilder
    private func verbButton(_ verb: LibraryVerb, labelled: Bool,
                            labels: LibraryBarLayout.Labels) -> some View {
        if verb == .creating && segment == .books {
            EmptyView()
        } else {
            Button {
                switch verb {
                case .importing: toggle(.importing)
                case .creating:  startCreating()
                }
            } label: {
                rowButton(verb.title, glyph: verb.glyph, iconOnly: !labelled,
                          active: verb == .importing
                              ? panel.isShowing(.importMenu)
                              : creatingName != nil,
                          icon: labels.iconButton)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(verb.identifier)
            .accessibilityLabel(verb == .creating ? newLabel : verb.title)
        }
    }

    /// What `+ New` makes, said in full for VoiceOver: the visible label is
    /// one word and the segment supplies the noun.
    private var newLabel: String {
        switch segment {
        case .pieces:   return "New piece"
        case .setlists: return "New set list"
        case .books:    return "New"
        }
    }

    /// Raise the naming row, and put it where it can be seen.
    ///
    /// Item 12. The row was never dead: it is the FIRST child of the list's
    /// LazyVStack, and Ali was scrolled into the P section of 41 pieces, so it
    /// appeared several screens above the viewport. A LazyVStack does not even
    /// build a child that far off screen, so its `onAppear` never ran and
    /// there was no keyboard to notice either.
    private func startCreating() {
        if creatingName != nil {
            creatingName = nil
            creatingDraft = ""
        } else {
            panel.done()
            creatingName = ""
            creatingDraft = ""
        }
    }

    private func sortButton(_ fit: LibraryBarLayout.Fit,
                            labels: LibraryBarLayout.Labels) -> some View {
        Button { panel.toggle(.sort) } label: {
            rowButton(sortTitle(fit.sort), glyph: "arrow.up.arrow.down",
                      iconOnly: false, active: panel.isShowing(.sort), icon: labels.iconButton)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library-sort")
    }

    private func sortTitle(_ style: LibraryBarLayout.SortStyle) -> String {
        switch style {
        case .full:  return "Sort \(sort.buttonLabel)"
        case .short: return "Sort \(sort.shortButtonLabel)"
        case .bare:  return "Sort"
        }
    }

    private func filterButton(_ fit: LibraryBarLayout.Fit,
                              labels: LibraryBarLayout.Labels) -> some View {
        Button { panel.toggle(.filter) } label: {
            rowButton(filters.isEmpty ? "Filter" : "Filter · \(filters.count)",
                      glyph: "line.3.horizontal.decrease",
                      iconOnly: !fit.filterLabelled, active: panel.isShowing(.filter), icon: labels.iconButton)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library-filter")
    }

    private func editButton(_ fit: LibraryBarLayout.Fit,
                            labels: LibraryBarLayout.Labels) -> some View {
        Button { editing.toggle() } label: {
            rowButton(editing ? "Done" : "Edit", glyph: "checkmark.circle",
                      iconOnly: !fit.editLabelled, active: editing,
                      icon: labels.iconButton)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library-edit")
    }

    /// Import opens its band (§7.6); Sort and Filter open theirs the same way.
    /// One panel state at a time, and no floating menus. New is not here: it
    /// creates rather than offering (item 13).
    private func toggle(_ band: Band) {
        switch band {
        case .importing: panel.toggle(.importMenu)
        case .sort:      panel.toggle(.sort)
        case .filter:    panel.toggle(.filter)
        }
    }

    private enum Band { case importing, sort, filter }

    private func rowButton(_ text: String, glyph: String,
                           iconOnly: Bool, active: Bool = false,
                           icon: CGFloat = LibraryActionRow.buttonHeight) -> some View {
        HStack(spacing: Theme.Metric.s6) {
            Image(systemName: glyph).font(.system(size: 13, weight: .medium))
            if !iconOnly {
                // one line, at its natural width: "Sort: recently changed" is
                // the longest label here and it wrapped inside a 32pt button
                Text(text).font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .foregroundStyle(active ? Theme.Accent.clayStrong : Theme.Ink.ink2)
        .padding(.horizontal, iconOnly ? 0 : LibraryActionRow.buttonPadding)
        // The icon square is SCALED (`LibraryBarMetrics.iconButton`): a flat
        // 32 clips the glyph inside it at an accessibility size, and told the
        // row's arithmetic the button never changes width while its content
        // did (§6.3 rule 2).
        .frame(width: iconOnly ? icon : nil)
        .frame(minHeight: icon)
        .background(active ? Theme.Accent.clayTint : Theme.Surface.panel)
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Metric.rCtl)
                .stroke(active ? Theme.Accent.clay : Color.clear, lineWidth: 1.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.rCtl))
        .contentShape(Rectangle())
    }

    private func controlLabel(_ text: String, active: Bool = false) -> some View {
        Text(text)
            .typeRole(.meta)
            .foregroundStyle(active ? Theme.Accent.clayStrong : Theme.Ink.ink2)
            .padding(.horizontal, Theme.Metric.s8)
            .padding(.vertical, 4)
            .background(active ? Theme.Accent.clayTint : Theme.Surface.panel)
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Metric.rCtl)
                    .stroke(active ? Theme.Accent.clay : Color.clear, lineWidth: 1.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.rCtl))
    }

    private var list: some View {
        // A reader. Item 12: raising the naming row is not enough if the row
        // is three screens above the viewport, which is where it is for
        // anybody scrolled past the letter A.
        ScrollViewReader { proxy in
        ScrollView {
            // The content column is CAPPED AND CENTRED, the same rule `Screen`
            // applies to every pushed screen (L34, and A-B of
            // design/IPHONE_0.6.14.md). Full-bleed rows put a title and its own
            // chevron 1200pt apart on a landscape phone and 1300 on a 13-inch
            // iPad, and at that distance a row stops reading as one thing.
            //
            // The library was the one list that never got it, and the test that
            // caught that -- LandscapeFits.testTheLibraryFitsInLandscape --
            // arrived with the landscape work asserting behaviour nobody had
            // written: it fails on dev too, not only here.
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                // Naming a new thing happens here, in place: the list moves
                // down, nothing dims, and there is nothing to dismiss.
                if creatingName != nil {
                    InlineRenameRow(text: $creatingDraft,
                                    placeholder: segment == .setlists ? "Set list name" : "Piece name",
                                    containerIdentifier: "inline-create-row",
                                    leading: Theme.Metric.s20 + (editing ? Theme.Metric.checkboxGutter : 0),
                                    onSave: {
                                        let name = creatingDraft
                                            .trimmingCharacters(in: .whitespacesAndNewlines)
                                        creatingName = nil
                                        creatingDraft = ""
                                        if !name.isEmpty { onCreate(name) }
                                    },
                                    onCancel: { creatingName = nil; creatingDraft = "" })
                    .onAppear { creatingDraft = creatingName ?? "" }
                    .id(Self.creatingAnchor)
                    Theme.Rule()
                }

                // Imports in flight, at the top where they cannot be missed.
                //
                // They used to render only in the score screen's library
                // overlay, which the redesign retired -- so an import showed a
                // badge on a Home icon that was not tappable and then could
                // not be found at all (0.4.1 item 9).
                // ...and each in the list it is making something FOR: a book
                // being read is not an arrangement arriving (ImportProgress).
                ForEach(pendingHere) { pending in importingRow(pending) }
                // Loading is not emptiness (#42): the manifest is nil until the
                // engine answers, and claiming "No music yet" in that window
                // flashed the empty state on every launch of a full library.
                // No shared-set-list band. §6A.1: there is ONE kind of set
                // list and sharing is a field on it, so a shared set list is
                // an ordinary row in this list -- it does not move, and it is
                // not listed twice.
                switch LibraryModel.listState(loaded: state.libraryLoaded,
                                              rows: rows.count,
                                              pendingImports: pendingHere.count,
                                              isFiltered: !search.isEmpty || !filters.isEmpty) {
                case .rows:      grouped
                case .loading:   loading
                case .empty, .noMatches: empty
                }
            }
            // FULL WIDTH. The reading-column cap was a deliberate design and
            // Ali reversed it on 2026-09-10 with a screenshot: two thirds of an
            // iPad landscape screen empty either side of the list, every row's
            // subtitle truncated at "..." in the middle. The list is a list,
            // not a page of prose; it gets the width it is given.
            .frame(maxWidth: .infinity)
            .padding(.bottom, 90)
            // The build stamp used to end this scroll view. It is in the top
            // row now: a tester should not have to scroll past their whole
            // library to say which build they are on (#53).
        }
        // The row is put on screen the instant it exists. Deferred by one
        // runloop turn because the row is not in the scroll view's content
        // until this state change has been laid out, and `scrollTo` on an id
        // that is not there yet does nothing at all.
        .onChange(of: creatingName == nil) { _, gone in
            guard !gone else { return }
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(Self.creatingAnchor, anchor: .top)
                }
            }
        }
        }
    }

    /// What the list scrolls to when a new thing is being named.
    private static let creatingAnchor = "inline-create-row-anchor"

    @ViewBuilder
    private var grouped: some View {
        // Letter headers only under name sort: under any other order they
        // would disagree with the rows. The rail that used to sit beside them
        // is gone (0.4.1 §5) -- search covers "jump to L", and the trailing
        // edge goes back to the chevrons.
        if sort.showsAlphabetRail {
            ForEach(LibraryModel.grouped(rows), id: \.letter) { group in
                Section {
                    // Identified by the slug AND the title.
                    //
                    // By the slug alone, a rename that moved a row from one
                    // letter to another redrew the HEADER and not the row:
                    // `rowView` was re-evaluated with the new title -- logged,
                    // once -- and the pinned-header LazyVStack kept the
                    // rendering it had. Photographed on an iPhone: "Big Fake
                    // Book" under a header reading "R". It is not new to
                    // books; a set list renamed across letters did the same,
                    // and renaming within one letter always worked, which is
                    // why nobody saw it.
                    ForEach(group.rows) { row in
                        rowView(row).id("\(row.id)|\(row.title)")
                    }
                } header: {
                    // BandHeader rather than a hand-rolled Text: it was a tiny
                    // lowercase "s" on an unruled 18pt strip, which is not what
                    // a section header looks like anywhere else in the app
                    // (§12.6). One component, so it cannot drift again.
                    BandHeader(title: group.letter, role: .titleS) { EmptyView() }
                        .id("letter-\(group.letter)")
                }
            }
        } else {
            // The same identity as above: under these sorts nothing moves
            // between sections, but a row that is redrawn for one reason and
            // not another is the defect, not the section.
            ForEach(rows) { row in rowView(row).id("\(row.id)|\(row.title)") }
        }
    }

    private func rowView(_ row: LibraryRow) -> some View {
        VStack(spacing: 0) {
            if renaming == row.id {
                InlineRenameRow(text: $renameDraft,
                                containerIdentifier: "inline-rename-row",
                                leading: Theme.Metric.s20 + (editing ? Theme.Metric.checkboxGutter : 0),
                                selectAll: renameSelectAll,
                                onSave: { commitRename(row); renameSelectAll = false },
                                onCancel: { renaming = nil; renameSelectAll = false })
            } else {
                HStack(spacing: 0) {
                    if editing { checkbox(row) }
                    LRow(row: row, identifier: "row-\(row.id)",
                         action: { editing ? toggle(row) : open(row) },
                         onMenu: editing ? nil : { toggleRow(row) },
                         // Set lists ONLY. Books and sources have no share path
                         // at all -- guard rails 3 and 4 stand unamended (§8.2),
                         // so this is absent rather than disabled for them.
                         onShare: segment == .setlists && !editing
                                  ? { onShareSetlist(row.id) } : nil,
                         isShared: sharedSetlistIds.contains(row.id),
                         onSync: syncAction(row),
                         syncStatus: syncStatus(row),
                         isSelected: editing && selected.contains(row.id),
                         menuIsOpen: openRow == row.id,
                         actions: openRow == row.id ? rowActions(row) : [],
                         onLongPress: editing ? nil : { enterEditing(with: row) })
                    if segment == .setlists, !editing {
                        // L7: Play sits beside ☰ on every set list row, since
                        // playing from the top is what a set list is for.
                        Button { onRowAction(row, .open) } label: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.Surface.paper)
                                .frame(width: 32, height: 32)
                                .background(Theme.Accent.clayPress)
                                .clipShape(Circle())
                                .frame(width: Theme.Metric.hitTarget, height: Theme.Metric.hitTarget)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(row.arrangementCount == 0)
                        .opacity(row.arrangementCount == 0 ? 0.45 : 1)
                        .accessibilityIdentifier("setlist-play-\(row.id)")
                        .accessibilityLabel("Play \(row.title) from the top")
                        .padding(.trailing, Theme.Metric.s8)
                    }
                }
                // [C4]: the open row is a flat tint band the width of the page.
                .background(openRow == row.id ? Theme.Accent.clayTint : Color.clear)
            }
            Theme.Rule()
        }
    }

    /// ☰: the row's actions, in the row (§7.3). One row open at a time.
    private func toggleRow(_ row: LibraryRow) {
        if openRow == row.id { openRow = nil; panel.done() } else { openRow = row.id }
    }

    /// A long press enters Edit with that row checked [C11].
    private func enterEditing(with row: LibraryRow) {
        openRow = nil
        editing = true
        selected = [row.id]
    }

    /// The row's own actions, by what the row is (L6, L8, L9).
    private func rowActions(_ row: LibraryRow) -> [RowActionItem] {
        var items: [RowActionItem] = []
        items.append(RowActionItem(id: "row-open-\(row.id)", title: "Open") { open(row) })
        switch segment {
        case .pieces:
            if isPiece(row) {
                items.append(RowActionItem(id: "row-arrangements-\(row.id)", title: "Arrangements",
                                           count: row.arrangementCount,
                                           lit: panel.isShowing(.pieceArrangements(row.id))) {
                    panel.toggle(.pieceArrangements(row.id))
                })
                items.append(RowActionItem(id: "row-details-\(row.id)", title: "Details",
                                           lit: panel.isShowing(.thisPiece(row.id))) {
                    panel.toggle(.thisPiece(row.id))
                })
            } else {
                items.append(RowActionItem(id: "row-versions-\(row.id)", title: "Versions",
                                           lit: panel.isShowing(.versions(row.id))) {
                    panel.toggle(.versions(row.id))
                })
                items.append(RowActionItem(id: "row-details-\(row.id)", title: "Details",
                                           lit: panel.isShowing(.details(row.id))) {
                    panel.toggle(.details(row.id))
                })
                items.append(RowActionItem(id: "row-setlists-\(row.id)", title: "Set lists",
                                           lit: panel.isShowing(.setlistsFor(row.id))) {
                    panel.toggle(.setlistsFor(row.id))
                })
            }
        case .setlists:
            items.append(RowActionItem(id: "row-share-action-\(row.id)",
                                       title: sharedSetlistIds.contains(row.id) ? "Shared" : "Share") {
                onShareSetlist(row.id)
            })
            items.append(RowActionItem(id: "row-rename-\(row.id)", title: "Rename") {
                renameDraft = row.title; renaming = row.id; openRow = nil
            })
            items.append(RowActionItem(id: "row-setlist-screen-\(row.id)", title: "Set list") {
                onOpenSetlistScreen(row.id)
            })
        case .books:
            // Rename, 0.8.2: the engine can do it now (`rename-book`). It is
            // the LABEL and nothing else -- the slug names books/<slug>.pdf
            // and every extraction ever taken out of this book recorded it --
            // so this offers exactly what a set list's Rename offers and
            // nothing that implies the file moves.
            items.append(RowActionItem(id: "row-rename-\(row.id)", title: "Rename") {
                renameDraft = row.title; renaming = row.id; openRow = nil
            })
        }
        items.append(RowActionItem(id: "row-delete-\(row.id)", title: "Delete", destructive: true,
                                   confirm: "Delete?") {
            openRow = nil
            onRowAction(row, .delete)
        })
        return items
    }

    /// A rename the root asked for, once the row is in the list.
    private func honourRenameRequest() {
        guard let slug = renameRequest, let row = rows.first(where: { $0.id == slug }) else { return }
        renameDraft = row.title
        renameSelectAll = true
        renaming = row.id
        openRow = nil
        renameRequest = nil
    }

    private func commitRename(_ row: LibraryRow) {
        let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        guard !name.isEmpty, name != row.title else { return }
        // Which engine op, by which list the row is in. Pieces have no inline
        // rename here (a piece is renamed on its own screen, with its
        // arrangements in view), so only these two reach a commit.
        switch segment {
        case .setlists:
            Task { _ = await state.renameSetlist(setlist: row.id, name: name) }
        case .books:
            Task { _ = await state.renameBook(row.id, name: name) }
        case .pieces:
            break
        }
    }

    /// The leading checkbox (§2.1). Selecting is what raises the action bar.
    private func checkbox(_ row: LibraryRow) -> some View {
        Button { toggle(row) } label: {
            Image(systemName: selected.contains(row.id) ? "checkmark.square.fill" : "square")
                .font(.system(size: 17))
                .foregroundStyle(selected.contains(row.id) ? Theme.Accent.clayStrong
                                                           : Theme.Ink.ink3)
                .frame(width: Theme.Metric.checkboxGutter,
                       height: Theme.Metric.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("row-select-\(row.id)")
        .accessibilityLabel("Select \(row.title)")
        .accessibilityAddTraits(selected.contains(row.id) ? [.isSelected] : [])
    }

    private func toggle(_ row: LibraryRow) {
        if selected.contains(row.id) { selected.remove(row.id) }
        else { selected.insert(row.id) }
    }

    /// A piece filling up. It sits in the list from the moment the file is
    /// chosen, so "where did it go?" never has to be asked.
    ///
    /// THESE ROWS ARE THE TRANSCRIPTION QUEUE. They are already ordered, they
    /// already sit at the top of the library, and every import in flight is
    /// among them -- so the queue Ali asked to see is the list he was already
    /// looking at, with a position on each row that has not started and the
    /// word TRANSCRIBING or WAITING rather than a blanket IMPORTING. Adding a
    /// second surface to show the same six rows would be a second place for
    /// them to disagree.
    private func importingRow(_ pending: AppState.PendingImport) -> some View {
        let waiting = pending.isTranscription && pending.waiting
        let badge = pending.isTranscription
            ? (waiting ? "WAITING" : "TRANSCRIBING")
            : "IMPORTING"
        return VStack(spacing: 0) {
            HStack(spacing: Theme.Metric.s12) {
                PageThumb()
                VStack(alignment: .leading, spacing: 3) {
                    Text(rowTitle(for: pending))
                        .typeRole(.titleS).foregroundStyle(Theme.Ink.ink)
                    Text(pending.stage).typeRole(.meta).foregroundStyle(Theme.Ink.ink3)
                    if let fraction = pending.fraction {
                        ProgressView(value: fraction)
                            .tint(Theme.Accent.clay)
                            .frame(maxWidth: 180)
                    }
                }
                Spacer(minLength: Theme.Metric.s8)
                Text(badge).typeRole(.meta)
                    .foregroundStyle(Color(hex: 0x8A5A12))
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(Color(hex: 0xFBF2E6))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Metric.rCtl)
                            .stroke(Color(hex: 0xE8CFA6), lineWidth: 1)
                    }
            }
            .padding(.horizontal, Theme.Metric.s20)
            .padding(.vertical, 9)
            .frame(minHeight: 56)
            Theme.Rule()
        }
        .accessibilityIdentifier("importing-\(pending.id.uuidString)")
        .accessibilityLabel("\(rowTitle(for: pending)), \(badge.lowercased()), \(pending.stage)")
    }

    /// What the row is called. A transcription of a scan the reader already
    /// has is named by the ARRANGEMENT it belongs to -- which is the whole
    /// point of recording that identity -- and everything else by its piece or
    /// its file.
    private func rowTitle(for pending: AppState.PendingImport) -> String {
        if let slug = pending.arrangement,
           let score = state.manifest?.scores.first(where: { $0.slug == slug }) {
            return ScoreTitle.arrangementName(title: score.title, name: score.name,
                                              slug: score.slug)
        }
        return pieceName(for: pending) ?? pending.name
    }

    private func pieceName(for pending: AppState.PendingImport) -> String? {
        guard let slug = pending.piece else { return nil }
        return (state.manifest?.pieces ?? []).first { $0.slug == slug }?.name
    }

    private func isPiece(_ row: LibraryRow) -> Bool {
        (state.manifest?.pieces ?? []).contains { $0.slug == row.id }
    }

    /// Edit mode puts the same actions on screen as buttons.
    ///
    // Edit mode no longer repeats each row's actions underneath it (L22).
    // Versions / Set lists / Delete were drawn per row AND in the action bar
    // at the bottom, which is the same verbs twice with different scope: the
    // bar acts on everything ticked, the row buttons on one row. The division
    // is the one the row already states -- the action bar owns what you have
    // selected, the ☰ owns the row it sits on -- and the ☰ is now present in
    // both modes, so nothing lost a way in.

    /// Still looking. It says so quietly and takes the same room the list will,
    /// so the screen does not jump when the rows arrive.
    private var loading: some View {
        StateView(systemImage: "music.note.list",
                  title: "Opening your library…",
                  identifier: "library-loading")
            .frame(maxWidth: .infinity)
            .padding(.top, Theme.Metric.s32)
    }

    /// The empty library is the app's FIRST screen now (§4C), so it is a STATE
    /// rather than a sentence in the top-left corner: centred glyph, title,
    /// one line of help, and the one button that resolves it.
    ///
    /// The action row stays above it either way -- the state's Import and the
    /// row's Import are the same action, and a new reader should find it
    /// wherever they look first.
    @ViewBuilder
    private var empty: some View {
        if search.isEmpty && filters.isEmpty {
            let empty = LibraryModel.emptyState(segment: segment)
            StateView(systemImage: empty.systemImage,
                      title: empty.title,
                      message: empty.message,
                      actionTitle: empty.actionTitle,
                      actionKind: .primary,
                      identifier: "library-empty",
                      action: {
                          switch segment {
                          case .pieces:   onImport()
                          case .books:    onImportBook()
                          case .setlists: creatingName = ""
                          }
                      })
                .frame(maxWidth: .infinity)
                .padding(.top, Theme.Metric.s32)
        } else {
            StateView(systemImage: "magnifyingglass",
                      title: "No matches",
                      message: "Nothing here matches what you are looking for.",
                      identifier: "library-empty")
                .frame(maxWidth: .infinity)
                .padding(.top, Theme.Metric.s32)
        }
    }

    // The `+` FAB and its New/Import band are gone (§4C). They offered
    // exactly what the action row now shows permanently, which makes the row
    // the de-duplication rather than a second way in.

    // MARK: - Data

    /// The imports in flight that belong to the segment on screen.
    private var pendingHere: [AppState.PendingImport] {
        state.pendingImports.filter { $0.target.segment == segment }
    }

    private var rows: [LibraryRow] {
        guard let manifest = state.manifest else { return [] }
        var base: [LibraryRow]
        switch segment {
        case .pieces:
            let tags = state.allArrangementTags
            base = LibraryModel.pieceRows(manifest: manifest, arrangementTags: tags)
                + LibraryModel.unfiledRows(manifest: manifest, arrangementTags: tags)
        case .setlists:
            base = LibraryModel.setlistRows(manifest: manifest)
        case .books:
            base = LibraryModel.bookRows(manifest: manifest)
        }
        base = LibraryModel.filtered(base, by: filters, manifest: manifest)
        return LibraryModel.sorted(LibraryModel.searched(base, query: search), by: sort)
    }

    /// Derived filters, computed from the manifest -- not a tag store (§7).
    private func open(_ row: LibraryRow) {
        if segment == .books {
            onOpenBook(row.id)
            return
        }
        if segment == .setlists {
            // L7/L8: the row opens the set list's own screen; Play, beside the
            // ☰, is what plays it from the top.
            onOpenSetlistScreen(row.id)
            return
        }
        // A piece is not openable (§2): opening one means opening one of its
        // arrangements. One arrangement goes straight there; several put the
        // choice on screen.
        if (state.manifest?.pieces ?? []).contains(where: { $0.slug == row.id }) {
            onOpenPiece(row.id)
        } else {
            onOpenArrangement(row.id)
        }
    }
}
