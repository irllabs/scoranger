import Foundation
import os

/// The library as the engine last projected it, read straight from disk.
///
/// `workspace/manifest.json` is written by `workspace.rebuild_manifest` every
/// time the app asks the engine for the library, so on any launch after the
/// first it holds the library as the reader last saw it. Reading it takes
/// milliseconds. The engine takes seconds to start -- an interpreter, then
/// music21 -- and the library used to wait for it on every launch: 3.8 s
/// median on the simulator with 141 arrangements (`LaunchTiming`).
///
/// For DISPLAY ONLY. The database stays the authority: nothing is decided or
/// written from a snapshot (`AppState.showingSnapshot`), every action a row
/// offers goes through the engine, which takes calls in order behind its own
/// start-up, and the engine's first manifest replaces the snapshot as soon as
/// it arrives. No file is no snapshot, and the list waits for the engine as it
/// always did.
enum LibrarySnapshot {

    static func fileURL(workspace: URL) -> URL {
        workspace.appending(path: "manifest.json")
    }

    /// Start reading on another thread. Called from `ScorangerApp.init`: UIKit
    /// spends about 50 ms on the main thread setting up the scene before
    /// `AppState` exists to ask, and the decode (18 ms on the simulator for
    /// 141 arrangements) fits inside that.
    static func prefetch(from url: URL) {
        let pending = Pending()
        lock.lock(); prefetched = pending; lock.unlock()
        DispatchQueue.global(qos: .userInteractive).async {
            pending.finish(read(from: url))
        }
    }

    /// What `prefetch` read, waiting for it if it has not finished; reads the
    /// file here if nothing was prefetched. Hands the result over once.
    static func collect(from url: URL) -> Manifest? {
        lock.lock(); let pending = prefetched; prefetched = nil; lock.unlock()
        return pending?.wait() ?? read(from: url)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var prefetched: Pending?

    private final class Pending: @unchecked Sendable {
        private let done = DispatchSemaphore(value: 0)
        private var manifest: Manifest?
        func finish(_ manifest: Manifest?) { self.manifest = manifest; done.signal() }
        func wait() -> Manifest? { done.wait(); return manifest }
    }

    /// Decoded as `LocalEngine` decodes the engine's answer, so a snapshot and
    /// the engine's manifest of the same library compare equal and the
    /// handover redraws nothing.
    static func read(from url: URL) -> Manifest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(Manifest.self, from: data)
        } catch {
            // A file the engine wrote that the app cannot read is drift
            // between the two, worth finding in a device log; the launch
            // itself goes on and waits for the engine.
            Logger(subsystem: "com.irllabs.scoranger", category: "launch")
                .error("library snapshot unreadable: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
