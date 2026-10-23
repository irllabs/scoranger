import CoreGraphics
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// What a picture of part of a score IS, so the same request twice can be
/// recognised as the same request.
///
/// `document` is a string the canvas owns -- slug, version and layout -- and
/// NOT the `PDFPage`'s object identity. A pointer is not an identity here: a
/// page freed when the reader switches version can be replaced by a new page at
/// the same address, and the cache would then answer with the previous score's
/// music. A string that names what was engraved cannot do that.
struct RasterKey: Hashable {
    /// Which engraving: "<slug>/<version>/<layout>".
    let document: String
    let page: Int
    /// The window drawn, in surface points.
    let tile: CGRect
    /// Surface points per PDF point.
    let scale: CGFloat
    /// Pixels per surface point.
    let detail: CGFloat
}

/// Work already done, kept until the memory it cost is needed for newer work.
///
/// Least-recently-used out first, bounded in BYTES rather than in entries,
/// because what this holds is pictures and documents whose sizes differ by
/// three orders of magnitude and a count would mean nothing. The bound is the
/// point: the watchdog has killed this app for holding too many rasters (see
/// `PDFPageImage.maxRasterWidth`), and a cache with no ceiling would be the
/// next thing to kill it.
///
/// Two of these exist. `CanvasRasters` holds the pictures the score canvas
/// draws from; `AppState.engravings` holds the engravings themselves.
final class MemoCache<Key: Hashable, Value>: @unchecked Sendable {

    /// What a store holds unless it says otherwise. Sized against what one
    /// continuous strip costs: the two or three tiles drawn at depth are the
    /// expensive ones (a 900pt tile at 2x over a 900pt-tall strip is about
    /// 13MB), the dozen coarse ones are under half a megabyte each. 96MB holds
    /// a strip at two scales -- which is what opening a panel over the score
    /// and closing it again asks for -- and no more.
    static var defaultBudget: Int { 96 << 20 }

    private struct Entry {
        let value: Value
        let bytes: Int
        /// When it was last handed out. Monotonic within this store.
        var used: Int
    }

    private let budget: Int
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var clock = 0
    private var held = 0

    /// Hits and misses since the last `clear()`, for a diagnostic to read. Not
    /// published and not logged: a counter that publishes would invalidate the
    /// views this exists to stop invalidating.
    private var hitCount = 0
    private var missCount = 0

    var hits: Int { lock.withLock { hitCount } }
    var misses: Int { lock.withLock { missCount } }

    init(budget: Int = MemoCache.defaultBudget) {
        self.budget = budget
    }

    /// The picture for this key, drawn only if it is not already held.
    ///
    /// `cost` is asked what the drawn value takes up, because an image's
    /// backing store is not something to guess at from the size requested --
    /// `CGImage.bytesPerRow` rounds, and the rounding is what fills a budget.
    func value(for key: Key, cost: (Value) -> Int,
               make: () -> Value) -> Value {
        lock.lock()
        if var entry = entries[key] {
            clock += 1
            entry.used = clock
            entries[key] = entry
            hitCount += 1
            lock.unlock()
            return entry.value
        }
        missCount += 1
        lock.unlock()

        // Drawn OUTSIDE the lock: a raster is milliseconds of CoreGraphics and
        // holding a lock across it would serialise every canvas in the app
        // behind the slowest tile. Two threads racing the same key both draw
        // and the second overwrites the first, which costs one wasted raster
        // and never a wrong picture.
        let made = make()
        store(made, for: key, bytes: max(cost(made), 0))
        return made
    }

    /// The same, for work that has to be awaited -- an engrave, an export.
    ///
    /// A separate name rather than an `async` overload: two `value(for:...)`
    /// differing only in the effects of a closure is exactly the pair Swift
    /// resolves by context, and the context here is a `try await` that would
    /// silently pick either.
    ///
    /// A failure is NOT held. `make` throwing means there is no value, and a
    /// cache that remembered the failure would answer every later ask with it.
    func asyncValue(for key: Key, cost: (Value) -> Int,
                    make: () async throws -> Value) async rethrows -> Value {
        lock.lock()
        if var entry = entries[key] {
            clock += 1
            entry.used = clock
            entries[key] = entry
            hitCount += 1
            lock.unlock()
            return entry.value
        }
        missCount += 1
        lock.unlock()

        let made = try await make()
        store(made, for: key, bytes: max(cost(made), 0))
        return made
    }

    /// Whether `key` is held, without counting a hit or a miss or touching
    /// its age: a question about the cache, not a use of it.
    func contains(_ key: Key) -> Bool {
        lock.withLock { entries[key] != nil }
    }

    /// What is held for this key, WITHOUT making it.
    ///
    /// For a caller that must not block -- a view body deciding whether it can
    /// draw now or has to ask for the work and wait. A successful peek counts
    /// as a use, because it IS one: the picture was drawn on screen, and an
    /// LRU that did not know that would evict the pages the reader is looking
    /// at in favour of ones they scrolled past.
    func held(_ key: Key) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[key] else {
            missCount += 1
            return nil
        }
        clock += 1
        entry.used = clock
        entries[key] = entry
        hitCount += 1
        return entry.value
    }

    /// Hold a value that was made elsewhere -- by a caller that had to do the
    /// work off this store's own thread, which is every raster that must not
    /// happen inside a view body.
    func store(_ value: Value, for key: Key, bytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        // Bigger than the whole budget: it was handed to the caller and is
        // simply not held. Holding it would evict everything else to store
        // something that cannot be kept anyway.
        guard bytes <= budget else { return }
        if let previous = entries[key] { held -= previous.bytes }
        clock += 1
        entries[key] = Entry(value: value, bytes: bytes, used: clock)
        held += bytes
        evictDownToBudget()
    }

    /// What is held, for the tests and the diagnostics panel.
    var count: Int { lock.withLock { entries.count } }
    var bytes: Int { lock.withLock { held } }

    /// Forget one entry -- what a forced re-render of the same key needs.
    func forget(_ key: Key) {
        lock.withLock {
            if let gone = entries.removeValue(forKey: key) { held -= gone.bytes }
        }
    }

    func clear() {
        lock.withLock {
            entries = [:]
            held = 0
            hitCount = 0
            missCount = 0
        }
    }

    /// Least-recently-used out first. Called with the lock held.
    private func evictDownToBudget() {
        guard held > budget else { return }
        // Sorting is O(n log n) over a few dozen entries and happens only when
        // the budget is exceeded, which is once per scale change at worst.
        for (key, entry) in entries.sorted(by: { $0.value.used < $1.value.used }) {
            guard held > budget else { return }
            entries.removeValue(forKey: key)
            held -= entry.bytes
        }
    }
}

/// The canvas's store, under the name the rest of the app knows it by.
///
/// It exists because `ZoomableScroll.updateUIView` assigns
/// `host.rootView = AnyView(content())`, which re-renders the whole canvas --
/// deliberate, since a new raster scale or a new pen has to reach the pages --
/// and `updateUIView` runs whenever `ScorePagesView`'s body does. That view
/// holds `@EnvironmentObject var state: AppState`, so EVERY publish on AppState
/// redrew every page or tile from the PDF: the manifest poll landing, the ink
/// tool changing, a selection being made, a band opening.
///
/// In paged layout that is one or two `PDFPage.thumbnail` calls. In continuous
/// it is a `drawPDFPage` per tile over a strip seventeen thousand points wide.
/// The rebuild is left alone; the DRAWING is made cheap to repeat.
typealias RasterCache<Value> = MemoCache<RasterKey, Value>

private extension NSLock {
    func withLock<T>(_ work: () -> T) -> T {
        lock()
        defer { unlock() }
        return work()
    }
}

#if canImport(UIKit)
/// The canvas's own store, and the bytes an image costs.
enum CanvasRasters {
    static let shared = RasterCache<UIImage>()

    /// Four bytes a pixel, which is what an `UIGraphicsImageRenderer` image and
    /// a `PDFPage.thumbnail` both are. Measured from the CGImage rather than
    /// from the size asked for, because both round.
    static func bytes(of image: UIImage) -> Int {
        guard let cg = image.cgImage else {
            return Int(image.size.width * image.scale
                       * image.size.height * image.scale * 4)
        }
        return cg.bytesPerRow * cg.height
    }

    /// A memory warning empties it. The pictures can all be drawn again; being
    /// killed cannot be undone.
    ///
    /// Once, however many times it is asked: the caller is `startPolling`,
    /// which runs again whenever the engine is reconfigured, and a stack of
    /// identical observers would clear the cache once per call.
    @MainActor private static var observing = false

    @MainActor static func observeMemoryWarnings(
        andAlso alsoClear: @escaping @Sendable () -> Void = {}) {
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: nil) { _ in
                shared.clear()
                alsoClear()
            }
    }
}
#endif

/// Where off-main rasters run: a queue with a small, fixed width.
///
/// The first off-main rasters (0.8.0 build 195) were detached tasks, one per
/// tile or page as it appeared -- two dozen CoreGraphics renders at once on
/// opening a strip. On a device that is heat; under the gate's four
/// simulators it starved the engine's own thread, and the playback timeline
/// that the tray waits for stopped arriving inside three minutes. Two at a
/// time keeps the main thread free, which was the point, without taking the
/// machine.
enum RasterWork {
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.irllabs.scoranger.raster"
        queue.maxConcurrentOperationCount = 2
        // Utility, not user-initiated: a raster is a picture that will
        // replace the one standing in, and the embedded engine's thread --
        // which the tray and the transport wait on -- must win the cores
        // when they are short. On an idle device utility work starts at once.
        queue.qualityOfService = .utility
        return queue
    }()

    /// One raster per key at a time. A tile's `.task(id:)` is cancelled and
    /// restarted every time the page stack is re-rooted, which under load is
    /// often; without this each restart queued the same raster again, and a
    /// strip's two dozen tiles became a hundred renders.
    private static let lock = NSLock()
    private static var inFlight: [RasterKey: Task<UIImage, Never>] = [:]

    /// The image for `key`: what the cache holds, or one raster shared by
    /// everyone asking for it, made on the raster queue.
    static func image(for key: RasterKey, make: @escaping @Sendable () -> UIImage) async -> UIImage {
        if let held = CanvasRasters.shared.held(key) { return held }
        lock.lock()
        if let running = inFlight[key] {
            lock.unlock()
            return await running.value
        }
        let task = Task<UIImage, Never> {
            let made: UIImage = await withCheckedContinuation { continuation in
                queue.addOperation {
                    continuation.resume(returning: CanvasRasters.shared.value(
                        for: key, cost: CanvasRasters.bytes, make: make))
                }
            }
            lock.lock(); inFlight[key] = nil; lock.unlock()
            return made
        }
        inFlight[key] = task
        lock.unlock()
        return await task.value
    }
}
