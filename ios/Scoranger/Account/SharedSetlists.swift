import CoreGraphics
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import FirebaseFunctions
import FirebaseStorage
import Foundation

/// Setlists several people can open, add to and mark up.
///
/// design/FIREBASE.md §6, and the goal the whole integration exists for
/// (principle 2 of §0): *"SHARED PLAYLISTS (setlists) where anyone in the
/// playlist can ADD arrangements and REORDER them."*
///
/// **This is a cloud-authority system cached locally, and the library is the
/// opposite** (§4.4). Your own library is editable offline forever; a shared
/// setlist you cannot reach is read-only until you can, and says so. They are
/// different animals and this type does not pretend otherwise.
///
/// Everything it decides was decided already and is tested elsewhere:
/// `SetlistPermission` for who may do what, `SharedOrder` for the running
/// order, `InkLayers` for whose marks are drawn, `SetlistInvite` for who may
/// join. This is the wiring, and the security rules are what actually enforce
/// any of it.
@MainActor
final class SharedSetlists: ObservableObject {

    /// Who is signed in, or nil.
    ///
    /// **The `FirebaseApp` guard is not defensive, it is load-bearing.**
    /// `Auth.auth()` TRAPS when no app has been configured -- it does not
    /// return nil and it does not throw -- and in this app nothing configures
    /// Firebase until somebody presses a sign-in button (§0.2). So every path
    /// that asks who is signed in has to be safe to ask before anyone ever
    /// has, and the only thing standing between that and a crash on a
    /// signed-out launch would otherwise be the order the views happen to
    /// render in.
    /// `nonisolated` because `Setlist` is a value type read from wherever it
    /// happens to be held, and Firebase Auth's own cached user is safe to read
    /// off any thread. Isolating it to the main actor made a struct's computed
    /// `isOwner` uncallable, which is where it is most needed.
    nonisolated static var currentUid: String? {
        // The fixture's uid, when there is one. It has to answer HERE and not
        // only in `SignIn`, because `Setlist.isOwner` is computed off this --
        // and a fixture whose set lists all read as somebody else's would
        // photograph the wrong half of the account-deletion confirm.
        if let pretend = SignIn.pretendedAccount { return pretend.uid }
        guard FirebaseApp.app() != nil else { return nil }
        return Auth.auth().currentUser?.uid
    }

    /// Shared set lists with no Firebase behind them, for tests and for
    /// photographs. Nil in every shipped run -- see `SignIn.pretendedAccount`.
    ///
    /// Three, deliberately, and one of each fate: one this account owns with
    /// other people in it (handed on), one it owns alone (deleted with the
    /// account), and one belonging to somebody else (left). That is the whole
    /// of §6.6 on one screen, which is what the confirm has to be able to say.
    nonisolated static var pretendedSetlists: [Setlist]? {
        guard let me = SignIn.pretendedAccount?.uid else { return nil }
        return [
            Setlist(id: "s-friday", name: "Friday at the Bell", ownerId: me,
                    members: [me: "owner", "u-2": "member", "u-3": "member"]),
            Setlist(id: "s-practice", name: "Practice", ownerId: me,
                    members: [me: "owner"]),
            Setlist(id: "s-quintet", name: "The quintet's book", ownerId: "u-9",
                    members: ["u-9": "owner", me: "member"]),
        ]
    }

    struct Setlist: Identifiable, Equatable {
        let id: String
        let name: String
        let ownerId: String
        let members: [String: String]
        var role: SetlistRole? {
            guard let uid = SharedSetlists.currentUid,
                  let raw = members[uid] else { return nil }
            return SetlistRole(rawValue: raw)
        }
        var isOwner: Bool {
            guard let uid = SharedSetlists.currentUid else { return false }
            return ownerId == uid
        }
    }

    struct Entry: Identifiable, Equatable {
        let id: String
        let title: String
        let composer: String?
        /// The fractional index. Sorting on this IS the running order (§6.5).
        let order: String
        let scoreUid: String
        let versionUid: String
        let storagePath: String?
        let addedBy: String
        /// Soft removal keeps the ink and can be undone (§6.2).
        let removedAt: Timestamp?
        var isRemoved: Bool { removedAt != nil }
    }

    @Published private(set) var setlists: [Setlist] = []
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var trouble: String?
    /// True while offline and showing a cached setlist. §5.3: reordering and
    /// adding are DISABLED with the reason shown, never a silent no-op.
    @Published private(set) var isStale = false

    /// The band's markup for the entry currently OPEN, by user and page, plus
    /// the page width each person drew at.
    @Published private(set) var ink: [String: [Int: Data]] = [:]
    @Published private(set) var inkWidths: [String: CGFloat] = [:]
    /// Pages of my own layer that will not fit in one Firestore document, so
    /// the screen can say which rather than losing them quietly.
    @Published private(set) var inkPagesOverBudget: [Int] = []

    private var setlistsListener: ListenerRegistration?
    private var entriesListener: ListenerRegistration?
    private var inkListener: ListenerRegistration?
    /// Which entry's ink is open, so a save can be pushed to the right place.
    private var openEntry: (setlist: String, entry: String)?
    /// Whose memberships the listener is watching, so a repeated `onAppear`
    /// does not pay for the query again.
    private var watchingFor: String?

    private var db: Firestore { Firestore.firestore() }
    private var storage: Storage { Storage.storage() }
    private var functions: Functions { Functions.functions(region: "us-west1") }
    private var uid: String? { Self.currentUid }

    // MARK: - what I am in

    /// Watch the flat index, not the setlists.
    ///
    /// "What setlists am I in" is one indexed query on `userId` because RULES
    /// ARE NOT FILTERS (§10.1): a query is all or nothing, so it must carry the
    /// same constraint the rule enforces. Listing `setlists` is refused
    /// outright by the deployed rules, and this is why.
    func watchMemberships() {
        // Test fixture, before the guard below: under `-pretendSignedIn` there
        // is no Firebase to listen to, and a confirm that has to name the set
        // lists it is about to destroy needs some to name.
        if let pretend = Self.pretendedSetlists { setlists = pretend; return }
        guard let uid else { return }   // nil until Firebase is up, by design
        // Already watching is not a reason to watch again. `onAppear` fires
        // every time the library's set-list segment comes back, and a listener
        // torn down and re-established is billed as a brand-new query (§5.1) --
        // which for an app whose whole point is working offline is the cost
        // that matters.
        guard setlistsListener == nil || watchingFor != uid else { return }
        watchingFor = uid
        setlistsListener?.remove()
        setlistsListener = db.collection("memberships")
            .whereField("userId", isEqualTo: uid)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }
                if let error { self.trouble = error.localizedDescription; return }
                let ids = snapshot?.documents.compactMap {
                    $0.data()["setlistId"] as? String
                } ?? []
                Task { await self.loadSetlists(ids) }
            }
    }

    /// Signing out stops everything and forgets everything.
    ///
    /// Not tidiness: without it the memberships listener outlives the account
    /// it was opened for. It keeps billing, and it keeps publishing the
    /// previous person's set lists into `setlists` -- so the next reader of
    /// this iPad, signed in as themselves or not at all, would be shown
    /// somebody else's shared music. `Setlist.role` would return nil for them
    /// and the rows would be unopenable, which is the failure looking like a
    /// bug instead of like a leak.
    func signedOut() {
        setlistsListener?.remove(); setlistsListener = nil
        entriesListener?.remove(); entriesListener = nil
        inkListener?.remove(); inkListener = nil
        stopWatchingEntries()
        watchingFor = nil
        openEntry = nil
        setlists = []
        entries = []
        ink = [:]
        inkWidths = [:]
        inkPagesOverBudget = []
        isStale = false
        trouble = nil
    }

    private func loadSetlists(_ ids: [String]) async {
        var found: [Setlist] = []
        for id in ids {
            // One document each, by id. Deliberately not a query: the rule
            // reads the membership map off the document in hand, which is the
            // one lookup §4.2 is built around.
            guard let snapshot = try? await db.collection("setlists").document(id).getDocument(),
                  let data = snapshot.data() else { continue }
            found.append(Setlist(id: id,
                                 name: data["name"] as? String ?? "Untitled",
                                 ownerId: data["ownerId"] as? String ?? "",
                                 members: data["members"] as? [String: String] ?? [:]))
        }
        setlists = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - one-shot reads, for joining

    /// One set list, read ONCE.
    ///
    /// Joining needs the document's name and owner to write the local row
    /// (§6A.5) and has no use for a listener it would immediately drop. The
    /// same decode as `loadSetlists`, and a missing document is an error here
    /// rather than a skipped row: the person just claimed an invitation to it.
    func fetch(_ setlistId: String) async throws -> Setlist {
        guard FirebaseApp.app() != nil else { throw Trouble.signedOut }
        let snapshot = try await db.collection("setlists").document(setlistId).getDocument()
        guard let data = snapshot.data() else { throw Trouble.unusablePayload }
        return Setlist(id: setlistId,
                       name: data["name"] as? String ?? "Untitled",
                       ownerId: data["ownerId"] as? String ?? "",
                       members: data["members"] as? [String: String] ?? [:])
    }

    /// Its entries, read once, in running order, without the removed ones.
    /// The same decode and the same sort as the listener in `open(_:)`.
    func fetchEntries(_ setlistId: String) async throws -> [Entry] {
        try await fetchAllEntries(setlistId)
            .filter { !$0.isRemoved }
            .sorted { $0.order < $1.order }
    }

    /// Every entry, the removed ones included: to keep a row in step, a
    /// removal is news (`SetlistSync`).
    func fetchAllEntries(_ setlistId: String) async throws -> [Entry] {
        guard FirebaseApp.app() != nil else { throw Trouble.signedOut }
        let snapshot = try await db.collection("setlists").document(setlistId)
            .collection("entries").getDocuments()
        return snapshot.documents.map(Self.entry)
    }

    nonisolated private static func entry(_ document: QueryDocumentSnapshot) -> Entry {
        let data = document.data()
        return Entry(id: document.documentID,
                     title: data["title"] as? String ?? "Untitled",
                     composer: data["composer"] as? String,
                     order: data["order"] as? String ?? "",
                     scoreUid: data["scoreUid"] as? String ?? "",
                     versionUid: data["versionUid"] as? String ?? "",
                     storagePath: data["storagePath"] as? String,
                     addedBy: data["addedBy"] as? String ?? "",
                     removedAt: data["removedAt"] as? Timestamp)
    }

    // MARK: - every shared row, kept in step

    /// One entries listener per shared set list in the library, not only the
    /// one open on the shared screen. A member's addition has to reach every
    /// other member's row without anybody opening anything -- Ali added a
    /// tune to "Echo and Bubba" and it never reached Echo.
    ///
    /// The same `setlists/{id}/entries` listen the shared screen opens, which
    /// the deployed rules already allow a member: no new rule, no new query.
    ///
    /// It says only WHICH set list changed. The sync reads the entries afresh
    /// rather than planning from the snapshot: on the emulators a snapshot
    /// taken partway through a sync's own uploads was planned from after it,
    /// and the half not yet in it was pushed a second time.
    private var rowListeners: [String: ListenerRegistration] = [:]

    func watchEntries(of setlistIds: Set<String>,
                      onChange: @escaping @MainActor (String) -> Void) {
        guard FirebaseApp.app() != nil, uid != nil else { return }
        for (id, listener) in rowListeners where !setlistIds.contains(id) {
            listener.remove()
            rowListeners[id] = nil
        }
        for id in setlistIds where rowListeners[id] == nil {
            rowListeners[id] = db.collection("setlists").document(id)
                .collection("entries")
                .addSnapshotListener { snapshot, error in
                    // A listener refused (the reader left, or was removed) or
                    // a write of this device's own not yet acknowledged: in
                    // neither case is there anything new from the band.
                    guard error == nil, let snapshot,
                          !snapshot.metadata.hasPendingWrites else { return }
                    Task { @MainActor in onChange(id) }
                }
        }
    }

    func stopWatchingEntries() {
        rowListeners.values.forEach { $0.remove() }
        rowListeners = [:]
    }

    /// Give an entry a new place in the running order.
    func setOrder(_ key: String, entry entryId: String, in setlistId: String) async throws {
        try await db.collection("setlists").document(setlistId)
            .collection("entries").document(entryId)
            .updateData(["order": key])
    }

    /// Soft-remove an entry by id: the same write as `remove(_:in:)`.
    func withdraw(_ entryId: String, in setlistId: String) async throws {
        guard let uid else { throw Trouble.signedOut }
        try await db.collection("setlists").document(setlistId)
            .collection("entries").document(entryId)
            .updateData(["removedAt": FieldValue.serverTimestamp(), "removedBy": uid])
    }

    /// The setlist being read, watched as ITS OWN DOCUMENT.
    ///
    /// **Not derived from `setlists`, and that is the fix.** The screen used to
    /// find its setlist in the memberships-driven list, so anything that left
    /// that list empty -- a missing index row, or simply the listener not
    /// having answered yet -- made the setlist `nil`, the role fall back to
    /// `.reader`, and the owner see a single red "Leave this set list". The
    /// list is a list; ownership is a property of the document, and it is read
    /// from the document.
    @Published private(set) var open: Setlist?
    /// Nil while nothing has answered yet. The screen renders LOADING on nil
    /// rather than picking the least-privileged reading -- a permissions
    /// fallback that shows fewer controls looks like a considered answer and
    /// is really just ignorance.
    @Published private(set) var openRole: SetlistRole?
    private var openListener: ListenerRegistration?

    /// Watch one setlist document: its name, its members, and my role in it.
    func openSetlist(_ setlistId: String) {
        guard FirebaseApp.app() != nil, let uid else { return }
        openListener?.remove()
        open = nil
        openRole = nil
        openListener = db.collection("setlists").document(setlistId)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }
                if let error { self.trouble = error.localizedDescription; return }
                guard let data = snapshot?.data() else {
                    // The document is genuinely not there -- deleted, or never
                    // promoted. Distinct from "not answered yet", and the
                    // screen says so instead of showing a reader's view.
                    self.open = nil
                    self.openRole = nil
                    return
                }
                let members = data["members"] as? [String: String] ?? [:]
                let ownerId = data["ownerId"] as? String ?? ""
                self.open = Setlist(id: setlistId,
                                    name: data["name"] as? String ?? "Untitled",
                                    ownerId: ownerId,
                                    members: members)
                // OWNERSHIP FROM ownerId FIRST. The members map and ownerId
                // are written together, but if they ever disagree the owner
                // field is the one the security rules use to decide who may
                // delete -- so it is the one the UI must agree with.
                if ownerId == uid {
                    self.openRole = .owner
                } else if let raw = members[uid] {
                    self.openRole = SetlistRole(rawValue: raw)
                } else {
                    self.openRole = nil     // not a member: not a reader
                }
            }
    }

    func closeSetlist() {
        openListener?.remove()
        openListener = nil
        open = nil
        openRole = nil
    }

    // MARK: - one setlist, live

    /// A snapshot listener on the setlist that is OPEN, and nothing else.
    ///
    /// §5.1: a listener disconnected for more than thirty minutes is billed as
    /// a brand-new query, which for an app designed to be offline is the
    /// dominant cost. This one is small, genuinely live, and open for minutes
    /// rather than days. The library is never listened to.
    func open(_ setlistId: String) {
        guard FirebaseApp.app() != nil else { return }
        entriesListener?.remove()
        entriesListener = db.collection("setlists").document(setlistId)
            .collection("entries")
            .addSnapshotListener(includeMetadataChanges: true) { [weak self] snapshot, error in
                guard let self else { return }
                if let error { self.trouble = error.localizedDescription; return }
                self.isStale = snapshot?.metadata.isFromCache ?? false
                self.entries = (snapshot?.documents ?? []).map(Self.entry)
                // The order is the KEY, sorted here. Sorting server-side would
                // need an index and buy nothing at a dozen entries.
                .filter { !$0.isRemoved }
                .sorted { $0.order < $1.order }
            }
    }

    func close() {
        entriesListener?.remove()
        entriesListener = nil
        entries = []
        isStale = false
    }

    // MARK: - making one

    /// Share a local set list: promote it in place.
    ///
    /// Through the Function, because the two writes it makes -- the setlist
    /// document and the `memberships` index -- cannot both be done by a
    /// client. The rules refuse every client write to `memberships`, so the
    /// old client-side `create` produced a setlist whose own owner could not
    /// see it. That is the bug behind both of Ali's screenshots.
    ///
    /// Takes the set list's OWN uid, so this promotes rather than copies:
    /// afterwards it is the same set list, in the same list, with members.
    @discardableResult
    func share(setlistId: String, named name: String) async throws -> SetlistRole {
        guard uid != nil else { throw Trouble.signedOut }
        let result = try await functions.httpsCallable("shareSetlist")
            .call(["setlistId": setlistId, "name": name])
        guard let data = result.data as? [String: Any],
              let raw = data["role"] as? String,
              let role = SetlistRole(rawValue: raw) else {
            throw Trouble.unusablePayload
        }
        return role
    }

    /// Promote a local set list into a shared one, in place, and return the
    /// link to send.
    ///
    /// §6A.1's four steps, in this order for a reason:
    ///
    ///   1. the Firestore document, via `shareSetlist` -- which writes the
    ///      membership index in the same transaction, so the owner can never
    ///      exist without it (the bug behind both of Ali's screenshots);
    ///   2. an entry per arrangement, pinned at its CURRENT LATEST version,
    ///      with a fractional index preserving the local order;
    ///   3. the artifacts those entries name, uploaded;
    ///   4. `shareId` written back to the local document -- LAST, so a set
    ///      list is never marked shared before it is. A `shareId` pointing at
    ///      nothing claims a collaboration that does not exist, and recovering
    ///      from that is worse than retrying a share.
    ///
    /// `progress` reports how far along the uploads are, because on a
    /// twenty-piece set list this is a real wait and a share button that
    /// appears to do nothing is how the last three builds felt.
    func promote(setlist: SetlistDoc, arrangements: [ScoreDoc],
                 payload: (String) async throws -> [String: Any],
                 bind: (String, String) async throws -> Void,
                 progress: @MainActor (Int, Int) -> Void = { _, _ in }) async throws -> URL {
        guard let uid else { throw Trouble.signedOut }
        let shareId = setlist.sharedId

        // 1. the document and the owner's index row, transactionally
        _ = try await share(setlistId: shareId, named: setlist.name)

        // 2 + 3. one entry per arrangement, in the local order
        let ordered = setlist.arrangements.compactMap { slug in
            arrangements.first { $0.slug == slug }
        }
        let keys = SharedOrder.spread(count: max(ordered.count, 1))
        for (index, score) in ordered.enumerated() {
            progress(index, ordered.count)
            // The engine decides what an entry carries, because it is what
            // knows which version is pinned and where its file is. Asking it
            // per arrangement pins each at whatever is latest RIGHT NOW,
            // which is §6.1's rule and the sub-decision confirmed for 6A.
            let described = try await payload(score.slug)
            try await addEntry(to: shareId, payload: described,
                               orderKey: keys[min(index, keys.count - 1)])
        }
        progress(ordered.count, ordered.count)

        // 4. bind the local row LAST
        try await bind(shareId, uid)

        // and the link to send: https, so Messages and Mail make it tappable
        let inviteId = try await invite(to: shareId, email: nil)
        guard let url = SharedInviteLink.webURL(inviteId: inviteId) else {
            throw Trouble.unusablePayload
        }
        return url
    }

    /// Mint an invitation. `email` nil means an OPEN link, when that is the
    /// rule in force; the Function records which rule the invitation carries.
    func invite(to setlistId: String, email: String?) async throws -> String {
        guard uid != nil else { throw Trouble.signedOut }
        var args: [String: Any] = ["setlistId": setlistId,
                                   "claim": email == nil ? "open" : "address"]
        if let email { args["email"] = SetlistInvite.normalise(email) }
        let result = try await functions.httpsCallable("createInvite").call(args)
        guard let data = result.data as? [String: Any],
              let id = data["inviteId"] as? String else {
            throw Trouble.unusablePayload
        }
        return id
    }

    /// Delete the whole setlist. The owner's alone -- the one act that destroys
    /// everybody's work at once (principle 4).
    func delete(_ setlist: Setlist) async throws {
        guard setlist.isOwner else { throw Trouble.notYours }
        try await db.collection("setlists").document(setlist.id).delete()
    }

    // MARK: - adding an arrangement

    /// Copy an arrangement of mine into a shared setlist.
    ///
    /// A COPY, not a reference (§4.3, and §12.13 as the owner settled it: his
    /// own purchased material shares as the real thing, to named people, capped
    /// at twelve). The bytes go to `shared/{setlistId}/{entryId}/` so a
    /// member's read permission is a property of the PATH and authorising it is
    /// one Firestore lookup -- not a chain into somebody's private library.
    ///
    /// The engine says what the entry carries (`share-payload`), because the
    /// engine is what knows which version is pinned.
    /// Promotion's form: the order key is computed for the whole list at once
    /// by `SharedOrder.spread`, so the entries keep the local order instead of
    /// each being appended relative to the last.
    @discardableResult
    func addEntry(to setlistId: String, payload: [String: Any],
                  orderKey: String) async throws -> String {
        try await addEntry(to: setlistId, payload: payload,
                           explicitOrder: orderKey)
    }

    @discardableResult
    func addEntry(to setlistId: String, payload: [String: Any],
                  after previous: String?, before next: String?) async throws -> String {
        try await addEntry(to: setlistId, payload: payload,
                           explicitOrder: SharedOrder.between(previous, next))
    }

    private func addEntry(to setlistId: String, payload: [String: Any],
                          explicitOrder: String) async throws -> String {
        guard let uid else { throw Trouble.signedOut }
        // The title is guarded with the other three, and that is the fix for a
        // real defect: it alone had a `?? "Untitled"` on it, so a payload that
        // could not name the music uploaded a placeholder to everybody in the
        // set list instead of failing. Echo opened Ali's set list and found a
        // piece called Untitled where Morrison's Jig should have been.
        // `bundle.share_payload` now walks title -> name -> piece -> slug and
        // refuses rather than returning nothing, so reaching this guard means
        // a bug worth hearing about rather than a row worth shipping.
        guard let localPath = payload["path"] as? String,
              let scoreUid = payload["scoreUid"] as? String,
              let versionUid = payload["versionUid"] as? String,
              let title = (payload["title"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            throw Trouble.unusablePayload
        }
        let entries = db.collection("setlists").document(setlistId).collection("entries")
        let entry = entries.document()

        // Uploaded BEFORE the document is written. A row pointing at bytes that
        // are not there yet is an entry that opens as a blank page, and the
        // reader cannot tell that from a broken one.
        let kind = payload["kind"] as? String ?? "notation"
        let name = kind == "pdf" ? "\(versionUid).pdf" : "\(versionUid).musicxml"
        let path = "shared/\(setlistId)/\(entry.documentID)/\(name)"
        _ = try await storage.reference(withPath: path)
            .putFileAsync(from: URL(fileURLWithPath: localPath))

        try await entry.setData([
            "title": title,
            "composer": payload["composer"] as? String as Any,
            "order": explicitOrder,
            "scoreUid": scoreUid,
            "versionUid": versionUid,
            "versionLabel": payload["versionLabel"] as? String as Any,
            "mode": "copy",
            "provenance": payload["provenance"] as? String ?? "unknown",
            "storagePath": path,
            "bytes": payload["bytes"] as? Int ?? 0,
            "sha256": payload["sha256"] as? String as Any,
            "addedBy": uid,
            "addedAt": FieldValue.serverTimestamp(),
        ])
        return entry.documentID
    }

    /// Move one entry. A one-field write to one document, which is what lets
    /// two people reorder at once without either losing a move (§6.5).
    ///
    /// Takes the neighbouring KEYS rather than the neighbouring entries, because
    /// which keys those are is a decision (`SharedOrder.neighbours`) and it is
    /// made and tested there.
    func move(_ entry: Entry, afterKey previous: String?, beforeKey next: String?,
              in setlistId: String) async throws {
        try await db.collection("setlists").document(setlistId)
            .collection("entries").document(entry.id)
            .updateData(["order": SharedOrder.between(previous, next)])
    }

    /// Soft, attributed, and undoable. Removing an entry never destroys ink.
    func remove(_ entry: Entry, in setlistId: String) async throws {
        guard let uid else { throw Trouble.signedOut }
        try await db.collection("setlists").document(setlistId)
            .collection("entries").document(entry.id)
            .updateData(["removedAt": FieldValue.serverTimestamp(), "removedBy": uid])
    }

    // MARK: - people

    /// Invite by email. Any member may (principle 4).
    ///
    /// The invite is a document addressed to an ADDRESS, because at a rehearsal
    /// "wait until your bandmate has signed up" is not a workable flow (§4.2).
    /// It carries the setlist's name and nothing else: the rules name the five
    /// allowed fields, so it cannot become a read grant.
    /// Returns the invitation's id, which is what the inviter has to send:
    /// the rules refuse `list` on `invites/`, so an invitee cannot find their
    /// own (`SharedInviteLink`).
    @discardableResult
    func invite(_ email: String, to setlist: Setlist) async throws -> String {
        guard let uid else { throw Trouble.signedOut }
        guard SetlistPermission.mayAdmit(currentCount: setlist.members.count) else {
            throw Trouble.full
        }
        let reference = db.collection("invites").document()
        try await reference.setData([
            "setlistId": setlist.id,
            "setlistName": setlist.name,
            "emailLower": SetlistInvite.normalise(email),
            "invitedBy": uid,
            "invitedAt": FieldValue.serverTimestamp(),
        ])
        return reference.documentID
    }

    /// Claim an invitation. Through the Function, because the rules refuse
    /// every client write to the membership map -- a client that could edit
    /// `members` could make itself the owner (§4.4, §12.11).
    func claim(inviteId: String) async throws -> String {
        let result = try await functions.httpsCallable("claimInvite")
            .call(["inviteId": inviteId])
        guard let data = result.data as? [String: Any],
              let setlistId = data["setlistId"] as? String else {
            throw Trouble.unusablePayload
        }
        return setlistId
    }

    func removeMember(_ userId: String, from setlistId: String) async throws {
        _ = try await functions.httpsCallable("removeMember")
            .call(["setlistId": setlistId, "userId": userId])
    }

    // MARK: - markup

    /// One page of my own layer. Nobody ever writes anybody else's, which is
    /// what makes the ink conflict-free with no merge function (§6.3).
    ///
    /// `pageWidth` is the width the canvas was laid out at, in points, and it
    /// is not optional in practice: a `PKDrawing`'s coordinates are in that
    /// space, so a layer without it cannot be placed correctly on a device
    /// with a differently sized page (`SharedInk.scale`).
    ///
    /// Merged, one page at a time, so writing page 4 does not have to send
    /// pages 1 to 3 back -- and so two of my own devices writing different
    /// pages of the same layer do not overwrite each other.
    func writeInk(_ data: Data, entry: String, page: Int,
                  pageWidth: CGFloat, in setlistId: String) async throws {
        guard let uid else { throw Trouble.signedOut }
        try await db.collection("setlists").document(setlistId)
            .collection("entries").document(entry)
            .collection("ink").document(uid)
            .setData(["layer": "personal",
                      "pageWidth": Double(pageWidth),
                      "updatedAt": FieldValue.serverTimestamp(),
                      "pages": [String(page): data]], merge: true)
    }

    /// Everybody's layers for one entry: the pages, and the page width each
    /// person's ink was drawn at.
    func readInk(entry: String, in setlistId: String) async throws
        -> (pages: [String: [Int: Data]], widths: [String: CGFloat]) {
        let snapshot = try await db.collection("setlists").document(setlistId)
            .collection("entries").document(entry).collection("ink").getDocuments()
        var layers: [String: [Int: Data]] = [:]
        var widths: [String: CGFloat] = [:]
        for document in snapshot.documents {
            let data = document.data()
            layers[document.documentID] =
                SharedInk.decode(data["pages"] as? [String: Any] ?? [:])
            if let width = data["pageWidth"] as? Double, width > 0 {
                widths[document.documentID] = CGFloat(width)
            }
        }
        return (layers, widths)
    }

    /// Fetch an entry's music to a local file, once.
    func download(_ entry: Entry) async throws -> URL {
        guard let path = entry.storagePath else { throw Trouble.unusablePayload }
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "shared", directoryHint: .isDirectory)
            .appending(path: "\(entry.id)-\(URL(fileURLWithPath: path).lastPathComponent)")
        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        _ = try await storage.reference(withPath: path).writeAsync(toFile: destination)
        return destination
    }

    // MARK: - the band's markup, live

    /// Watch everybody's layers for one entry, and push mine as it is drawn.
    ///
    /// Both directions are set up together on purpose: an overlay showing the
    /// band's marks while mine never leave this device is worse than no
    /// sharing at all, because it looks like it is working.
    ///
    /// `pageWidth` is what a `PKDrawing`'s coordinates mean here, and it goes
    /// out with every write -- see `SharedInk.scale` for what happens without
    /// it.
    func openInk(entry: String, in setlistId: String, store: DrawingStore,
                 pageWidth: @escaping () -> CGFloat) {
        guard FirebaseApp.app() != nil, uid != nil else { return }
        openEntry = (setlistId, entry)
        inkListener?.remove()
        inkListener = db.collection("setlists").document(setlistId)
            .collection("entries").document(entry).collection("ink")
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }
                if let error { self.trouble = error.localizedDescription; return }
                var pages: [String: [Int: Data]] = [:]
                var widths: [String: CGFloat] = [:]
                for document in snapshot?.documents ?? [] {
                    let data = document.data()
                    pages[document.documentID] =
                        SharedInk.decode(data["pages"] as? [String: Any] ?? [:])
                    if let width = data["pageWidth"] as? Double, width > 0 {
                        widths[document.documentID] = CGFloat(width)
                    }
                }
                self.ink = pages
                self.inkWidths = widths
            }

        store.onSave = { [weak self] key, drawing in
            guard let self,
                  let found = SharedEntryCopies.entryAndPage(forDrawingKey: key),
                  found.entry == entry else { return }
            let data = drawing.dataRepresentation()
            Task { @MainActor in
                await self.push(data, page: found.page, entry: entry,
                                setlistId: setlistId, pageWidth: pageWidth())
            }
        }
    }

    /// Stop watching, and stop pushing. Called when the score closes: a store
    /// hook left installed would push a LOCAL arrangement's markup to whatever
    /// entry happened to be open last.
    func closeInk(store: DrawingStore) {
        store.onSave = nil
        inkListener?.remove()
        inkListener = nil
        openEntry = nil
        ink = [:]
        inkWidths = [:]
        inkPagesOverBudget = []
    }

    private func push(_ data: Data, page: Int, entry: String,
                      setlistId: String, pageWidth: CGFloat) async {
        // Measured against the document budget BEFORE the write, because
        // Firestore's answer to an oversized document is a rejected write and
        // this needs to be a page number a person can be told (§11.6,
        // `SharedInkSizeTests`).
        var mine = ink[uid ?? ""] ?? [:]
        mine[page] = data
        let over = SharedInk.pagesOverBudget(mine)
        inkPagesOverBudget = over
        guard !over.contains(page) else { return }
        do {
            try await writeInk(data, entry: entry, page: page,
                               pageWidth: pageWidth, in: setlistId)
        } catch {
            // The disk write already happened, so nothing is lost -- this is a
            // page that has not reached the band yet.
            trouble = error.localizedDescription
        }
    }

    /// Everybody's marks for one page, ready for `SharedInkOverlay`.
    func layers(page: Int, participants: [String],
                visibility: InkLayers.Visibility, readAt pageWidth: CGFloat)
        -> [SharedInk.Layer] {
        guard let uid else { return [] }
        return SharedInk.layers(page: page, byUser: ink, widths: inkWidths,
                                readAt: pageWidth, me: uid,
                                visibility: visibility,
                                participants: participants)
    }

    enum Trouble: LocalizedError {
        case signedOut, notYours, full, unusablePayload

        var errorDescription: String? {
            switch self {
            case .signedOut:       return "Sign in to share setlists."
            case .notYours:        return "Only the person who made this setlist can delete it."
            case .full:            return "That set list is full — twelve people is the limit."
            case .unusablePayload: return "That arrangement could not be prepared for sharing."
            }
        }
    }
}
