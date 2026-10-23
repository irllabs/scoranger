import CryptoKit
import Foundation
import MachO

/// Engravings kept on disk, so opening a version this build has already
/// engraved costs a file read instead of an engrave.
///
/// `AppState.engravings` holds engravings in memory for one process; every
/// launch began with it empty, so the first open of a score in a session paid
/// the whole engrave again (4.2 s for "Espresso" on the simulator before
/// 0.23.3) for pages that had not changed.
///
/// An entry is named by everything the pages are made from, so no entry can be
/// shown for something it was not made from:
///  - the BYTES of the MusicXML. A version's file never changes once written,
///    and an op writes a new version with a new file, so an edited score has a
///    new key; a file rewritten in place (which `renderIfNeeded(force:)`
///    exists for) has new bytes and therefore a new key too;
///  - the engraving kind (paged or continuous), the one input to
///    `VerovioRenderer.engrave` besides the file;
///  - this build of the app: the build UUID of every image in the app bundle,
///    which changes with any rebuild of the renderer, Verovio, SwiftDraw or
///    the MEI and SVG passes, and its version and build numbers;
///  - the OS version, because the PDF's text is laid out with system fonts.
/// Nothing is ever invalidated: an entry no key can name again is simply never
/// read, and the oldest go first when the store passes its budget.
///
/// Library/Caches, so the system may empty it; an empty store engraves.
final class EngravingStore: @unchecked Sendable {

    static let shared = EngravingStore(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "engravings"),
        budget: 192 << 20)

    let directory: URL
    /// Bytes the store may hold before the least recently used go.
    let budget: Int
    private let identity: String
    /// Writes and evictions, one at a time and never on the caller's thread.
    private let queue = DispatchQueue(label: "com.irllabs.scoranger.engraving-store",
                                      qos: .utility)

    /// How long a write waits before it starts. The engraving it keeps has
    /// just been handed to the canvas, and the first page's raster should not
    /// share the moment with encoding and writing a few megabytes.
    /// nil writes at once (the tests).
    private let writeDelay: DispatchTimeInterval?

    init(directory: URL, budget: Int, identity: String = EngravingStore.rendererIdentity,
         writeDelay: DispatchTimeInterval? = .milliseconds(300)) {
        self.directory = directory
        self.budget = budget
        self.identity = identity
        self.writeDelay = writeDelay
    }

    // MARK: - Keys

    /// The key for one engraving of one file's bytes.
    func key(musicXML: Data, engraving: String) -> String {
        var hash = SHA256()
        hash.update(data: Data(identity.utf8))
        hash.update(data: Data([0]))
        hash.update(data: Data(engraving.utf8))
        hash.update(data: Data([0]))
        hash.update(data: musicXML)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// This build of the renderer on this OS. See the type for why each part.
    static let rendererIdentity: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "\(info["CFBundleShortVersionString"] ?? "?")-\(info["CFBundleVersion"] ?? "?")"
        // No image found means no way to tell this build from the last: a
        // key of this process alone, so nothing kept by another is read.
        let images = bundledImageUUIDs()
        return ([version] + (images.isEmpty ? ["process-\(UUID().uuidString)"] : images)
                + [ProcessInfo.processInfo.operatingSystemVersionString]).joined(separator: "|")
    }()

    /// The LC_UUID of every loaded image inside the app bundle -- the
    /// executable, and in a Debug build the `.debug.dylib` that holds the code
    /// while the executable is a stub. The linker makes a new one for every
    /// build whose code differs.
    private static func bundledImageUUIDs() -> [String] {
        // by the bundle's own directory name rather than its whole path: on a
        // device the loader and Bundle may spell /var as /private/var
        let bundle = "/" + Bundle.main.bundleURL.lastPathComponent + "/"
        var uuids: [String] = []
        for i in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(i), String(cString: name).contains(bundle),
                  let header = _dyld_get_image_header(i) else { continue }
            var cursor = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
            for _ in 0..<header.pointee.ncmds {
                let command = cursor.loadUnaligned(as: load_command.self)
                if command.cmd == UInt32(LC_UUID) {
                    uuids.append(UUID(uuid: cursor.loadUnaligned(as: uuid_command.self).uuid).uuidString)
                    break
                }
                cursor = cursor.advanced(by: Int(command.cmdsize))
            }
        }
        return uuids.sorted()
    }

    // MARK: - Reading and writing

    private func url(_ key: String) -> URL { directory.appending(path: key) }

    /// What was kept under `key`, or nil. An entry that will not decode is
    /// removed, so it is engraved and written again rather than read again.
    func recall(_ key: String) -> EngravingArchive.Contents? {
        let file = url(key)
        guard let data = try? Data(contentsOf: file) else { return nil }
        guard let contents = EngravingArchive.decode(data) else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        // used now, so it is not the first to go
        try? FileManager.default.setAttributes([.modificationDate: Date()],
                                               ofItemAtPath: file.path)
        return contents
    }

    /// Keep an engraving under `key`, in the background. Atomic: a reader
    /// finds the whole entry or none.
    func keep(_ contents: EngravingArchive.Contents, under key: String) {
        let write = { [self] in
            try? FileManager.default.createDirectory(at: directory,
                                                     withIntermediateDirectories: true)
            guard (try? EngravingArchive.encode(contents).write(to: url(key), options: .atomic))
                    != nil else { return }
            evictBeyondBudget()
        }
        if let writeDelay {
            queue.asyncAfter(deadline: .now() + writeDelay, execute: write)
        } else {
            queue.async(execute: write)
        }
    }

    /// Waits for every `keep` asked for so far, in a store made with no
    /// write delay. For tests.
    func settle() { queue.sync {} }

    private func evictBeyondBudget() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
        else { return }
        var entries = files.compactMap { file -> (URL, Date, Int)? in
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else { return nil }
            return (file, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }
        var total = entries.reduce(0) { $0 + $1.2 }
        guard total > budget else { return }
        entries.sort { $0.1 < $1.1 }
        for (file, _, size) in entries where total > budget {
            try? fm.removeItem(at: file)
            total -= size
        }
    }
}
