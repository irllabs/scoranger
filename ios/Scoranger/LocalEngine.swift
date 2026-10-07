import Foundation

/// Typed facade over the embedded Python engine (PythonEngine actor).
/// Mirrors the subset of EngineClient the app uses, so AppState can switch
/// between the on-device engine and a remote `scor serve`.
enum LocalEngineError: Error, LocalizedError {
    case engine(String)
    var errorDescription: String? {
        if case .engine(let msg) = self { return msg }
        return nil
    }
}

struct LocalEngine {
    private func result(op: String, args: [String: Any] = [:]) async throws -> [String: Any] {
        // Every op the app asks of the engine passes through here, so one
        // measurement covers all of them, named by op.
        let span = PerfMetrics.shared.begin(PerfMetrics.Name.bridge(op))
        let r = await PythonEngine.shared.call(op: op, args: args)
        span?.end()
        guard let ok = r["ok"] as? Bool, ok else {
            throw LocalEngineError.engine(r["error"] as? String ?? "engine error")
        }
        return (r["result"] as? [String: Any]) ?? [:]
    }

    private func decode<T: Decodable>(_ dict: [String: Any], as type: T.Type) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: dict)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: data)
    }

    func manifest() async throws -> Manifest {
        try decode(try await result(op: "manifest"), as: Manifest.self)
    }

    func transpose(score: String, semitones: Int) async throws {
        _ = try await result(op: "transpose",
                             args: ["score": score, "interval": String(semitones)])
    }

    /// Import a MusicXML/MIDI file into the on-device workspace, optionally
    /// filing the new arrangement under a piece.
    @discardableResult
    func importScore(fileURL: URL, name: String?, piece: String? = nil) async throws -> String {
        try await importScoreReporting(fileURL: fileURL, name: name, piece: piece).slug
    }

    /// The same import, and what the reader should be told about it: a file of
    /// many tunes can import some and name the rest (`ImportReport`).
    func importScoreReporting(fileURL: URL, name: String?, piece: String? = nil)
        async throws -> (slug: String, notice: String?) {
        var args: [String: Any] = ["path": fileURL.path]
        if let name { args["name"] = name }
        if let piece { args["piece"] = piece }
        let r = try await result(op: "import", args: args)
        return ((r["score"] as? String) ?? "", ImportReport.notice(from: r))
    }

    /// Import a PDF as a scan arrangement: stored as it arrived, readable and
    /// annotatable at once. OMR is a separate, explicit step afterwards.
    func importPDF(fileURL: URL, name: String?, piece: String? = nil) async throws -> String {
        var args: [String: Any] = ["path": fileURL.path]
        if let name { args["name"] = name }
        if let piece { args["piece"] = piece }
        let r = try await result(op: "import-pdf", args: args)
        return (r["score"] as? String) ?? ""
    }

    /// Plan (or run) the import of a whole exported folder.
    ///
    /// `commit: false` writes nothing and returns the tree it WOULD build --
    /// this runs across an entire library, and the shape of someone's library
    /// is worth reading before it exists.
    /// `files` are paths relative to `folder`, listed by the caller. Passing
    /// them is not an optimisation: a folder from the iCloud file provider
    /// enumerates as empty inside Python, so the engine cannot find its own
    /// contents there. See `FolderScan`.
    func bulkImport(folder: URL, files: [String]? = nil, commit: Bool,
                    manifest: [[String: Any]]? = nil,
                    exclude: [String] = []) async throws -> [String: Any] {
        var args: [String: Any] = ["folder": folder.path, "commit": commit]
        if let files { args["files"] = files }
        if let manifest { args["manifest"] = manifest }
        if !exclude.isEmpty { args["exclude"] = exclude }
        return try await result(op: "bulk-import", args: args)
    }

    /// Add a notation file as the next VERSION of an existing arrangement.
    /// What OMR on demand produces: the scan stays as it was, and the
    /// transcription sits after it in the same history.
    /// `recordedAs` is the label the VERSION carries in its history ("omr"),
    /// not a bridge op -- named apart from `op:` so it cannot be mistaken for
    /// one, by a reader or by check_bridge_ops.
    @discardableResult
    func addVersion(from fileURL: URL, score: String,
                    recordedAs label: String) async throws -> String {
        let r = try await result(op: "add-version-from-file",
                                 args: ["score": score, "path": fileURL.path, "op": label])
        return (r["version"] as? String) ?? ""
    }

    /// Import a PDF as a BOOK: a collection to take arrangements out of.
    func importBook(fileURL: URL, name: String?) async throws -> String {
        var args: [String: Any] = ["path": fileURL.path]
        if let name { args["name"] = name }
        return (try await result(op: "import-book", args: args)["book"] as? String) ?? ""
    }

    /// Take pages out of a book as a new PDF arrangement.
    @discardableResult
    func extractFromBook(_ book: String, from: Int, to: Int, name: String,
                         piece: String?) async throws -> String {
        var args: [String: Any] = ["book": book, "from_page": from,
                                   "to_page": to, "name": name]
        if let piece { args["piece"] = piece }
        return (try await result(op: "book-extract", args: args)["score"] as? String) ?? ""
    }

    /// Where each tune in a book starts and what it is called. Read-only.
    /// `ocr` carries Vision's lines for pages the last answer named in
    /// `needsOcr`.
    func bookDetect(_ book: String,
                    ocr: [String: [[String: Any]]] = [:]) async throws -> BookProposal {
        var args: [String: Any] = ["book": book]
        if !ocr.isEmpty { args["ocr"] = ocr }
        return try decode(try await result(op: "book-detect", args: args),
                          as: BookProposal.self)
    }

    /// Keep the tunes as the book's contents (nil clears them). The book stays
    /// one book; nothing is copied.
    func setBookContents(_ book: String, entries: [BookEntry]?) async throws {
        _ = try await result(op: "book-contents",
                             args: ["book": book,
                                    "entries": entries.map(Self.plan) ?? NSNull()])
    }

    /// Take each tune out as an arrangement under a piece of its name.
    func splitBook(_ book: String, entries: [BookEntry]) async throws -> BookSplitReport {
        try decode(try await result(op: "book-split",
                                    args: ["book": book, "entries": Self.plan(entries)]),
                   as: BookSplitReport.self)
    }

    private static func plan(_ entries: [BookEntry]) -> [[String: Any]] {
        entries.map { ["id": $0.id, "title": $0.title, "from": $0.from, "to": $0.to] }
    }

    /// Where a book's own PDF is, so the reader can look through it.
    func bookFilePath(_ book: String) async throws -> String {
        let r = try await result(op: "book-file", args: ["book": book])
        guard let path = r["path"] as? String else {
            throw LocalEngineError.engine("no path in book-file result")
        }
        return path
    }

    /// Rename a book. The LABEL only: the slug names books/<slug>.pdf and
    /// every extraction's recorded args, so the engine keeps it (workspace.
    /// rename_book).
    func renameBook(_ slug: String, name: String) async throws {
        _ = try await result(op: "rename-book", args: ["book": slug, "name": name])
    }

    func deleteBook(_ slug: String) async throws {
        _ = try await result(op: "delete-book", args: ["book": slug])
    }

    func deleteScore(_ slug: String) async throws {
        _ = try await result(op: "delete-score", args: ["score": slug])
    }

    /// Absolute path of a version's MusicXML artifact (for rendering).
    /// Write a version out as MusicXML or MIDI and hand back where it landed.
    ///
    /// PDF is deliberately NOT here: the bridge refuses it, because engraving
    /// on device is Swift and carries chord adjustments and whistle fingerings
    /// that the Python side never sees. `AppState.exportFile` routes PDF to
    /// `VerovioRenderer` instead.
    func exportFile(score: String, version: String?,
                    format: String, parts: [String] = []) async throws -> String {
        var args: [String: Any] = ["score": score, "format": format]
        if let version { args["version"] = version }
        if !parts.isEmpty { args["parts"] = parts.joined(separator: ",") }
        let r = try await result(op: "export", args: args)
        guard let path = r["path"] as? String else {
            throw LocalEngineError.engine("no path in export result")
        }
        return path
    }

    /// The score AS PERFORMED: a MIDI file, and the map from its beats back to
    /// the engraved bars.
    ///
    /// ONE call, because the two halves must describe the same performance.
    /// The engine builds both out of a single performed score -- repeats
    /// played out, written pitch made sounding -- and asking for them
    /// separately is how a play head ends up following music that is not the
    /// music sounding. It creates no version: playback is a reading of the
    /// arrangement, like `info`.
    func playback(score: String, version: String?) async throws
        -> (midi: URL, timeline: PlaybackTimeline) {
        var args: [String: Any] = ["score": score]
        if let version { args["version"] = version }
        let r = try await result(op: "playback", args: args)
        guard let path = r["path"] as? String else {
            throw LocalEngineError.engine("no path in playback result")
        }
        guard let raw = r["timeline"] as? [String: Any] else {
            throw LocalEngineError.engine("no timeline in playback result")
        }
        return (URL(fileURLWithPath: path), try decode(raw, as: PlaybackTimeline.self))
    }

    func versionFilePath(score: String, version: String?) async throws -> String {
        var args: [String: Any] = ["score": score]
        if let version { args["version"] = version }
        let r = try await result(op: "version-file", args: args)
        guard let path = r["path"] as? String else {
            throw LocalEngineError.engine("no path in version-file result")
        }
        return path
    }

    /// Raw op passthrough (used by the chat tool loop).
    func call(op: String, args: [String: Any]) async throws -> [String: Any] {
        try await result(op: op, args: args)
    }

    // MARK: - the account's library on every device (0.16.0, librarysync.py)

    /// Tie the journal to this account, starting it if it never ran. A
    /// different account from last time is owed the whole library.
    func librarySyncBind(account: String) async throws -> [String: Any] {
        try await result(op: "library-sync-bind", args: ["account": account])
    }

    /// What this device owes the server, as records, oldest first.
    func librarySyncOutbox(limit: Int) async throws -> [String: Any] {
        try await result(op: "library-sync-outbox", args: ["limit": limit])
    }

    /// The server has these; stop owing them.
    func librarySyncAck(_ acks: [[String: Any]]) async throws -> [String: Any] {
        try await result(op: "library-sync-ack", args: ["acks": acks])
    }

    /// Write what other devices did into this one. Returns what was deferred.
    func librarySyncApply(_ records: [[String: Any]]) async throws -> [String: Any] {
        try await result(op: "library-sync-apply", args: ["records": records])
    }

    func librarySyncStatus() async throws -> [String: Any] {
        try await result(op: "library-sync-status")
    }
}
