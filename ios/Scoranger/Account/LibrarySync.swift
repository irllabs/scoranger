import FirebaseCore
import FirebaseFirestore
import FirebaseStorage
import Foundation
import Network

/// A signed-in account's library, the same on every device (0.16.0).
///
/// Ali: "if i signin as google on my ipad and have a whole bunch of
/// pieces/setlists/books, when i sign in with google on my iphone, I expect to
/// see all the same pieces/setlists/books." design/FIREBASE.md §2, §4, §5.
///
/// **The local library stays authoritative for the device.** This carries
/// records between the engine (`librarysync.py`, which turns the library into
/// uid-named records and back) and the account's copy:
///
///     users/{uid}                          libraryId
///     libraries/{libraryId}                owner
///     libraries/{libraryId}/{collection}/{uid}   payload, deleted, device, updatedAt
///     Storage: libraries/{libraryId}/files/{versions|sources|books}/...
///
/// Every rule that says who may read what is in firestore.rules and
/// storage.rules (an account reads and writes only a library it owns); what
/// this type decides without a server is `LibrarySyncModel`, tested.
///
/// **One account, one library.** The first device to sign in creates it. A
/// device that already has a library of its own and signs in to an account
/// that has one MERGES: its documents go up, the account's come down, and both
/// devices hold the union (Ali, 2026-09-26). Nothing is converted, because
/// every document already has a uid (§9.2).
///
/// **A cycle is push, then pull**, never both at once and never two at once.
/// Pushing first means a document this device still owes is not overwritten
/// by an older copy on the way down; the engine also refuses to overwrite one
/// it still owes.
@MainActor
final class LibrarySync: ObservableObject {

    @Published private(set) var status: LibrarySyncModel.Status = .off
    /// Bytes of books waiting while on cellular, for the reader to be asked
    /// about. Nil when nothing is waiting or the reader has already answered.
    @Published var cellularQuestion: Int?

    private let engine = LocalEngine()
    private weak var state: AppState?
    private var account: String?
    private var libraryId: String?
    private var network: LibrarySyncModel.Network = .offline
    /// The reader's answer to "books over cellular", for this session.
    private var cellularAllowed = false
    private var cellularDeclined = false
    private var running = false
    private var again = false
    private var ticker: Task<Void, Never>?
    private var debounce: Task<Void, Never>?
    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let network: LibrarySyncModel.Network =
                path.status != .satisfied ? .offline
                : (path.isExpensive || path.usesInterfaceType(.cellular)) ? .cellular
                : .wifi
            Task { @MainActor [weak self] in
                guard let self else { return }
                let was = self.network
                self.network = network
                if network == .wifi { self.cellularDeclined = false }
                if was != network, network != .offline { self.nudge() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "library-sync.network"))
    }

    func attach(_ state: AppState) {
        self.state = state
    }

    /// Start or stop with the account. Nil stops, and keeps everything local.
    ///
    /// **The account is taken only once every precondition holds.** Every
    /// other entry point -- `nudge`, `libraryChanged`, the network monitor --
    /// asks only whether there is an account, and `Firestore.firestore()`
    /// raises an Objective-C exception when Firebase is not configured, which
    /// no Swift `catch` can stop. Recording the account before these checks
    /// crashed the app under the UI tests' pretend account, where Firebase is
    /// deliberately never brought up (the 0.16.0 gate, four AccountDeletion
    /// tests).
    func follow(account uid: String?) {
        guard uid != account else { return }
        account = nil
        libraryId = nil
        ticker?.cancel()
        guard let uid, SignIn.pretendedAccount == nil, FirebaseApp.app() != nil,
              state?.useLocalEngine == true else {
            status = .off
            cellularQuestion = nil
            return
        }
        account = uid
        nudge()
        // A slow heartbeat for what other devices do; this device's own
        // changes are pushed within seconds of being made (`libraryChanged`).
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await MainActor.run { self?.nudge() }
            }
        }
    }

    /// Something in the library changed here. Pushed a moment later, so a
    /// burst of edits is one cycle.
    func libraryChanged() {
        guard account != nil else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.nudge() }
        }
    }

    /// Run a cycle now, or right after the one that is running.
    func nudge() {
        guard account != nil else { return }
        if running { again = true; return }
        running = true
        Task {
            repeat {
                again = false
                await cycle()
            } while again
            running = false
        }
    }

    /// The reader said "now" to books over cellular.
    func allowCellular() {
        cellularAllowed = true
        cellularQuestion = nil
        nudge()
    }

    /// The reader said "wait for Wi-Fi". Not asked again until the next
    /// session or the next time this device is on Wi-Fi and then leaves it.
    func waitForWiFi() {
        cellularDeclined = true
        cellularQuestion = nil
    }

    // MARK: - a cycle

    private var db: Firestore { Firestore.firestore() }
    private var storage: Storage { Storage.storage() }
    /// Bytes of books this cycle could not move on cellular.
    private var heldBookBytes = 0

    private func cycle() async {
        // Re-checked on every cycle, not only at `follow`: see there.
        guard let account, FirebaseApp.app() != nil else { return }
        guard network != .offline else {
            let pending = await pendingCount()
            status = .offline(pending)
            return
        }
        if case .synced = status {} else { status = .syncing }
        heldBookBytes = 0
        do {
            let library = try await library(for: account)
            _ = try await engine.librarySyncBind(account: "\(account)/\(library)")
            try await push(library)
            let changed = try await pull(library)
            if changed { await state?.refresh() }
            let pending = await pendingCount()
            if heldBookBytes > 0, network == .cellular {
                status = .askCellular(bytes: heldBookBytes)
                if !cellularAllowed && !cellularDeclined { cellularQuestion = heldBookBytes }
            } else {
                status = pending > 0 ? .waiting(pending) : .synced(Date())
            }
        } catch {
            status = .failed(Self.readable(error))
        }
    }

    private func pendingCount() async -> Int {
        (try? await engine.librarySyncStatus())?["pending"] as? Int ?? 0
    }

    /// The account's library, creating it on the first device ever to sign in.
    ///
    /// In a transaction, because two devices signing in to a new account at
    /// the same moment must end up agreeing on ONE library, and the loser's
    /// fresh library document is left empty rather than half-used.
    private func library(for account: String) async throws -> String {
        if let libraryId { return libraryId }
        let user = db.collection("users").document(account)
        if let existing = try await user.getDocument(source: .server)
            .data()?["libraryId"] as? String {
            libraryId = existing
            return existing
        }
        let fresh = db.collection("libraries").document()
        try await fresh.setData(["owner": account,
                                 "created": FieldValue.serverTimestamp()])
        let chosen = try await db.runTransaction { transaction, errorPointer -> Any? in
            do {
                let snapshot = try transaction.getDocument(user)
                if let existing = snapshot.data()?["libraryId"] as? String {
                    return existing
                }
                transaction.setData(["libraryId": fresh.documentID], forDocument: user,
                                    merge: true)
                return fresh.documentID
            } catch let error as NSError {
                errorPointer?.pointee = error
                return nil
            }
        }
        guard let id = chosen as? String else { throw Trouble.noLibrary }
        if id != fresh.documentID { try? await fresh.delete() }
        libraryId = id
        return id
    }

    private func documents(_ library: String, _ collection: String) -> CollectionReference {
        db.collection("libraries").document(library).collection(collection)
    }

    private func file(_ library: String, _ name: String) -> StorageReference {
        storage.reference(withPath: "libraries/\(library)/files/\(name)")
    }

    private var device: String {
        let key = "librarySync.device"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    // MARK: - up

    private func push(_ library: String) async throws {
        while true {
            let box = try await engine.librarySyncOutbox(limit: 400)
            let records = box["records"] as? [[String: Any]] ?? []
            guard !records.isEmpty else { return }
            var acks: [[String: Any]] = []
            var batch = db.batch()
            var inBatch = 0
            var held = 0
            for record in records {
                guard let collection = record["collection"] as? String,
                      let uid = record["uid"] as? String else { continue }
                let deleted = record["deleted"] as? Bool ?? false
                var data: [String: Any] = ["deleted": deleted, "device": device,
                                           "updatedAt": FieldValue.serverTimestamp()]
                if deleted {
                    data["payload"] = "{}"
                } else {
                    let fields = record["fields"] as? [String: Any] ?? [:]
                    let json = try JSONSerialization.data(withJSONObject: fields,
                                                          options: [.sortedKeys])
                    data["payload"] = String(decoding: json, as: UTF8.self)
                    if let upload = record["file"] as? [String: Any],
                       let path = upload["path"] as? String,
                       let name = upload["name"] as? String {
                        let isBook = collection == "books"
                        guard LibrarySyncModel.transfer(isBook: isBook, network: network,
                                                        consented: cellularAllowed) == .go else {
                            heldBookBytes += upload["bytes"] as? Int ?? 0
                            held += 1
                            continue
                        }
                        let sent = try await send(URL(fileURLWithPath: path), as: name,
                                                  to: library, isBook: isBook)
                        data["fileName"] = name
                        data["fileBytes"] = sent.bytes
                        data["fileEncoding"] = sent.encoding as Any
                    }
                }
                batch.setData(data, forDocument: documents(library, collection).document(uid))
                acks.append(contentsOf: record["acks"] as? [[String: Any]] ?? [])
                inBatch += 1
                if inBatch == 400 {
                    try await batch.commit()
                    _ = try await engine.librarySyncAck(acks)
                    acks = []
                    batch = db.batch()
                    inBatch = 0
                }
            }
            if inBatch > 0 { try await batch.commit() }
            if !acks.isEmpty { _ = try await engine.librarySyncAck(acks) }
            // Held books stay owed. Asking for more would hand them back again.
            if held > 0 || !(box["more"] as? Bool ?? false) { return }
        }
    }

    /// Upload one file. Notation is packed with zlib; a PDF is sent as it is.
    /// A book already there at the same size is not sent twice: re-adoption
    /// (another account on this device, a lost journal) re-owes everything,
    /// and a 50 MB book should not cross the network again for it.
    private func send(_ url: URL, as name: String, to library: String,
                      isBook: Bool) async throws -> (bytes: Int, encoding: String?) {
        let reference = file(library, name)
        if isBook {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]
                        as? Int) ?? -1
            if let existing = try? await reference.getMetadata(), Int(existing.size) == size {
                return (size, nil)
            }
            let metadata = StorageMetadata()
            metadata.contentType = "application/pdf"
            _ = try await reference.putFileAsync(from: url, metadata: metadata)
            return (size, nil)
        }
        let raw = try Data(contentsOf: url)
        if LibrarySyncModel.shouldCompress(name),
           let packed = try? (raw as NSData).compressed(using: .zlib) as Data {
            _ = try await reference.putDataAsync(packed)
            return (packed.count, LibrarySyncModel.zlib)
        }
        _ = try await reference.putDataAsync(raw)
        return (raw.count, nil)
    }

    // MARK: - down

    /// Everything other devices wrote since this device last looked, applied.
    /// Returns whether the library changed.
    private func pull(_ library: String) async throws -> Bool {
        let me = device
        var fresh: [LibrarySyncModel.Remote] = []
        var cursors = loadCursors(library)
        for collection in LibrarySyncModel.collections {
            let floor = LibrarySyncModel.floor(for: cursors[collection])
            var query = documents(library, collection)
                .whereField("updatedAt", isGreaterThan: Timestamp(seconds: Int64(floor), nanoseconds: 0))
                .order(by: "updatedAt")
                .limit(to: 300)
            while true {
                let page = try await query.getDocuments(source: .server)
                for document in page.documents {
                    guard let remote = Self.remote(document, collection: collection) else { continue }
                    cursors[collection] = max(cursors[collection] ?? 0, remote.updatedAt)
                    if remote.device != me { fresh.append(remote) }
                }
                guard page.documents.count == 300, let last = page.documents.last else { break }
                query = query.start(afterDocument: last)
            }
        }
        let offered = LibrarySyncModel.merge(held: loadHeld(library), fresh: fresh)
        guard !offered.isEmpty else {
            saveCursors(cursors, library)
            return false
        }
        var applied = loadApplied(library)
        let downloads = FileManager.default.temporaryDirectory
            .appending(path: "library-sync", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: downloads) }

        // Already written here at this state: the overlap re-read it.
        let wanted = offered.filter { remote in
            guard let at = applied[remote.key] else { return true }
            return at < remote.updatedAt
        }
        // The bytes first, six at a time: a first sign-in on a new device
        // fetches every version of every arrangement.
        var fetchable: [(key: String, name: String, target: URL, encoding: String?)] = []
        for remote in wanted where !remote.deleted {
            guard let name = remote.fileName else { continue }
            switch LibrarySyncModel.transfer(isBook: remote.isBook, network: network,
                                             consented: cellularAllowed) {
            case .go:
                fetchable.append((remote.key, name,
                                  downloads.appending(path: name.replacingOccurrences(of: "/", with: "_")),
                                  remote.fileEncoding))
            case .ask, .wait:
                heldBookBytes += remote.fileBytes ?? 0
            }
        }
        var fetched: [String: String] = [:]
        for chunk in stride(from: 0, to: fetchable.count, by: 6) {
            let slice = fetchable[chunk..<min(chunk + 6, fetchable.count)]
            let done = await withTaskGroup(of: (String, String?).self) { group in
                for job in slice {
                    group.addTask { [self] in
                        do {
                            try await self.fetch(job.name, from: library, to: job.target,
                                                 encoding: job.encoding)
                            return (job.key, job.target.path)
                        } catch {
                            // Not fatal: the engine defers the record and the
                            // next cycle asks for these bytes again.
                            return (job.key, nil)
                        }
                    }
                }
                var out: [(String, String?)] = []
                for await result in group { out.append(result) }
                return out
            }
            for (key, path) in done { if let path { fetched[key] = path } }
        }
        var records: [[String: Any]] = []
        for remote in wanted {
            let fields = (try? JSONSerialization.jsonObject(with: Data(remote.payload.utf8)))
                as? [String: Any] ?? [:]
            var record: [String: Any] = ["collection": remote.collection, "uid": remote.uid,
                                         "deleted": remote.deleted, "fields": fields]
            if let path = fetched[remote.key] { record["file_path"] = path }
            records.append(record)
        }
        guard !records.isEmpty else {
            saveCursors(cursors, library)
            return false
        }
        let result = try await engine.librarySyncApply(records)
        let deferred = Set((result["deferred"] as? [[String: Any]] ?? []).compactMap {
            guard let c = $0["collection"] as? String, let u = $0["uid"] as? String else { return nil }
            return "\(c)/\(u)"
        } as [String])
        for remote in offered where !deferred.contains(remote.key) {
            applied[remote.key] = remote.updatedAt
        }
        saveHeld(offered.filter { deferred.contains($0.key) }, library)
        saveApplied(applied, library)
        saveCursors(cursors, library)
        return (result["applied"] as? Int ?? 0) + (result["removed"] as? Int ?? 0) > 0
    }

    private func fetch(_ name: String, from library: String, to target: URL,
                       encoding: String?) async throws {
        let reference = file(library, name)
        if encoding == LibrarySyncModel.zlib {
            let packed = try await reference.data(maxSize: 64 * 1024 * 1024)
            let raw = try (packed as NSData).decompressed(using: .zlib) as Data
            try raw.write(to: target)
        } else {
            _ = try await reference.writeAsync(toFile: target)
        }
    }

    private static func remote(_ document: QueryDocumentSnapshot,
                               collection: String) -> LibrarySyncModel.Remote? {
        let data = document.data()
        guard let stamp = data["updatedAt"] as? Timestamp,
              let device = data["device"] as? String else { return nil }
        return LibrarySyncModel.Remote(
            collection: collection, uid: document.documentID,
            deleted: data["deleted"] as? Bool ?? false,
            payload: data["payload"] as? String ?? "{}",
            device: device,
            fileName: data["fileName"] as? String,
            fileBytes: data["fileBytes"] as? Int,
            fileEncoding: data["fileEncoding"] as? String,
            updatedAt: Double(stamp.seconds) + Double(stamp.nanoseconds) / 1e9)
    }

    // MARK: - what survives a relaunch

    /// The pull cursors, the records held back, and what has been applied,
    /// per account library -- kept INSIDE the local workspace, beside the
    /// journal (`sync.db`), so they live and die with the library they
    /// describe. Kept anywhere longer-lived, a device whose library was
    /// replaced believed it already had the account's, and pulled nothing:
    /// found by the two-simulator test. Losing them costs a re-read, never a
    /// document, because applying is idempotent. A dot-name: legacy migration
    /// reads only folders holding a meta.json, and no slug begins with a dot.
    private func stateFile(_ name: String, _ library: String) -> URL {
        let dir = PythonEngine.workspaceURL
            .appending(path: ".library-sync/\(library)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "\(name).json")
    }

    private func load<T: Decodable>(_ name: String, _ library: String, as type: T.Type) -> T? {
        guard let data = try? Data(contentsOf: stateFile(name, library)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func save<T: Encodable>(_ value: T, _ name: String, _ library: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: stateFile(name, library), options: .atomic)
    }

    private func loadCursors(_ library: String) -> [String: Double] {
        load("cursors", library, as: [String: Double].self) ?? [:]
    }
    private func saveCursors(_ value: [String: Double], _ library: String) {
        save(value, "cursors", library)
    }
    private func loadHeld(_ library: String) -> [LibrarySyncModel.Remote] {
        load("held", library, as: [LibrarySyncModel.Remote].self) ?? []
    }
    private func saveHeld(_ value: [LibrarySyncModel.Remote], _ library: String) {
        save(value, "held", library)
    }
    private func loadApplied(_ library: String) -> [String: Double] {
        load("applied", library, as: [String: Double].self) ?? [:]
    }
    private func saveApplied(_ value: [String: Double], _ library: String) {
        save(value, "applied", library)
    }

    // MARK: - trouble

    enum Trouble: LocalizedError {
        case noLibrary
        var errorDescription: String? {
            "the account's library could not be found or made."
        }
    }

    private static func readable(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == FirestoreErrorDomain,
           ns.code == FirestoreErrorCode.permissionDenied.rawValue {
            return "the server refused this account's library. Sign out and in again."
        }
        if ns.domain == FirestoreErrorDomain,
           ns.code == FirestoreErrorCode.unavailable.rawValue {
            return "the server could not be reached. It will try again."
        }
        return (error as? LocalizedError)?.errorDescription ?? ns.localizedDescription
    }
}
