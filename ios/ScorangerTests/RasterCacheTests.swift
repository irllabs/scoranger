import CoreGraphics
import XCTest

/// The store that stops the canvas redrawing itself from the PDF every time
/// AppState publishes anything.
///
/// The interesting behaviour is not "it remembers". It is what it does when it
/// cannot remember everything: this app has been killed by the watchdog for
/// holding too many rasters, so a cache that grows without a ceiling would be
/// a worse bug than the one it fixes. The eviction order and the byte
/// accounting are what these assert.
final class RasterCacheTests: XCTestCase {

    private func key(_ name: String, x: CGFloat = 0,
                     scale: CGFloat = 1, detail: CGFloat = 2) -> RasterKey {
        RasterKey(document: name, page: 0,
                  tile: CGRect(x: x, y: 0, width: 900, height: 500),
                  scale: scale, detail: detail)
    }

    // MARK: - Remembering

    func testTheSecondAskDoesNotDrawAgain() {
        let cache = RasterCache<Int>()
        var draws = 0
        let a = cache.value(for: key("s"), cost: { _ in 10 }) { draws += 1; return 7 }
        let b = cache.value(for: key("s"), cost: { _ in 10 }) { draws += 1; return 9 }
        XCTAssertEqual(a, 7)
        XCTAssertEqual(b, 7, "the held picture, not a fresh one")
        XCTAssertEqual(draws, 1)
        XCTAssertEqual(cache.hits, 1)
        XCTAssertEqual(cache.misses, 1)
    }

    /// Asking whether something is held is not a use of it: no hit, no miss,
    /// and its place in the eviction order is unchanged.
    func testContainsIsNotAUse() {
        let cache = MemoCache<String, Int>(budget: 2)
        cache.store(1, for: "old", bytes: 1)
        cache.store(2, for: "new", bytes: 1)
        XCTAssertTrue(cache.contains("old"))
        XCTAssertFalse(cache.contains("absent"))
        XCTAssertEqual(cache.hits, 0)
        XCTAssertEqual(cache.misses, 0)
        cache.store(3, for: "newest", bytes: 1)
        XCTAssertFalse(cache.contains("old"), "contains() made the oldest entry look recent")
        XCTAssertTrue(cache.contains("new"))
    }

    /// Every field of the key names something that changes the picture, so
    /// each on its own has to miss. A key that ignored `scale` would answer a
    /// zoomed-in canvas with the zoomed-out raster.
    func testEveryPartOfTheKeyIdentifiesADifferentPicture() {
        let cache = RasterCache<Int>()
        var draws = 0
        let make = { draws += 1; return draws }
        _ = cache.value(for: key("s"), cost: { _ in 10 }, make: make)
        _ = cache.value(for: key("other"), cost: { _ in 10 }, make: make)
        _ = cache.value(for: key("s", x: 900), cost: { _ in 10 }, make: make)
        _ = cache.value(for: key("s", scale: 2), cost: { _ in 10 }, make: make)
        _ = cache.value(for: key("s", detail: 0.35), cost: { _ in 10 }, make: make)
        XCTAssertEqual(draws, 5)
        XCTAssertEqual(cache.count, 5)
    }

    /// The reason the key carries a document STRING and not the PDFPage's
    /// object identity: a page freed when the version changes can be replaced
    /// at the same address, and a pointer key would then serve the previous
    /// score's music.
    func testADifferentVersionOfTheSameScoreIsADifferentPicture() {
        let cache = RasterCache<String>()
        let v1 = RasterKey(document: "waltz/v001/continuous", page: 0,
                           tile: .zero, scale: 1, detail: 2)
        let v2 = RasterKey(document: "waltz/v002/continuous", page: 0,
                           tile: .zero, scale: 1, detail: 2)
        XCTAssertEqual(cache.value(for: v1, cost: { _ in 1 }) { "one" }, "one")
        XCTAssertEqual(cache.value(for: v2, cost: { _ in 1 }) { "two" }, "two")
    }

    // MARK: - The ceiling

    func testTheBudgetIsCountedInBytesNotEntries() {
        let cache = RasterCache<Int>(budget: 100)
        _ = cache.value(for: key("a"), cost: { _ in 30 }) { 1 }
        _ = cache.value(for: key("b"), cost: { _ in 30 }) { 2 }
        XCTAssertEqual(cache.bytes, 60)
        XCTAssertEqual(cache.count, 2)
    }

    func testTheLeastRecentlyUsedGoesFirst() {
        let cache = RasterCache<Int>(budget: 100)
        _ = cache.value(for: key("a"), cost: { _ in 40 }) { 1 }
        _ = cache.value(for: key("b"), cost: { _ in 40 }) { 2 }
        // touch a, so b is now the oldest use
        _ = cache.value(for: key("a"), cost: { _ in 40 }) { 99 }
        // c does not fit beside both
        _ = cache.value(for: key("c"), cost: { _ in 40 }) { 3 }

        var drew = false
        _ = cache.value(for: key("a"), cost: { _ in 40 }) { drew = true; return 0 }
        XCTAssertFalse(drew, "a was used most recently and should have been kept")

        var redrew = false
        _ = cache.value(for: key("b"), cost: { _ in 40 }) { redrew = true; return 0 }
        XCTAssertTrue(redrew, "b was the oldest and should have been evicted")
    }

    func testEvictionStopsAsSoonAsItFits() {
        let cache = RasterCache<Int>(budget: 100)
        _ = cache.value(for: key("a"), cost: { _ in 30 }) { 1 }
        _ = cache.value(for: key("b"), cost: { _ in 30 }) { 2 }
        _ = cache.value(for: key("c"), cost: { _ in 30 }) { 3 }
        _ = cache.value(for: key("d"), cost: { _ in 30 }) { 4 }
        XCTAssertLessThanOrEqual(cache.bytes, 100)
        XCTAssertEqual(cache.count, 3, "only enough was thrown away to fit")
    }

    /// One picture bigger than the whole budget is drawn and handed back, and
    /// never held: holding it would evict everything else to store something
    /// that cannot be kept anyway.
    func testAPictureBiggerThanTheBudgetIsNotHeld() {
        let cache = RasterCache<Int>(budget: 100)
        _ = cache.value(for: key("a"), cost: { _ in 30 }) { 1 }
        let huge = cache.value(for: key("huge"), cost: { _ in 400 }) { 42 }
        XCTAssertEqual(huge, 42)
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.bytes, 30, "the small one survived")
    }

    func testClearingEmptiesItAndTheCounters() {
        let cache = RasterCache<Int>(budget: 100)
        _ = cache.value(for: key("a"), cost: { _ in 30 }) { 1 }
        _ = cache.value(for: key("a"), cost: { _ in 30 }) { 1 }
        cache.clear()
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.bytes, 0)
        XCTAssertEqual(cache.hits, 0)
        XCTAssertEqual(cache.misses, 0)
    }

    // MARK: - Work that has to be awaited

    /// The engraving store. Keyed by a string, and asked for work that is
    /// `async throws` -- a Verovio engrave.
    func testAnAwaitedValueIsMadeOnceAndThenRemembered() async throws {
        let cache = MemoCache<String, String>(budget: 1000)
        var made = 0
        func engrave() async throws -> String { made += 1; return "pdf" }

        let first = try await cache.asyncValue(for: "waltz/v003/page",
                                               cost: { $0.count }, make: engrave)
        let second = try await cache.asyncValue(for: "waltz/v003/page",
                                                cost: { $0.count }, make: engrave)
        XCTAssertEqual(first, "pdf")
        XCTAssertEqual(second, "pdf")
        XCTAssertEqual(made, 1)
    }

    /// The layout is part of the key, which is the whole point: page and
    /// continuous are two engravings of one version, and toggling between them
    /// paid for a fresh one every time.
    func testTheLayoutIsPartOfTheKey() async throws {
        let cache = MemoCache<String, String>(budget: 1000)
        var made: [String] = []
        func engrave(_ what: String) async throws -> String {
            made.append(what); return what
        }
        _ = try await cache.asyncValue(for: "w/v003/page", cost: { $0.count }) {
            try await engrave("paged")
        }
        _ = try await cache.asyncValue(for: "w/v003/continuous", cost: { $0.count }) {
            try await engrave("strip")
        }
        _ = try await cache.asyncValue(for: "w/v003/page", cost: { $0.count }) {
            try await engrave("paged again")
        }
        XCTAssertEqual(made, ["paged", "strip"],
                       "going back to paged should not have engraved anything")
    }

    /// A failed engrave must not be remembered as the answer, or one bad
    /// render would make a version permanently unopenable.
    func testAFailureIsNotHeld() async {
        struct Boom: Error {}
        let cache = MemoCache<String, String>(budget: 1000)
        var attempts = 0
        for _ in 0..<2 {
            _ = try? await cache.asyncValue(for: "k", cost: { $0.count }) {
                attempts += 1
                throw Boom()
            }
        }
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(cache.count, 0)
    }

    /// A forced re-render is asked for when the file behind the key changed
    /// under it -- the one thing a key naming slug, version and layout cannot
    /// see.
    func testForgettingOneKeyLeavesTheRest() {
        let cache = RasterCache<Int>(budget: 1000)
        _ = cache.value(for: key("a"), cost: { _ in 30 }) { 1 }
        _ = cache.value(for: key("b"), cost: { _ in 30 }) { 2 }
        cache.forget(key("a"))
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.bytes, 30)
        var redrew = false
        _ = cache.value(for: key("a"), cost: { _ in 30 }) { redrew = true; return 9 }
        XCTAssertTrue(redrew)
    }

    /// The canvas draws from more than one thread over its life (a tile from a
    /// scroll, a page from a settle), so the store has to survive being asked
    /// from several at once without losing its accounting.
    func testConcurrentAsksKeepTheAccountingStraight() {
        let cache = RasterCache<Int>(budget: 1 << 20)
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            _ = cache.value(for: key("s", x: CGFloat(i % 20) * 900), cost: { _ in 100 }) { i }
        }
        XCTAssertEqual(cache.count, 20)
        XCTAssertEqual(cache.bytes, 2000)
    }
}
