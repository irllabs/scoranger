import SwiftUI

/// A set list the band shares: its running order, who is in it, and the things
/// each of them may do to it.
///
/// The product ask, principles 2, 4 and 5 of design/FIREBASE.md §0. The screen
/// is deliberately thin -- every rule it appears to apply is decided elsewhere
/// and tested there (`SetlistPermission`, `SharedOrder`, `SetlistInvite`), and
/// the copy that actually binds is `firebase/firestore.rules`.
///
/// It differs from the local set list screen in one visible way, and it has to:
/// **a shared set list you cannot reach is read-only and says so.** Your own
/// library is editable offline forever; this is cloud-authoritative and cached
/// (§4.4, §5.3). Showing a reorder that will never land is worse than refusing
/// it.
struct SharedSetlistScreen: View {
    let setlistId: String
    var onBack: () -> Void
    /// Open one of the entries, by the local slug this device filed its copy
    /// under. The screen does not open scores itself: the score is presented
    /// over the tabs rather than pushed, and that is the navigation stack's
    /// business (NAVIGATION_SYSTEM.md §3).
    var onOpen: (String) -> Void = { _ in }

    @EnvironmentObject var state: AppState
    @EnvironmentObject var shared: SharedSetlists
    @EnvironmentObject var signIn: SignIn

    @State private var inviting = false
    @State private var address = ""
    @State private var sending = false
    @State private var invitation: String?
    @State private var adding = false
    @State private var confirmingDelete = false
    @State private var opening: String?
    /// The open link, ready for the iOS share sheet. Wrapped so `.sheet(item:)`
    /// has an identity to present on.
    @State private var linkToSend: SendableLink?
    @State private var mintingLink = false

    private struct SendableLink: Identifiable {
        let url: URL
        let name: String
        var id: String { url.absoluteString }
    }

    /// The setlist DOCUMENT, not an entry in a list.
    ///
    /// Derived from `shared.setlists` once, and that was the bug: anything
    /// that left the memberships-driven list empty -- a missing index row, or
    /// the listener simply not having answered -- made this nil.
    private var setlist: SharedSetlists.Setlist? { shared.open }

    /// Nil means NOT KNOWN YET, and is rendered as loading.
    ///
    /// It used to be `?? .reader`, which turned "I have not been told" into
    /// "you may do the least" -- and an owner then saw a single red "Leave
    /// this set list". A permissions fallback that shows fewer controls looks
    /// like a decision and is really just ignorance, so there is no fallback.
    private var role: SetlistRole? { shared.openRole }

    private var mayEdit: Bool {
        guard let role else { return false }
        return SetlistPermission.allows(role, .addEntry) && !shared.isStale
    }

    var body: some View {
        screen
            .sheet(item: $linkToSend) { link in
                ShareSheet(items: [ShareSetlistAction.message(name: link.name, url: link.url)])
            }
    }

    private var screen: some View {
        Screen(title: setlist?.name ?? "Shared set list",
               backLabel: "Library",
               subtitle: subtitle,
               onBack: onBack) {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                if role == nil {
                    // NOT a reader's view. Until the document has answered,
                    // the honest thing to show is that we are asking.
                    PanelNote(text: shared.open == nil
                              ? "Opening this set list…"
                              : "Checking what you can do here…")
                        .padding(Theme.Metric.panelPadding)
                        .accessibilityIdentifier("shared-loading")
                } else {
                    if shared.isStale { offline }
                    order
                    actions
                    whoseMarks
                    people
                    inkTrouble
                }
            }
        }
        .onAppear { shared.openSetlist(setlistId); shared.open(setlistId) }
        .onDisappear { shared.closeSetlist(); shared.close() }
    }

    private var subtitle: String? {
        guard let setlist else { return nil }
        let people = setlist.members.count
        return people == 1 ? "None" : "\(people) people"
    }

    // MARK: - offline

    private var offline: some View {
        // §5.3: named, and the actions are gone rather than dead. A greyed
        // button a person can still tap teaches them the app is broken.
        PanelNote(text: "You're offline, so this is the set list as you last "
                  + "saw it. You can read and mark it up; adding and "
                  + "reordering need a connection.")
            .padding(Theme.Metric.panelPadding)
            .accessibilityIdentifier("shared-offline")
    }

    // MARK: - the running order

    @ViewBuilder
    private var order: some View {
        if shared.entries.isEmpty {
            PanelNote(text: mayEdit
                      ? "Nothing yet — add an arrangement below."
                      : "Nothing in this set list yet.")
                .padding(Theme.Metric.panelPadding)
                .accessibilityIdentifier("shared-empty")
        }
        // Dragged by the grip, like the library's own set lists, where an
        // editor may reorder. A reader's list has no grip and no Move up.
        ReorderableRows(items: shared.entries.map(\.id), ruled: false,
                        canReorder: mayEdit,
                        reorder: { move in await self.move(move) }) { id, handle in
            if let entry = shared.entries.first(where: { $0.id == id }) {
                entryRow(entry, handle: handle)
            }
        }
    }

    private func entryRow(_ entry: SharedSetlists.Entry, handle: ReorderableRowHandle) -> some View {
        let position = handle.index + 1
        return HStack(spacing: Theme.Metric.s12) {
            Text("\(position)").typeRole(.meta).foregroundStyle(Theme.Ink.ink3)
                .frame(width: 20, alignment: .trailing)
            Button { open(entry) } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title).typeRole(.body).foregroundStyle(Theme.Ink.ink)
                        .lineLimit(1)
                    Text(opening == entry.id ? "Getting the music…"
                         : (entry.composer ?? ""))
                        .typeRole(.meta).foregroundStyle(Theme.Ink.ink3)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .reorderableRowActions(handle)
            Spacer(minLength: Theme.Metric.s8)
            if mayEdit {
                // A grip, not a button: this row has no actions for a tap to
                // open. VoiceOver moves the row by the Move up / Move down
                // actions on the row itself, so the glyph is hidden from it.
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.Ink.ink2)
                    .frame(width: Theme.Metric.hitTarget, height: Theme.Metric.hitTarget)
                    .contentShape(Rectangle())
                    .reorderGrip(handle)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Theme.Metric.s16)
        .frame(minHeight: Theme.Metric.hitTarget)
        .contentShape(Rectangle())
        .accessibilityIdentifier("shared-entry-\(position)")
    }

    /// One entry moved, however far. The write is still a single fractional
    /// index on a single document (§6.5), which is what lets two people move
    /// different entries at the same time without either move being lost.
    private func move(_ move: RowMove<String>) async -> Bool {
        guard let entry = shared.entries.first(where: { $0.id == move.item }),
              let landing = SharedOrder.neighbours(
                moving: entry.order, by: move.to - move.from,
                in: shared.entries.map(\.order))
        else { return false }
        do {
            try await shared.move(entry, afterKey: landing.before,
                                  beforeKey: landing.after, in: setlistId)
            return true
        } catch {
            state.report("move that entry", error)
            return false
        }
    }

    /// Read one entry.
    ///
    /// The music is DOWNLOADED and imported the first time, and after that this
    /// is an ordinary arrangement in the local library -- offline, annotatable,
    /// playable (`AppState.adoptSharedEntry`). What stays shared is the running
    /// order and the markup.
    private func open(_ entry: SharedSetlists.Entry) {
        guard opening == nil else { return }
        opening = entry.id
        Task {
            defer { opening = nil }
            guard let slug = await state.adoptSharedEntry(
                entry.id, title: entry.title,
                download: { try await shared.download(entry) }) else { return }
            // The band's ink, live, for as long as this entry is the one open.
            // The width the canvas is laid out at is read at push time rather
            // than captured, because it changes with the window.
            state.openSharedEntry = (setlistId, entry.id)
            shared.openInk(entry: entry.id, in: setlistId,
                           store: DrawingStore.shared,
                           pageWidth: { state.geometry?.page(0)?.size.width ?? 0 })
            onOpen(slug)
        }
    }

    // MARK: - what can be done

    @ViewBuilder
    private var actions: some View {
        BandHeader("This set list")
        if mayEdit {
            PanelButton(title: "Add", kind: .normal,
                        identifier: "shared-add") { adding = true }
        }
        if let role, SetlistPermission.allows(role, .invite), !shared.isStale {
            // THE LINK AGAIN. The same open link the row's share button mints
            // (§6A.0.1: cap 12, seven days, revocable), from here, because
            // this is where the owner comes to see who has joined and the
            // natural next thought is "and send it to one more person".
            PanelButton(title: mintingLink ? "Making the link…" : "Send",
                        kind: .primary, identifier: "shared-send-link") {
                guard !mintingLink, let setlist else { return }
                mintingLink = true
                Task {
                    defer { mintingLink = false }
                    do {
                        let inviteId = try await shared.invite(to: setlistId, email: nil)
                        guard let url = SharedInviteLink.webURL(inviteId: inviteId) else {
                            throw SharedSetlists.Trouble.unusablePayload
                        }
                        linkToSend = SendableLink(url: url, name: setlist.name)
                    } catch {
                        state.report("make the link", error)
                    }
                }
            }
            PanelButton(title: "Invite", kind: .normal,
                        identifier: "shared-invite") { inviting = true; address = "" }
            if inviting { inviteField }
        }
        if let setlist, setlist.isOwner {
            // PRINCIPLE 4, the one asymmetry. Named as what it does to other
            // people, not as "Delete".
            PanelButton(title: confirmingDelete
                        ? "Delete for everybody — tap again"
                        : "Delete this set list",
                        kind: .destructive,
                        identifier: "shared-delete") {
                if confirmingDelete {
                    Task {
                        // The document AND the local row. Deleting the document
                        // alone left the row in the library with nothing behind
                        // it, and nothing on the row could remove it.
                        if let mine = state.manifest?.setlists?.first(where: { $0.shareId == setlistId }) {
                            if await state.deleteSharedSetlistEverywhere(mine, shared: shared, remote: setlist) { onBack() }
                        } else {
                            do { try await shared.delete(setlist); onBack() }
                            catch { state.report("delete that set list", error) }
                        }
                    }
                } else {
                    confirmingDelete = true
                }
            }
            if confirmingDelete {
                PanelNote(text: "Everybody's markup on every arrangement in it "
                          + "goes too. Nobody else can do this.")
                    .padding(Theme.Metric.panelPadding)
            }
        } else if let role, SetlistPermission.mayLeave(role) {
            PanelButton(title: "Leave this set list", kind: .destructive,
                        identifier: "shared-leave") {
                guard let uid = signIn.account?.uid else { return }
                Task {
                    // Membership AND the local row (AppState.leaveSharedSetlist).
                    if let mine = state.manifest?.setlists?.first(where: { $0.shareId == setlistId }) {
                        if await state.leaveSharedSetlist(mine, shared: shared, uid: uid) { onBack() }
                    } else {
                        do { try await shared.removeMember(uid, from: setlistId); onBack() }
                        catch { state.report("leave that set list", error) }
                    }
                }
            }
        }

        if adding { arrangementPicker }
    }

    // MARK: - inviting

    @ViewBuilder
    private var inviteField: some View {
        VStack(alignment: .leading, spacing: Theme.Metric.s8) {
            TextField("Their email address", text: $address)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.emailAddress)
                .accessibilityIdentifier("shared-invite-address")

            // The address has to be the one they sign in with: the Function
            // checks it against their VERIFIED token, so a typo is a refusal
            // rather than a stranger getting in (§0.4).
            Text("It has to be the address they sign in with.")
                .typeRole(.meta).foregroundStyle(Theme.Ink.ink3)

            if let invitation, let setlist {
                let text = SharedInviteLink.message(setlistName: setlist.name,
                                                    email: SetlistInvite.normalise(address),
                                                    inviteId: invitation)
                Text("Send them this. The link on its own gets nobody in — it "
                     + "only works for that address.")
                    .typeRole(.meta).foregroundStyle(Theme.Ink.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                ShareLink(item: text) {
                    Text("Send the invitation").typeRole(.control)
                }
                .accessibilityIdentifier("shared-invite-send")
            } else {
                PanelButton(title: sending ? "Inviting…" : "Invite",
                            kind: .primary, identifier: "shared-invite-confirm") {
                    guard !sending, let setlist else { return }
                    sending = true
                    Task {
                        defer { sending = false }
                        do { invitation = try await shared.invite(to: setlistId, email: address) }
                        catch { state.report("send that invitation", error) }
                    }
                }
                .disabled(!SetlistInvite.looksLikeAnAddress(address))
            }
        }
        .padding(.horizontal, Theme.Metric.s16)
        .padding(.bottom, Theme.Metric.s12)
    }

    // MARK: - adding one of mine

    /// Every arrangement in my own library, to copy in.
    ///
    /// A COPY (§4.3, §12.13): the bytes go under `shared/{setlistId}/` so a
    /// member's permission to read them is a property of the path and not a
    /// chain of lookups into my private library. Books and sources have no
    /// share path at all and the engine refuses them (`bundle.share_payload`).
    @ViewBuilder
    private var arrangementPicker: some View {
        BandHeader("Add")
        let already = Set(shared.entries.map(\.scoreUid))
        let mine = (state.manifest?.scores ?? [])
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
        if mine.isEmpty {
            PanelNote(text: "Nothing in your library yet.")
                .padding(Theme.Metric.panelPadding)
        }
        ForEach(mine) { score in
            Button {
                add(score)
            } label: {
                HStack {
                    Text(score.name).typeRole(.body).foregroundStyle(Theme.Ink.ink)
                        .lineLimit(1)
                    Spacer(minLength: Theme.Metric.s8)
                    if let uid = score.uid, already.contains(uid) {
                        Text("in the set").typeRole(.meta)
                            .foregroundStyle(Theme.Ink.ink3)
                    }
                }
                .padding(.horizontal, Theme.Metric.s16)
                .frame(minHeight: Theme.Metric.hitTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("shared-candidate-\(score.slug)")
        }
    }

    private func add(_ score: ScoreDoc) {
        Task {
            do {
                // The engine decides what an entry carries, because the engine
                // is what knows which version is pinned and where it lives.
                let payload = try await state.sharePayload(for: score.slug)
                let last = shared.entries.last?.order
                try await shared.addEntry(to: setlistId, payload: payload,
                                          after: last, before: nil)
                adding = false
            } catch {
                state.report("add that arrangement", error)
            }
        }
    }

    // MARK: - whose marks to show

    /// Principle 5's control: everybody's marks, mine only, or one person's.
    ///
    /// It lives on the SET LIST rather than in the score's top bar, and that is
    /// a placement decision rather than a compromise. The bar is width-budgeted
    /// with its own arithmetic and tests, and more to the point "whose cues am I
    /// reading tonight" is a decision about the gig, made once before playing --
    /// not a per-page control. Defaults to everyone's, because seeing what the
    /// band wrote is the reason the set list is shared (§6.3).
    @ViewBuilder
    private var whoseMarks: some View {
        if let setlist, setlist.members.count > 1 {
            BandHeader("Marks to show")
            choice("Everybody's", is: .everyone, identifier: "ink-everyone")
            choice("Only mine", is: .mine, identifier: "ink-mine")
            ForEach(setlist.members.keys.sorted().filter { $0 != signIn.account?.uid },
                    id: \.self) { uid in
                choice("Only \(shortened(uid))", is: .only(uid),
                       identifier: "ink-only-\(uid)")
            }
        }
    }

    private func choice(_ title: String, is value: InkLayers.Visibility,
                        identifier: String) -> some View {
        Button { state.inkVisibility = value } label: {
            HStack {
                Text(title).typeRole(.body).foregroundStyle(Theme.Ink.ink)
                Spacer(minLength: Theme.Metric.s8)
                if state.inkVisibility == value {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Accent.clayStrong)
                }
            }
            .padding(.horizontal, Theme.Metric.s16)
            .frame(minHeight: Theme.Metric.hitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    // MARK: - who is in it

    @ViewBuilder
    private var people: some View {
        if let setlist {
            BandHeader("People")
            ForEach(setlist.members.keys.sorted(), id: \.self) { uid in
                let theirs = SetlistRole(rawValue: setlist.members[uid] ?? "") ?? .reader
                HStack(spacing: Theme.Metric.s12) {
                    // Colour first, because it is how their marks are told
                    // apart on the page (§6.3).
                    Circle()
                        .fill(Color(hex: InkLayers.colour(slot:
                            InkLayers.colourSlot(for: uid,
                                                 participants: Array(setlist.members.keys),
                                                 slots: InkLayers.palette.count))))
                        .frame(width: 12, height: 12)
                    Text(uid == signIn.account?.uid ? "You" : shortened(uid))
                        .typeRole(.body).foregroundStyle(Theme.Ink.ink)
                    Spacer(minLength: Theme.Metric.s8)
                    Text(theirs == .owner ? "made it" : "can add and reorder")
                        .typeRole(.meta).foregroundStyle(Theme.Ink.ink3)
                    if setlist.isOwner && uid != signIn.account?.uid {
                        Button {
                            Task {
                                do { try await shared.removeMember(uid, from: setlistId) }
                                catch { state.report("remove that person", error) }
                            }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.Accent.clayStrong)
                        .accessibilityIdentifier("shared-remove-\(uid)")
                    }
                }
                .padding(.horizontal, Theme.Metric.s16)
                .frame(minHeight: Theme.Metric.hitTarget)
            }
            PanelNote(text: "Up to \(SetlistPermission.membershipCap) people in a "
                      + "set list, owner included. Everybody can add, "
                      + "reorder, invite and mark up, and anybody can take a "
                      + "piece out; only whoever made it can remove people "
                      + "or delete the set list.")
                .padding(Theme.Metric.panelPadding)
        }
    }

    /// Pages of my own markup that are not reaching the band.
    ///
    /// Said, not swallowed. The write to disk already happened, so nothing is
    /// lost -- but a person who has covered a page in cues has to be told it is
    /// only on this iPad, and which page it is (§11.6).
    @ViewBuilder
    private var inkTrouble: some View {
        if !shared.inkPagesOverBudget.isEmpty {
            let pages = shared.inkPagesOverBudget.map { String($0 + 1) }
                .joined(separator: ", ")
            PanelNote(text: "Your markup on page \(pages) is too large to "
                      + "share, so it is on this iPad only. Everything else "
                      + "in this set list is shared normally.")
                .padding(Theme.Metric.panelPadding)
                .accessibilityIdentifier("shared-ink-too-big")
        }
    }

    /// A uid is not a name and this build has no directory of people, so it is
    /// shortened rather than shown whole or invented into a name.
    private func shortened(_ uid: String) -> String {
        uid.count <= 8 ? uid : "Somebody · " + uid.suffix(4)
    }
}
