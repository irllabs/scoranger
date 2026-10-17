import Foundation

/// What `LibrarySync` decides, with the network taken out (0.16.0).
///
/// A signed-in account's library is the same on every device it signs in on.
/// The engine (`librarysync.py`) turns the library into RECORDS -- one per
/// document, named by uid -- and back; `LibrarySync` carries records to and
/// from Firestore and their bytes to and from Cloud Storage. Everything that
/// can be decided without a server is here, so it is tested in the unit bundle
/// with no Firebase: what a record looks like on the server, when a transfer
/// may happen on cellular, how much of a push goes up between commits, what
/// this device calls itself, which held records to offer again, and what the
/// status line says.
enum LibrarySyncModel {

    /// A document as the server keeps it, under
    /// `libraries/{libraryId}/{collection}/{uid}`.
    ///
    /// The engine's fields travel as ONE JSON string, `payload`, rather than
    /// as Firestore fields. Firestore refuses an array directly inside an
    /// array and turns every JSON number into a Double or an Int64 by its own
    /// rules; the engine's documents are JSON and come back as the same JSON.
    struct Remote: Codable, Equatable {
        let collection: String
        let uid: String
        let deleted: Bool
        let payload: String
        /// The device that wrote it. A device skips its own writes coming back.
        let device: String
        /// The bytes, when the document has any: the object's name under
        /// `libraries/{libraryId}/files/`, its size as uploaded, and how it was
        /// packed.
        let fileName: String?
        let fileBytes: Int?
        let fileEncoding: String?
        /// The server's clock, seconds since 1970. What the pull cursor is.
        let updatedAt: Double

        var key: String { "\(collection)/\(uid)" }
        var isBook: Bool { collection == "books" }
    }

    /// Everything a sync can move, as the engine names it.
    static let collections = ["pieces", "scores", "versions", "sources", "setlists", "books"]

    // MARK: - files

    /// Notation compresses about 24:1 (design/FIREBASE.md §1.2) and a PDF
    /// barely at all, so only text formats are packed.
    static func shouldCompress(_ fileName: String) -> Bool {
        ["musicxml", "xml", "mei", "abc"].contains((fileName as NSString).pathExtension.lowercased())
    }

    static let zlib = "zlib"

    // MARK: - pushing

    /// How much of a push may be in flight before the server is written and
    /// the engine stops owing it.
    ///
    /// A first push of a large library takes minutes and is cut off whenever
    /// iOS suspends the app or the connection drops, and whatever was uploaded
    /// but not yet committed and acknowledged is sent again from the start of
    /// its window. The window used to be 400 records, uploaded one file at a
    /// time, so an interrupted first push could lose minutes of work and make
    /// no progress at all from one launch to the next. Twenty records, or
    /// fewer once their files reach a couple of megabytes -- a scanned
    /// arrangement, a book -- bounds what one interruption costs.
    static let windowRecords = 20
    static let windowBytes = 2_000_000

    static func windowIsFull(records: Int, bytes: Int) -> Bool {
        records >= windowRecords || bytes >= windowBytes
    }

    // MARK: - this device's name

    /// The name this device writes under (`Remote.device`), and the one a
    /// pull skips as its own writes coming back.
    struct DeviceIdentity: Equatable {
        let id: String
        /// `UIDevice.identifierForVendor` when `id` was minted, if iOS had it.
        let vendor: String?
    }

    /// The name is kept only while it was minted under this device's vendor
    /// id.
    ///
    /// It lives in UserDefaults, and Library/Preferences is in every iCloud
    /// and Finder backup, so a phone set up from another device's backup
    /// starts with that device's name -- and each of the two then skips
    /// everything the other writes, as its own. `identifierForVendor` is
    /// different on every device (Apple's documentation for it), so a stored
    /// vendor id that does not match says the name came from another device.
    /// A name stored before the vendor id was kept beside it cannot be told
    /// apart from one restored that way, and is replaced once: the cost is
    /// re-reading this device's own most recent writes, which applying
    /// already treats as a no-op. Before the first unlock after a restart iOS
    /// has no vendor id to give, and the stored name is used as it is.
    static func deviceIdentity(storedID: String?, storedVendor: String?, vendor: String?,
                               mint: () -> String) -> DeviceIdentity {
        guard let vendor else {
            return DeviceIdentity(id: storedID ?? mint(), vendor: storedVendor)
        }
        if let storedID, storedVendor == vendor {
            return DeviceIdentity(id: storedID, vendor: vendor)
        }
        return DeviceIdentity(id: mint(), vendor: vendor)
    }

    // MARK: - the network

    enum Network: Equatable {
        case offline
        case wifi
        /// Cellular, or any connection iOS marks as expensive.
        case cellular
    }

    enum Transfer: Equatable {
        case go
        /// Cellular, and a book: the reader is asked first.
        case ask
        case wait
    }

    /// When a file may move (Ali, 2026-09-26): everything on Wi-Fi; on
    /// cellular, arrangements and their history go and a BOOK asks first --
    /// "sync now or later, like many Apple services do". `consented` is the
    /// reader's answer for this session.
    static func transfer(isBook: Bool, network: Network, consented: Bool) -> Transfer {
        switch network {
        case .offline: return .wait
        case .wifi: return .go
        case .cellular: return !isBook || consented ? .go : .ask
        }
    }

    // MARK: - pulling

    /// How far back each pull reaches before its cursor.
    ///
    /// The cursor is the newest `updatedAt` seen, and a server timestamp is
    /// assigned at COMMIT: a write stamped just before the cursor can become
    /// visible just after the query that set it. Reaching back re-reads a few
    /// records, which applying already treats as a no-op.
    static let overlap: TimeInterval = 120

    static func floor(for cursor: Double?) -> Double {
        guard let cursor else { return 0 }
        return max(0, cursor - overlap)
    }

    /// Records held back last time -- an arrangement whose music had not
    /// arrived, a book waiting for Wi-Fi -- merged with what just arrived.
    /// The newer copy of a document wins; held ones that nothing replaced are
    /// offered again.
    static func merge(held: [Remote], fresh: [Remote]) -> [Remote] {
        var byKey: [String: Remote] = [:]
        for record in held { byKey[record.key] = record }
        for record in fresh {
            if let old = byKey[record.key], old.updatedAt > record.updatedAt { continue }
            byKey[record.key] = record
        }
        return byKey.values.sorted { ($0.updatedAt, $0.key) < ($1.updatedAt, $1.key) }
    }

    // MARK: - what the reader is told

    enum Status: Equatable {
        case off
        case syncing
        case synced(Date)
        case waiting(Int)
        case offline(Int)
        /// A book, or several, waiting for the reader to say "now" on cellular.
        case askCellular(bytes: Int)
        /// This device's changes could not be sent, and this many are still
        /// owed; what the other devices did was still fetched.
        case unsent(Int, String)
        case failed(String)
    }

    /// What this device has been told of and does not hold yet: an
    /// arrangement whose music has not downloaded, a set list waiting for one
    /// of its arrangements, a book. Counted by the engine as it applies
    /// (`librarysync._waiting`), because only the engine knows which records
    /// it held back and why.
    struct Arriving: Equatable {
        var arrangements = 0
        var setlists = 0
        var books = 0

        static let none = Arriving()
    }

    /// One line under the account, never a spinner: a musician needs to know
    /// whether what they are looking at is current (§5.3). "Up to date" is
    /// said only when nothing is arriving either: the count of changes owed
    /// is what this device has not sent, and says nothing about what it has
    /// not received.
    static func sentence(_ status: Status, arriving: Arriving = .none,
                         now: Date = Date()) -> String {
        let still = arrivingClause(arriving)
        switch status {
        case .off:
            return "Sign in to keep your library on all your devices."
        case .syncing:
            return "Syncing your library…"
        case .synced(let at):
            let seconds = Int(now.timeIntervalSince(at))
            let when = seconds < 60 ? "just now"
                : seconds < 3600 ? "\(seconds / 60) min ago"
                : "at \(at.formatted(date: .omitted, time: .shortened))"
            guard let still else {
                return "Your library is up to date on this device. Synced \(when)."
            }
            return "Synced \(when). \(still)"
        case .waiting(let n):
            return followed("\(n) \(n == 1 ? "change" : "changes") waiting to sync.", by: still)
        case .offline(let n):
            return followed(n == 0
                ? "Offline. Your library works as usual and syncs when you are back online."
                : "Offline. \(n) \(n == 1 ? "change waits" : "changes wait") for a connection.",
                by: still)
        case .askCellular(let bytes):
            return "\(megabytes(bytes)) of books waiting for Wi-Fi."
        case .unsent(let n, let reason):
            let what = n == 0 ? "this device's changes"
                : "\(n) \(n == 1 ? "change" : "changes") from this device"
            return followed("Could not send \(what): \(reason)", by: still)
        case .failed(let reason):
            return followed("Could not sync: \(reason)", by: still)
        }
    }

    /// "3 arrangements and 1 set list have not finished arriving on this
    /// device.", or nil when nothing is arriving.
    static func arrivingClause(_ arriving: Arriving) -> String? {
        func count(_ n: Int, _ one: String, _ many: String) -> String? {
            n == 0 ? nil : "\(n) \(n == 1 ? one : many)"
        }
        let parts = [count(arriving.arrangements, "arrangement", "arrangements"),
                     count(arriving.setlists, "set list", "set lists"),
                     count(arriving.books, "book", "books")].compactMap { $0 }
        guard let last = parts.last else { return nil }
        let list = parts.count == 1 ? last
            : parts.dropLast().joined(separator: ", ") + " and " + last
        let single = parts.count == 1 && list.hasPrefix("1 ")
        return "\(list) \(single ? "has" : "have") not finished arriving on this device."
    }

    private static func followed(_ sentence: String, by clause: String?) -> String {
        guard let clause else { return sentence }
        return sentence.hasSuffix(".") ? "\(sentence) \(clause)" : "\(sentence). \(clause)"
    }

    static func megabytes(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1_000_000
        return mb < 1 ? "under 1 MB" : "\(Int(mb.rounded())) MB"
    }
}
