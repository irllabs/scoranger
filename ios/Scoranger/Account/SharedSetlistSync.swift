import FirebaseCore
import Foundation

/// Every shared set list in the library, kept in step with its Firestore
/// entries in both directions (0.18.0).
///
/// Ali added a tune to "Echo and Bubba" on his iPad and it never reached
/// Echo, who was in the set list. The row had been filled from the server
/// once, when Echo joined, and adding to it from the library wrote only the
/// local document. Now:
///
///   - a change to a shared row HERE -- an arrangement added, taken out or
///     moved, by any path: the library, the set list screen, chat -- is seen
///     as a change to the manifest and goes up;
///   - a change THERE comes down through an entries listener on each shared
///     set list, while the app is open;
///   - launch, return to the app, and the row's Sync button run the same
///     sync on demand.
///
/// What to do is `SetlistSync.plan`, which is pure and tested. This carries
/// it out, and records what the row held when it was last in step (`Bases`)
/// so the next plan can tell a removal made here from an addition made
/// elsewhere.
///
/// Inert while signed out, like `LibrarySync`: `follow(account:)` starts it.
@MainActor
final class SharedSetlistSync: ObservableObject {

    /// How each shared row stands, by share id, for the row's Sync button.
    @Published private(set) var status: [String: SetlistSync.Status] = [:]

    private weak var state: AppState?
    private weak var shared: SharedSetlists?
    private var account: String?
    private let bases = Bases()

    /// The row as this device last left it, by share id. A manifest change
    /// that leaves a shared row as it was is not a change to that row.
    private var leftAt: [String: [String]] = [:]
    private var running: Set<String> = []
    /// Asked for again while running: one more sync follows this one.
    private var queued: Set<String> = []
    private var debounce: [String: Task<Void, Never>] = [:]

    func attach(_ state: AppState, _ shared: SharedSetlists) {
        self.state = state
        self.shared = shared
    }

    /// Start or stop with the account. The account is taken only once every
    /// precondition holds -- `LibrarySync.follow` says why: Firestore raises
    /// an Objective-C exception when Firebase is not configured, and the UI
    /// tests' pretend account never configures it.
    func follow(account uid: String?) {
        guard uid != account else { return }
        account = nil
        shared?.stopWatchingEntries()
        debounce.values.forEach { $0.cancel() }
        debounce = [:]
        leftAt = [:]
        status = [:]
        guard let uid, SignIn.pretendedAccount == nil, FirebaseApp.app() != nil,
              state?.useLocalEngine == true else { return }
        account = uid
        libraryChanged()
    }

    /// The library changed: watch every shared row, and sync any whose
    /// arrangements are not as this device last left them.
    func libraryChanged() {
        guard account != nil, let state, let shared else { return }
        let rows = (state.manifest?.setlists ?? []).filter(\.isShared)
        let ids = Set(rows.compactMap(\.shareId))
        shared.watchEntries(of: ids) { [weak self] id in
            self?.request(id, after: .zero)
        }
        for id in status.keys where !ids.contains(id) { status[id] = nil }
        for row in rows {
            guard let id = row.shareId, leftAt[id] != row.arrangements else { continue }
            // A moment's grace, so a burst of edits -- a reorder is several
            // writes -- goes up as one sync.
            request(id, after: .milliseconds(800))
        }
    }

    /// Every shared row, now: on return to the app.
    func syncAll() {
        guard account != nil, let state else { return }
        for row in (state.manifest?.setlists ?? []) {
            if let id = row.shareId { request(id, after: .zero) }
        }
    }

    /// The row's Sync button.
    ///
    /// Signed out it says so on the button rather than doing nothing: a
    /// joined row stays in the library after its reader signs out.
    func syncNow(_ shareId: String) {
        guard account != nil else {
            status[shareId] = .trouble(SharedSetlists.Trouble.signedOut.localizedDescription)
            return
        }
        request(shareId, after: .zero)
    }

    func rowStatus(_ setlist: SetlistDoc) -> SetlistSync.Status {
        guard let id = setlist.shareId else { return .unknown }
        return status[id] ?? .unknown
    }

    // MARK: - running one

    private func request(_ shareId: String, after delay: Duration) {
        debounce[shareId]?.cancel()
        debounce[shareId] = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            // Its own task, so a later request cancelling this one's WAIT
            // cannot cancel a sync half way through its writes.
            Task { await self?.run(shareId) }
        }
    }

    /// One sync per set list at a time; a request during one runs once more
    /// after it, against entries read then.
    private func run(_ shareId: String) async {
        if running.contains(shareId) { queued.insert(shareId); return }
        running.insert(shareId)
        repeat {
            queued.remove(shareId)
            await once(shareId)
        } while queued.contains(shareId)
        running.remove(shareId)
    }

    private func once(_ shareId: String) async {
        guard account != nil, let state, let shared,
              let row = state.manifest?.setlists?.first(where: { $0.shareId == shareId })
        else { return }
        status[shareId] = .syncing
        do {
            let remote = try await shared.fetchAllEntries(shareId)
            let scores = Dictionary((state.manifest?.scores ?? []).map { ($0.slug, $0) },
                                    uniquingKeysWith: { a, _ in a })
            let local = row.arrangements.map { slug in
                SetlistSync.Local(slug: slug, uid: scores[slug]?.uid,
                                  sharedEntry: scores[slug]?.sharedEntry)
            }
            let server = remote.map {
                SetlistSync.Remote(id: $0.id, order: $0.order, scoreUid: $0.scoreUid,
                                   isRemoved: $0.isRemoved)
            }
            var copies: [String: String] = [:]
            for entry in remote {
                if let slug = state.sharedCopies.localSlug(forEntry: entry.id) {
                    copies[entry.id] = slug
                }
            }
            let plan = SetlistSync.plan(local: local, remote: server,
                                        base: bases.base(for: shareId),
                                        copies: copies, mayEdit: mayEdit(row, shareId))
            let links = SetlistSync.links(local: local, remote: server, copies: copies)
            let byId = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

            // Down: what the band added, through the ordinary import. A copy
            // that fails to arrive is reported by `adoptSharedEntry` and left
            // out of the base, so the next sync tries it again.
            var adopted: [String: String] = [:]
            for id in plan.adopt {
                guard let entry = byId[id] else { continue }
                // One of this account's own arrangements, added from its other
                // device: the library holds it already, by the same uid, and
                // a copy beside it would be a second arrangement for one tune.
                if let own = state.manifest?.scores.first(where: {
                    $0.uid != nil && $0.uid == entry.scoreUid }) {
                    adopted[id] = own.slug
                    continue
                }
                if let slug = await state.adoptSharedEntry(
                    id, title: entry.title, download: { try await shared.download(entry) }) {
                    adopted[id] = slug
                }
            }

            // Up: what this reader added, took out and moved.
            var pushed: [String: String] = [:]
            for (slug, key) in zip(plan.push, plan.pushKeys) {
                let payload = try await state.sharePayload(for: slug)
                pushed[slug] = try await shared.addEntry(to: shareId, payload: payload,
                                                         orderKey: key)
            }
            for id in plan.withdraw { try await shared.withdraw(id, in: shareId) }
            for (id, key) in plan.moves { try await shared.setOrder(key, entry: id, in: shareId) }

            // The row, in the order the plan settled on.
            var slugs: [String] = []
            var held: [String] = []
            for item in plan.order {
                switch item {
                case .local(let slug):
                    guard !slugs.contains(slug) else { continue }
                    slugs.append(slug)
                    if let id = pushed[slug] ?? links[slug] { held.append(id) }
                case .adopt(let id):
                    guard let slug = adopted[id], !slugs.contains(slug) else { continue }
                    slugs.append(slug)
                    held.append(id)
                }
            }
            try await setRow(row.slug, shareId, to: slugs, from: row.arrangements)
            bases.set(held, for: shareId)
            leftAt[shareId] = slugs
            status[shareId] = .inStep
            print("SCORANGER-SETLIST-SYNC \(shareId) in step: \(slugs.count) in the row; "
                  + "adopted \(adopted.count), pushed \(pushed.count), "
                  + "withdrew \(plan.withdraw.count), moved \(plan.moves.count), "
                  + "dropped \(plan.dropLocally.count)")
        } catch {
            status[shareId] = .trouble(error.localizedDescription)
            print("SCORANGER-SETLIST-SYNC \(shareId) failed: \(error.localizedDescription)")
        }
    }

    /// Whether this reader may change the shared entries. The role from the
    /// memberships listener when it has answered; until then the local row's
    /// owner field, which is enough, since a reader is not yet issued and
    /// the security rules refuse a reader's write whatever this says.
    private func mayEdit(_ row: SetlistDoc, _ shareId: String) -> Bool {
        let role: SetlistRole
        if let known = shared?.setlists.first(where: { $0.id == shareId })?.role {
            role = known
        } else {
            role = row.ownerUid == nil || row.ownerUid == account ? .owner : .member
        }
        return SetlistPermission.allows(role, .addEntry)
    }

    /// Write the row: out, in, then the order. Three engine ops the library
    /// already uses, called directly so a sync's own writes are not mistaken
    /// for a reader's edits -- `leftAt` records them before the manifest
    /// change that follows arrives.
    private func setRow(_ setlist: String, _ shareId: String, to slugs: [String],
                        from current: [String]) async throws {
        guard let state, slugs != current else { return }
        leftAt[shareId] = slugs
        for slug in current where !slugs.contains(slug) {
            _ = try await state.local.call(op: "unassign-setlist",
                                           args: ["setlist": setlist, "score": slug])
        }
        for slug in slugs where !current.contains(slug) {
            _ = try await state.local.call(op: "assign-setlist",
                                           args: ["setlist": setlist, "score": slug])
        }
        _ = try await state.local.call(op: "reorder-setlist",
                                       args: ["setlist": setlist, "order": slugs])
        await state.refresh()
    }

    /// The entry ids each shared row held when this device last brought it
    /// into step: the third side of `SetlistSync.plan`'s merge.
    ///
    /// Device-local, like `SharedEntryCopies`. Losing it costs one sync that
    /// only adds, which is what a first sync does anyway.
    struct Bases {
        private let defaults: UserDefaults
        private static let prefix = "shared-setlist-base."

        init(defaults: UserDefaults = .standard) {
            self.defaults = defaults
        }

        func base(for shareId: String) -> [String]? {
            defaults.stringArray(forKey: Self.prefix + shareId)
        }

        func set(_ ids: [String], for shareId: String) {
            defaults.set(ids, forKey: Self.prefix + shareId)
        }
    }
}
