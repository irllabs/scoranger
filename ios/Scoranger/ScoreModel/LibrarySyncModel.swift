import Foundation

/// What `LibrarySync` decides, with the network taken out (0.16.0).
///
/// A signed-in account's library is the same on every device it signs in on.
/// The engine (`librarysync.py`) turns the library into RECORDS -- one per
/// document, named by uid -- and back; `LibrarySync` carries records to and
/// from Firestore and their bytes to and from Cloud Storage. Everything that
/// can be decided without a server is here, so it is tested in the unit bundle
/// with no Firebase: what a record looks like on the server, when a transfer
/// may happen on cellular, which held records to offer again, and what the
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
        case failed(String)
    }

    /// One line under the account, never a spinner: a musician needs to know
    /// whether what they are looking at is current (§5.3).
    static func sentence(_ status: Status, now: Date = Date()) -> String {
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
            return "Your library is up to date on this device. Synced \(when)."
        case .waiting(let n):
            return "\(n) \(n == 1 ? "change" : "changes") waiting to sync."
        case .offline(let n):
            return n == 0
                ? "Offline. Your library works as usual and syncs when you are back online."
                : "Offline. \(n) \(n == 1 ? "change waits" : "changes wait") for a connection."
        case .askCellular(let bytes):
            return "\(megabytes(bytes)) of books waiting for Wi-Fi."
        case .failed(let reason):
            return "Could not sync: \(reason)"
        }
    }

    static func megabytes(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1_000_000
        return mb < 1 ? "under 1 MB" : "\(Int(mb.rounded())) MB"
    }
}
