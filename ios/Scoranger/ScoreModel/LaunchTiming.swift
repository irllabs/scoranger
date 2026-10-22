import Foundation
import QuartzCore
import os

/// Process start to the frame that first shows library rows, and where that
/// time went.
///
/// Ali, 2026-10-21: "There is a slight delay when I open the app before I can
/// see my pieces." The budget is 300 ms. One number answers it: from the
/// moment the kernel started the process to the render server committing the
/// first frame with a row in it. Everything else here is the breakdown of that
/// number.
///
/// The clock is the WALL clock, against the process start time the kernel
/// keeps (`kinfo_proc.p_starttime`). It is the only clock that reaches back to
/// before `main`, and dyld's work before `main` is part of what the reader
/// waits through. A wall-clock step inside one launch would spoil one reading;
/// a launch measured without its first 100 ms would spoil all of them.
///
/// Always on, because it is once per launch: a handful of clock reads and
/// signposts, which cost nothing unless Instruments is recording. The log line
/// at the end is how a device reports it. The JSON file is written only under
/// `-launchTiming`, which only the measurement script passes
/// (`ios/scripts/measure_launch.sh`).
final class LaunchTiming: @unchecked Sendable {

    static let shared = LaunchTiming()

    /// One interval of the launch, in milliseconds since the process started.
    /// A point in time is an interval with `end == start`.
    struct Span: Codable, Equatable {
        var name: String
        var start: Double
        var end: Double
    }

    private let lock = NSLock()
    private var spans: [Span] = []
    /// The two ends of a launch. The first is the number; the second is how
    /// long a tap on a row may wait for the engine behind it.
    private var rowsOnGlass: (ms: Double, rows: Int)?
    private var engineArrived: Double?
    private let processStart: Date?
    private let signposter = OSSignposter(subsystem: "com.irllabs.scoranger",
                                          category: "launch")
    private let logger = Logger(subsystem: "com.irllabs.scoranger", category: "launch")

    private init() {
        processStart = Self.processStartDate()
    }

    /// Milliseconds since the kernel started this process.
    var now: Double {
        guard let processStart else { return 0 }
        return Date().timeIntervalSince(processStart) * 1000
    }

    /// Whether the library has reached the glass AND the engine has answered.
    /// Spans after both are not part of the launch and are not kept.
    var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return rowsOnGlass != nil && engineArrived != nil
    }

    // MARK: - Recording

    func mark(_ name: String) {
        let t = now
        signposter.emitEvent("mark", "\(name, privacy: .public)")
        append(Span(name: name, start: t, end: t))
    }

    /// Time a piece of work that belongs to the launch. Outside the launch it
    /// only runs the work.
    func measure<T>(_ name: String, _ work: () throws -> T) rethrows -> T {
        guard !isFinished else { return try work() }
        let start = now
        let state = signposter.beginInterval("span", "\(name, privacy: .public)")
        defer {
            signposter.endInterval("span", state)
            append(Span(name: name, start: start, end: now))
        }
        return try work()
    }

    /// An interval that began at `start` (a reading of `now`) and ends now:
    /// for work that crosses an `await`, which `measure` cannot wrap.
    func record(_ name: String, since start: Double) {
        guard !isFinished else { return }
        append(Span(name: name, start: start, end: now))
    }

    private func append(_ span: Span) {
        lock.lock(); defer { lock.unlock() }
        // Bounded: an engine that never answers must not grow this for ever.
        guard rowsOnGlass == nil || engineArrived == nil, spans.count < 500 else { return }
        spans.append(span)
    }

    // MARK: - The end of the launch

    /// The library list has put rows into the view tree. The launch ends when
    /// the frame carrying them is committed: one turn of the run loop later
    /// the transaction being assembled is the one that draws them, and its
    /// completion fires when the render server has it (the same rule as
    /// `PerfMetrics.measureUntilPresented`).
    ///
    /// `rows` is an autoclosure because the list computes its rows from the
    /// whole manifest; once the launch is over this must cost nothing.
    @MainActor
    func libraryRowsAppeared(rows count: @autoclosure () -> Int) {
        guard !Self.rowsSeen else { return }
        let rows = count()
        guard rows > 0 else { return }
        Self.rowsSeen = true
        mark("library rows in view tree")
        DispatchQueue.main.async {
            CATransaction.begin()
            CATransaction.setCompletionBlock {
                LaunchTiming.shared.finish(rows: rows)
            }
            CATransaction.commit()
        }
    }

    @MainActor private static var rowsSeen = false

    /// The engine has answered with its own library, replacing the snapshot
    /// (or, with none, bringing the first rows). Once per launch.
    @MainActor
    func engineManifestArrived() {
        guard !Self.engineSeen else { return }
        Self.engineSeen = true
        let t = now
        mark("engine manifest")
        lock.lock()
        engineArrived = t
        let report = currentReport()
        lock.unlock()
        recordInPanel(PerfMetrics.Name.launchEngine, msSinceStart: t)
        report.map(publish)
    }

    @MainActor private static var engineSeen = false

    /// Into Settings > Diagnostics, so a reader can see the number on their
    /// own device with no Mac attached. Free unless that switch is on.
    private func recordInPanel(_ name: String, msSinceStart ms: Double) {
        let seconds = ms / 1000
        PerfMetrics.shared.record(name, start: PerfClock.now - seconds, duration: seconds)
    }

    private func finish(rows: Int) {
        let total = now
        lock.lock()
        guard rowsOnGlass == nil else { lock.unlock(); return }
        spans.append(Span(name: "library rows on glass", start: total, end: total))
        rowsOnGlass = (total, rows)
        let report = currentReport()
        lock.unlock()
        recordInPanel(PerfMetrics.Name.launchLibrary, msSinceStart: total)
        report.map(publish)
    }

    /// Under the lock. Nil until the rows are on the glass: that is the number
    /// every report carries.
    private func currentReport() -> Report? {
        rowsOnGlass.map { Report(totalMs: $0.ms, engineMs: engineArrived, rows: $0.rows, spans: spans) }
    }

    /// Logged when the rows land and again when the engine answers, if it
    /// answers later; written for the script under `-launchTiming`.
    private func publish(_ report: Report) {
        logger.log("SCORANGER-LAUNCH \(report.line, privacy: .public)")
        if ProcessInfo.processInfo.arguments.contains("-launchTiming") {
            report.write()
        }
    }

    /// What one launch measured: the number, and the spans that make it up.
    struct Report: Codable, Equatable {
        var totalMs: Double
        /// Process start to the engine's own library, once it has arrived.
        var engineMs: Double?
        var rows: Int
        var spans: [Span]

        /// One line for the unified log, readable on a device with
        /// `log stream --predicate 'eventMessage CONTAINS "SCORANGER-LAUNCH"'`.
        var line: String {
            let parts = spans.map { span in
                span.end == span.start
                    ? "\(span.name)@\(Int(span.start))"
                    : "\(span.name)@\(Int(span.start))+\(Int(span.end - span.start))"
            }
            let engine = engineMs.map { " engine_ms=\(Int($0.rounded()))" } ?? ""
            return "total_ms=\(Int(totalMs.rounded()))\(engine) rows=\(rows) | "
                + parts.joined(separator: " | ")
        }

        /// Where `-launchTiming` leaves the reading for the script to collect
        /// from the app's data container.
        static var fileURL: URL {
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appending(path: "launch-timing.json")
        }

        func write() {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(self) else { return }
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    // MARK: - The kernel's start time for this process

    private static func processStartDate() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec)
                    + TimeInterval(tv.tv_usec) / 1_000_000)
    }
}
