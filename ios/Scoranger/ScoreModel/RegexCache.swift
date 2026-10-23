import Foundation

/// Compiled regular expressions, kept by pattern for the life of the process.
///
/// The MEI and SVG passes ask for the same few dozen patterns once per note,
/// verse or glyph, and compiling a pattern costs far more than matching it.
/// Opening "Espresso" (2678 fingering verses) compiled one for every verse and
/// spent 488 ms of the MEI passes doing it (simulator, Release, 2026-10-22).
///
/// `NSRegularExpression` is immutable and documented as safe to share between
/// threads, so one compiled instance serves every page the rasteriser draws at
/// once. A pattern that does not compile is not remembered: the caller's
/// `guard` handles nil exactly as it did when it compiled the pattern itself.
enum RegexCache {
    private struct Key: Hashable {
        let pattern: String
        let options: UInt
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var compiled: [Key: NSRegularExpression] = [:]
    /// A few patterns are built from data (an attribute name, an escaped
    /// label). None is unbounded today; the cap keeps a future one from
    /// growing the table for ever.
    private static let limit = 512

    static func regex(pattern: String,
                      options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        let key = Key(pattern: pattern, options: options.rawValue)
        lock.lock()
        if let hit = compiled[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        guard let made = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }
        lock.lock()
        if compiled.count >= limit { compiled.removeAll(keepingCapacity: true) }
        compiled[key] = made
        lock.unlock()
        return made
    }
}
