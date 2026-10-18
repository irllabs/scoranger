import SwiftUI

/// Where an arrangement should be filed (NAV_MODAL_FREE_0.4.2 §3.3).
///
/// What `MoveToPieceSheet` was. The spec calls filing the single biggest hole
/// the revision closes: it previously existed only as a drag or a long press,
/// so someone who did not know the gesture had no way to file anything.
struct MoveToPieceScreen: View {
    @EnvironmentObject var state: AppState
    let moving: [String]
    var onBack: () -> Void

    @State private var creating = false
    @State private var draft = ""

    var body: some View {
        Screen(title: "Move to piece", backLabel: "Back",
               subtitle: subject, onBack: onBack) {
            VStack(alignment: .leading, spacing: 0) {
                // The consequence, stated before the choice rather than
                // discovered after it: #N is a position within a piece.
                Text("Arrangements are numbered within their piece, so moving "
                     + "these renumbers both pieces.")
                    .typeRole(.meta).foregroundStyle(Theme.Ink.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Metric.s20)
                    .padding(.vertical, Theme.Metric.s12)

                PanelLabel(text: "Pieces", ruled: false)
                ForEach(state.manifest?.pieces ?? []) { piece in
                    ScreenRow(title: piece.name,
                              value: current == piece.slug ? "current" : nil,
                              leads: false,
                              identifier: "move-target-\(piece.slug)") {
                        commit(to: piece.slug)
                    }
                }

                if creating {
                    InlineRenameRow(text: $draft,
                                    onSave: { commitNewPiece() },
                                    onCancel: { creating = false })
                } else {
                    ScreenRow(title: "New piece", leads: false,
                              identifier: "move-target-new") {
                        draft = ""
                        creating = true
                    }
                }
                ScreenRow(title: "Remove from piece", value: "leaves them unfiled",
                          leads: false, identifier: "move-target-none") {
                    commit(to: nil)
                }
            }
            .padding(.bottom, Theme.Metric.s32)
        }
    }

    private var subject: String {
        moving.count == 1
            ? (state.manifest?.scores.first { $0.slug == moving[0] }
                .map { ScoreTitle.arrangementName(title: $0.title, name: $0.name,
                                                  slug: $0.slug) } ?? "one arrangement")
            : "\(moving.count) arrangements"
    }

    private var current: String? {
        moving.count == 1 ? state.placement(of: moving[0])?.piece.slug : nil
    }

    private func commit(to piece: String?) {
        for slug in moving { state.assignToPiece(scoreSlug: slug, piece: piece) }
        onBack()
    }

    private func commitNewPiece() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        creating = false
        guard !name.isEmpty else { return }
        Task {
            // assign-piece creates the piece when it is missing, so filing into
            // a new one is the same call with a new name
            for slug in moving { state.assignToPiece(scoreSlug: slug, piece: name) }
            onBack()
        }
    }
}

/// Which set lists an arrangement belongs to (§3.4). Membership commits on tap:
/// nothing to confirm, nothing to dismiss.
struct SetlistsForScreen: View {
    @EnvironmentObject var state: AppState
    let slug: String
    var onBack: () -> Void

    @State private var creating = false
    @State private var draft = ""

    var body: some View {
        Screen(title: "Set lists", backLabel: "Back", subtitle: name, onBack: onBack) {
            VStack(alignment: .leading, spacing: 0) {
                PanelLabel(text: "Set lists", ruled: false)
                ForEach(state.manifest?.setlists ?? []) { setlist in
                    let member = setlist.arrangements.contains(slug)
                    Button {
                        Task {
                            if member {
                                _ = await state.removeFromSetlist(setlist: setlist.slug,
                                                                  score: slug)
                            } else {
                                _ = await state.addToSetlist(setlist: setlist.slug,
                                                             score: slug)
                            }
                        }
                    } label: {
                        HStack(spacing: Theme.Metric.s8) {
                            Image(systemName: member ? "checkmark.square.fill" : "square")
                                .foregroundStyle(member ? Theme.Accent.clayStrong
                                                        : Theme.Ink.ink3)
                            Text(setlist.name).typeRole(.row).foregroundStyle(Theme.Ink.ink)
                            Spacer()
                            Text("\(setlist.arrangements.count)").typeRole(.data)
                                .foregroundStyle(Theme.Ink.ink3)
                        }
                        .padding(.horizontal, Theme.Metric.s20)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chooser-\(setlist.slug)")
                    .accessibilityAddTraits(member ? [.isSelected] : [])
                }
                if creating {
                    InlineRenameRow(text: $draft, onSave: commitNew,
                                    onCancel: { creating = false })
                } else {
                    ScreenRow(title: "New set list", leads: false,
                              identifier: "setlists-new") { draft = ""; creating = true }
                }
            }
            .padding(.bottom, Theme.Metric.s32)
        }
    }

    private var name: String? {
        state.manifest?.scores.first { $0.slug == slug }
            .map { ScoreTitle.arrangementName(title: $0.title, name: $0.name,
                                              slug: $0.slug) }
    }

    private func commitNew() {
        let wanted = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        creating = false
        guard !wanted.isEmpty else { return }
        Task {
            if let made = await state.createSetlist(name: wanted) {
                _ = await state.addToSetlist(setlist: made, score: slug)
            }
        }
    }
}

/// A set list's running order (§3.5).
///
/// Here the row's ☰ EXPANDS rather than pushes, by the rule in
/// RowMenuBehaviour: every action is one tap. One row open at a time, and the
/// open row's ☰ is lit so the two behaviours are told apart. Dragging the ☰
/// reorders the list and swiping a row left takes it out (`ReorderableRows`).
struct SetlistScreen: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var shared: SharedSetlists
    @EnvironmentObject var signIn: SignIn
    @EnvironmentObject var panel: PanelModel
    let slug: String
    var onBack: () -> Void
    var onOpen: (String) -> Void
    var push: (Route) -> Void
    /// Share, from the foot strip (Ph2). The SAME action `ThisSetlistPanel`'s
    /// row runs -- a second sharing path would be a second answer to who owns
    /// the upload.
    var onShare: () -> Void = {}

    /// The member whose ☰ is open, its actions in the row (S2).
    @State private var expanded: String?
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// A phone has no column beside the page, so the list's own tools sit on
    /// one line at its foot (Ph2, `PageFootStrip`).
    private var isCompact: Bool { sizeClass == .compact }

    private var setlist: SetlistDoc? {
        state.manifest?.setlists?.first { $0.slug == slug }
    }

    var body: some View {
        Screen(title: "", backLabel: "Library",
               subtitle: summary, onBack: onBack,
               trailing: {
                   PanelButton(title: "Play", kind: .primary, identifier: "setlist-play") {
                       if let first = setlist?.arrangements.first { onOpen(first) }
                   }
                   .disabled((setlist?.arrangements ?? []).isEmpty)
               }) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Metric.s12) {
                    EditableTitle(text: setlist?.name ?? "Set list", role: .title,
                                  identifier: "setlist-title") { name in
                        Task { _ = await state.renameSetlist(setlist: slug, name: name) }
                    }
                    if let summary {
                        Text(summary).typeRole(.meta).foregroundStyle(Theme.Ink.ink3).lineLimit(1)
                    }
                }
                .padding(.horizontal, Theme.Metric.pageSide)
                .padding(.top, Theme.Metric.s12)
                .padding(.bottom, Theme.Metric.s12)

                // The list is the list: no "Running order" header (§10). A
                // shared row's order goes up through the same reorder: the
                // set list sync sees the manifest change, whatever made it.
                ReorderableRows(items: setlist?.arrangements ?? [],
                                reorder: { move in
                                    await state.reorderSetlist(slug, order: move.order)
                                },
                                deletion: removal(of:)) { member, handle in
                    memberRow(member, handle: handle)
                }
                if (setlist?.arrangements ?? []).isEmpty {
                    // S7: one button opens Add beside it.
                    VStack(alignment: .leading, spacing: Theme.Metric.s12) {
                        Text("Nothing in this set list yet.").typeRole(.body)
                            .foregroundStyle(Theme.Ink.ink2)
                        PanelButton(title: "Add", kind: .primary,
                                    identifier: "setlist-add-\(slug)") { push(.addArrangements(slug)) }
                    }
                    .padding(Theme.Metric.pageSide)
                }
            }
            .padding(.bottom, isCompact ? PageFootStrip.inset : Theme.Metric.s32)
        }
        .overlay(alignment: .bottom) {
            if isCompact { PageFootStrip(items: tools) }
        }
    }

    /// The four the panel at rest carries on an iPad (S1), as a strip: Add,
    /// Share, People while it is shared, and More for the rest -- which is
    /// the same `thisSetlist` state, pushed as a page (Ph3). Delete is not
    /// promoted to the strip: it lives under More with the consequence
    /// written beside it, where it already is.
    private var tools: [PageFootStrip.Item] {
        var items: [PageFootStrip.Item] = [
            .init(id: "setlist-tool-add", title: "Add", glyph: "plus") {
                push(.addArrangements(slug))
            },
        ]
        if let setlist {
            items.append(.init(id: "setlist-tool-share",
                               title: setlist.isShared ? "Shared" : "Share",
                               glyph: "square.and.arrow.up") { onShare() })
            if setlist.isShared, let shareId = setlist.shareId {
                items.append(.init(id: "setlist-tool-people", title: "People",
                                   glyph: "person.2") { push(.sharedSetlist(shareId)) })
            }
        }
        items.append(.init(id: "setlist-tool-more", title: "More") {
            push(.thisSetlist(slug))
        })
        return items
    }

    /// The swipe's trash button: out of the set list, and nothing else -- the
    /// arrangement stays in the library and can be added back from Add. Not
    /// on the row whose ☰ is open, for the reason `PieceScreen` gives.
    private func removal(of member: String) -> RowDeletion? {
        guard expanded != member else { return nil }
        return RowDeletion(identifier: "setlist-remove-\(member)",
                           label: "Remove \(label(for: member)) from the set list",
                           actionName: "Remove from set list",
                           perform: {
                               Task { _ = await state.removeFromSetlist(setlist: slug, score: member) }
                           })
    }

    private func memberRow(_ member: String, handle: ReorderableRowHandle) -> some View {
        let index = handle.index
        let open = expanded == member
        return HStack(spacing: Theme.Metric.s12) {
            HStack(spacing: Theme.Metric.s12) {
                    // The ordinal, the title, and the arrangement's stamp at
                    // the END of the row (0.20.1). It sat between the ordinal
                    // and the title, and only some rows have one -- an
                    // arrangement alone in its piece carries no number -- so
                    // the titles of a set list were in two columns (Ali's
                    // photograph of Echo and Baba). Every title starts at
                    // the same x now; the stamp stands beside the menu.
                    Text("\(index + 1)").typeRole(.data).foregroundStyle(Theme.Ink.ink3)
                        .frame(width: 28, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(label(for: member)).typeRole(.titleS)
                            .foregroundStyle(Theme.Ink.ink).lineLimit(1)
                        if open {
                            RowActionsBar(actions: memberActions(member))
                        } else {
                            Text(memberMeta(member)).typeRole(.meta)
                                .foregroundStyle(Theme.Ink.ink3).lineLimit(1)
                        }
                    }
                    Spacer()
                    if let number = state.placement(of: member)?.number {
                        NumeralBadge(number: number)
                            .accessibilityIdentifier("setlist-number-\(member)")
                    }
            }
            .rowTappable(label: label(for: member), identifier: "setlist-member-\(member)",
                         container: open) { onOpen(member) }
            .reorderableRowActions(handle)

            RowMenuButton(identifier: "row-menu-\(member)",
                          label: open ? "Close the actions" : "Manage \(label(for: member))",
                          isOpen: open) {
                if open { expanded = nil; panel.done() } else { expanded = member }
            }
            .reorderGrip(handle)
        }
        .padding(.horizontal, Theme.Metric.pageSide)
        .padding(.vertical, Theme.Metric.s8)
        .frame(minHeight: 64)
        .background(open ? Theme.Accent.clayTint : Color.clear)
    }

    /// S2: Open, Arrangement -- on the row. Reordering is the ☰ dragged and
    /// removing is the row swiped left (`ReorderableRows`).
    private func memberActions(_ member: String) -> [RowActionItem] {
        [
            RowActionItem(id: "setlist-open-\(member)", title: "Open") { onOpen(member) },
            RowActionItem(id: "setlist-manage-\(member)", title: "Arrangement",
                          lit: panel.isShowing(.arrangement(member))) {
                panel.toggle(.arrangement(member))
            },
        ]
    }

    private func label(for member: String) -> String {
        state.manifest?.scores.first { $0.slug == member }
            .map { ScoreTitle.arrangementName(title: $0.title, name: $0.name, slug: $0.slug) }
            ?? member
    }

    /// "Sous le ciel de Paris · v003"
    private func memberMeta(_ member: String) -> String {
        var bits: [String] = []
        if let p = state.placement(of: member) { bits.append(p.piece.name) }
        if let latest = state.manifest?.scores.first(where: { $0.slug == member })?.versions.last {
            bits.append(latest.name)
        }
        return bits.joined(separator: " · ")
    }

    private var summary: String? {
        guard let setlist else { return nil }
        let n = setlist.arrangements.count
        return "\(n) arrangement\(n == 1 ? "" : "s")" + (setlist.isShared ? " · shared" : "")
    }
}

/// Which arrangements a set list holds — the other direction of membership.
struct AddArrangementsScreen: View {
    @EnvironmentObject var state: AppState
    let slug: String
    var onBack: () -> Void

    var body: some View {
        Screen(title: "Add", backLabel: "Back", onBack: onBack) {
            VStack(alignment: .leading, spacing: 0) {
                PanelLabel(text: "In this set list", ruled: false)
                ForEach(state.manifest?.scores ?? []) { score in
                    let member = (state.manifest?.setlists?
                        .first { $0.slug == slug }?.arrangements ?? []).contains(score.slug)
                    Button {
                        Task {
                            if member {
                                _ = await state.removeFromSetlist(setlist: slug,
                                                                  score: score.slug)
                            } else {
                                _ = await state.addToSetlist(setlist: slug, score: score.slug)
                            }
                        }
                    } label: {
                        HStack(spacing: Theme.Metric.s8) {
                            Image(systemName: member ? "checkmark.square.fill" : "square")
                                .foregroundStyle(member ? Theme.Accent.clayStrong
                                                        : Theme.Ink.ink3)
                            Text(label(score)).typeRole(.row).foregroundStyle(Theme.Ink.ink)
                            Spacer()
                        }
                        .padding(.horizontal, Theme.Metric.s20)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(
                        member ? "picker-remove-\(score.slug)" : "picker-add-\(score.slug)")
                }
            }
            .padding(.bottom, Theme.Metric.s32)
        }
    }

    private func label(_ score: ScoreDoc) -> String {
        if let p = state.placement(of: score.slug) { return "\(p.piece.name) #\(p.number)" }
        return ScoreTitle.arrangementName(title: score.title, name: score.name,
                                          slug: score.slug)
    }
}

/// The version history (§3.6). Replaces the old version menu and the sheet's
/// nested list: tapping a version displays it and returns.
struct VersionsScreen: View {
    @EnvironmentObject var state: AppState
    let slug: String
    var onBack: () -> Void
    var onShow: (String?) -> Void

    @State private var expanded: Set<String> = []

    var body: some View {
        Screen(title: "Versions", backLabel: "Back", subtitle: name, onBack: onBack) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(groups) { group in
                    groupRow(group)
                    if expanded.contains(group.id) {
                        ForEach(group.subs.reversed(), id: \.id) { step in
                            ScreenRow(title: step.name,
                                      value: VersionLabel.text(op: step.op,
                                                               prompt: step.turn?.prompt),
                                      leads: false,
                                      isSelected: step.id == shown,
                                      identifier: "step-\(slug)-\(step.name)") {
                                show(step.id)
                            }
                            .padding(.leading, Theme.Metric.stepIndent)
                        }
                    }
                }
            }
            .padding(.bottom, Theme.Metric.s32)
        }
    }

    /// One chat prompt can produce a run of versions. They collapse into one
    /// row under the prompt that made them, opened by a caret -- history a
    /// person can read, rather than eight rows saying "transpose".
    private var groups: [AppState.VersionGroup] {
        score.map { state.versionGroups(for: $0) } ?? []
    }

    @ViewBuilder
    private func groupRow(_ group: AppState.VersionGroup) -> some View {
        let steps = group.subs.count
        if steps > 1 {
            let open = expanded.contains(group.id)
            // The caret is a SIBLING of the row, not something inside it:
            // ScreenRow collapses its children into one accessibility element,
            // so a caret drawn inside it would be findable and untappable.
            HStack(spacing: 0) {
                Button {
                    if open { expanded.remove(group.id) } else { expanded.insert(group.id) }
                } label: {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.Ink.ink3)
                        .frame(width: Theme.Metric.hitTarget, height: Theme.Metric.hitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(open ? "Hide the steps of this prompt"
                                         : "Show the \(steps) steps of this prompt")
                .accessibilityIdentifier("steps-toggle-\(slug)-\(group.id)")
                ScreenRow(title: group.title,
                          value: "\(group.face.name) · \(steps) steps",
                          leads: false,
                          // while the steps are open they own the highlight:
                          // a group's steps include its own face, and lighting
                          // both read as two versions being open at once
                          isSelected: !open && group.subs.contains { $0.id == shown },
                          identifier: "version-\(slug)-\(group.face.name)") {
                    show(group.face.id)
                }
            }
            .padding(.leading, Theme.Metric.s6)
        } else {
            ScreenRow(title: group.face.name,
                      value: VersionLabel.text(op: group.face.op,
                                               prompt: group.face.turn?.prompt),
                      leads: false,
                      isSelected: group.face.id == shown,
                      identifier: "version-\(slug)-\(group.face.name)") {
                show(group.face.id)
            }
        }
    }

    /// The version on screen right now -- the pinned one, or the latest when
    /// nothing is pinned.
    private var shown: String? {
        state.displayedVersionID ?? score?.latest
    }

    private func show(_ version: String) {
        onShow(version == score?.latest ? nil : version)
    }

    private var score: ScoreDoc? { state.manifest?.scores.first { $0.slug == slug } }
    private var name: String? {
        score.map { ScoreTitle.arrangementName(title: $0.title, name: $0.name,
                                               slug: $0.slug) }
    }
}

/// Parts and ranges — read-only, from the version snapshot the engine writes.
struct PartsScreen: View {
    @EnvironmentObject var state: AppState
    let slug: String
    var onBack: () -> Void

    var body: some View {
        Screen(title: "Parts", backLabel: "Back", subtitle: name,
               onBack: onBack) {
            VStack(alignment: .leading, spacing: 0) {
                let parts = score?.versions.last?.parts ?? []
                if parts.isEmpty {
                    Text("No parts recorded for this version.")
                        .typeRole(.meta).foregroundStyle(Theme.Ink.ink3)
                        .padding(Theme.Metric.s20)
                } else {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                        ScreenRow(title: part.name,
                                  value: [part.instrument,
                                          part.range?.joined(separator: "–")]
                                      .compactMap { $0 }.joined(separator: " · "),
                                  leads: false,
                                  identifier: "part-\(part.name)") {}
                    }
                }
            }
            .padding(.bottom, Theme.Metric.s32)
        }
    }

    private var score: ScoreDoc? { state.manifest?.scores.first { $0.slug == slug } }
    private var name: String? {
        score.map { ScoreTitle.arrangementName(title: $0.title, name: $0.name,
                                               slug: $0.slug) }
    }
}


/// An arrangement's details.
///
/// It takes the slug once and keeps the ScoreDoc it found. The slug is
/// editable inside, so a screen that re-resolved by slug would tear itself
/// down mid-edit -- `ScoreInfoView` already follows the move on its own.
struct DetailsScreen: View {
    @EnvironmentObject var state: AppState
    let slug: String
    var onBack: () -> Void

    @State private var opened: ScoreDoc?

    var body: some View {
        Group {
            if let score = opened {
                Screen(title: "Details", backLabel: "Back",
                       subtitle: ScoreTitle.arrangementName(title: score.title,
                                                            name: score.name,
                                                            slug: score.slug),
                       onBack: onBack) {
                    ScoreInfoView(score: score)
                }
            } else {
                Color.clear
            }
        }
        .onAppear {
            if opened == nil {
                opened = state.manifest?.scores.first { $0.slug == slug }
            }
        }
    }
}

/// What combining the checked pieces will do, said before it is done.
///
/// A screen rather than the action bar's delete-and-undo, because combining
/// CANNOT be undone: the absorbed pieces stop existing and the engine has no
/// record to restore them from. The bar's destructive verb can be casual
/// because the row comes back; this one cannot.
///
/// A screen rather than a `ConfirmDeleteStrip`, because the consequences are
/// several sentences and one of them is about numbering, which is the thing a
/// reader notices first and would otherwise discover afterwards. The strip
/// holds one.
///
/// `CombinePieces.plan` works all of it out; this only draws it.
struct CombinePiecesScreen: View {
    @EnvironmentObject var state: AppState
    let combining: [String]
    var onBack: () -> Void

    var body: some View {
        Screen(title: "Combine pieces", backLabel: "Back",
               subtitle: subject, onBack: onBack) {
            VStack(alignment: .leading, spacing: 0) {
                if plan.isPossible {
                    // The consequences, stated before the choice rather than
                    // discovered after it.
                    VStack(alignment: .leading, spacing: Theme.Metric.s8) {
                        ForEach(plan.consequences, id: \.self) { line in
                            Text(line)
                                .typeRole(.meta).foregroundStyle(Theme.Ink.ink3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, Theme.Metric.s20)
                    .padding(.vertical, Theme.Metric.s12)
                    .accessibilityIdentifier("combine-consequences")

                    PanelLabel(text: "Keeping", ruled: false)
                    ScreenRow(title: plan.survivorName,
                              value: plan.total == 1 ? "1 arrangement"
                                                     : "\(plan.total) arrangements",
                              leads: false, isSelected: true,
                              identifier: "combine-keeping-\(plan.survivor)") {}

                    PanelLabel(text: "Folding in")
                    ForEach(Array(plan.absorbed.enumerated()), id: \.offset) { index, slug in
                        ScreenRow(title: plan.absorbedNames[index], leads: false,
                                  identifier: "combine-absorbing-\(slug)") {}
                    }

                    PanelLabel(text: "Careful")
                    ScreenRow(title: "Combine into \(plan.survivorName)",
                              leads: false, isDestructive: true,
                              identifier: "combine-confirm") {
                        Task {
                            _ = await state.combinePieces(
                                [plan.survivor] + plan.absorbed)
                            state.notice = plan.consequences.first
                            onBack()
                        }
                    }
                } else {
                    Text("Combining needs two pieces or more.")
                        .typeRole(.body).foregroundStyle(Theme.Ink.ink2)
                        .padding(Theme.Metric.s20)
                        .accessibilityIdentifier("combine-needs-two")
                }
            }
            .padding(.bottom, Theme.Metric.s32)
        }
    }

    /// The pieces in the order the library listed them; the first survives.
    private var chosen: [PieceDoc] {
        let pieces = state.manifest?.pieces ?? []
        return combining.compactMap { slug in pieces.first { $0.slug == slug } }
    }

    private var plan: CombinePieces.Plan { CombinePieces.plan(pieces: chosen) }

    private var subject: String {
        combining.count == 1 ? "one piece" : "\(combining.count) pieces"
    }
}
