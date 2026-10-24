import Foundation

/// The transcription queue, as arithmetic.
///
/// There was no queue. `omrBusy` was one Bool and `omrPendingID` one optional
/// id: a second transcription started while one was running overwrote the
/// first's pointer, and whichever finished first cleared the flag for both.
/// The progress belonged to nobody — Ali opened one arrangement and read
/// "page 1 of 2 / Transcribing…" for a job belonging to a different one.
///
/// The contradiction is the bug, not just the misplacement. He put it exactly:
/// "if I go to a different arrangement that is PDF only and see that progress
/// bar, then it doesn't make sense that 'Make Editable' is not on." A score
/// showing transcription progress while its own Make editable reads off is
/// telling the reader two incompatible things. So there is ONE answer to
/// "what is this score's transcription doing", `OMRStatus?`, and the chip, the
/// Make editable switch, the Convert panel and the transport all read it. They
/// cannot drift, because there is nothing for them to drift from.
///
/// ONE AT A TIME, and the reason is the service. The OMR service is a single
/// Cloud Run instance running Audiveris, which is where all the time goes; it
/// already queues submissions itself (the poll loop reads `state == "queued"`
/// with how many are ahead) and answers 429 when it is saturated, which the
/// client backs off fifteen seconds for. Sending four at once would buy no
/// parallelism and pay for it in 429s. A client queue of one is the honest
/// mirror of a server that is serial anyway — and it is the only arrangement
/// under which the upload bar means something, because there is one upload.
enum OMRQueue {

    /// How many transcriptions run at once. See the note above: the work is
    /// serial on the service, so making it parallel here would only move the
    /// waiting somewhere the reader cannot see it.
    static let concurrency = 1

    /// One transcription, as the queue sees it. A projection of the pending
    /// import that carries it, so this arithmetic can be tested with no app.
    struct Entry: Identifiable, Equatable {
        let id: UUID
        /// The arrangement being transcribed. Nil when the transcription is
        /// BECOMING an arrangement — a PDF handed to the app from outside,
        /// which belongs to the library and to no score on screen.
        var arrangement: String?
        /// What it is called, for the queue's own listing.
        var name: String
        /// Running, rather than waiting its turn.
        var running: Bool
        /// The running job's own word for what it is doing.
        var stage: String
        /// nil = indeterminate.
        var fraction: Double?
    }

    /// Which id to start next, or nil when the slots are full or nothing is
    /// waiting. Oldest first: the queue is the order they were asked for.
    static func next(in entries: [Entry]) -> UUID? {
        guard entries.filter(\.running).count < concurrency else { return nil }
        return entries.first { !$0.running }?.id
    }

    /// What ONE arrangement's transcription is doing, or nil when that
    /// arrangement has none. The single answer every surface reads.
    ///
    /// A nil slug has no transcription of its own by definition: a reader
    /// looking at no score is not looking at a score being transcribed.
    static func status(ofArrangement slug: String?, in entries: [Entry]) -> OMRStatus? {
        guard let slug else { return nil }
        guard let entry = entries.first(where: { $0.arrangement == slug }) else { return nil }
        return status(of: entry, in: entries)
    }

    static func status(of id: UUID, in entries: [Entry]) -> OMRStatus? {
        guard let entry = entries.first(where: { $0.id == id }) else { return nil }
        return status(of: entry, in: entries)
    }

    private static func status(of entry: Entry, in entries: [Entry]) -> OMRStatus {
        if entry.running { return .running(stage: entry.stage, fraction: entry.fraction) }
        let waiting = entries.filter { !$0.running }
        let place = (waiting.firstIndex(where: { $0.id == entry.id }) ?? 0) + 1
        return .waiting(place: place, of: waiting.count)
    }

    /// The whole queue in one line, for a surface that shows all of it.
    /// Nil when nothing is in flight.
    static func summary(_ entries: [Entry]) -> String? {
        guard !entries.isEmpty else { return nil }
        let running = entries.filter(\.running).count
        let waiting = entries.count - running
        var bits: [String] = []
        if running > 0 { bits.append("\(running) transcribing") }
        if waiting > 0 { bits.append("\(waiting) waiting") }
        return bits.joined(separator: ", ")
    }
}

/// What the upload stage says, from the bytes URLSession has SENT.
///
/// `didSendBodyData` counts bytes handed to the network stack, not bytes the
/// service has received, and a scan of a few MB is handed over almost at
/// once: the bar read 100% straight away and then sat there while the
/// transfer finished and the service started, with "uploading…" under it
/// (Ali, 0.23.2). Once every byte is handed over there is no fraction left
/// to show, so the stage says what the wait is and the bar becomes a
/// spinner until the service accepts the job.
enum OMRUpload {
    static let sending = "uploading…"
    static let waitingForService = "sending to the converter…"

    static func stage(sent fraction: Double) -> (stage: String, fraction: Double?) {
        fraction < 1 ? (sending, fraction) : (waitingForService, nil)
    }
}

/// What a transcription is doing, from the point of view of the arrangement it
/// belongs to. Nil — no case at all — is "this score is not being
/// transcribed", which is what every surface needs to agree on.
enum OMRStatus: Equatable {
    /// Its turn has not come. `place` is 1-based within the waiting ones.
    case waiting(place: Int, of: Int)
    case running(stage: String, fraction: Double?)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    /// The bar's value, or nil for a spinner. A job that is waiting has no
    /// progress to show: nothing has started.
    var fraction: Double? {
        if case .running(_, let fraction) = self { return fraction }
        return nil
    }

    var showsSpinner: Bool { fraction == nil }

    /// The line under a title, and the words in the chip.
    ///
    /// "2nd of 3 waiting" rather than "queued": a reader who has asked for
    /// three transcriptions wants to know which one this is, and a position
    /// is the only part of the wait anyone can act on.
    var detail: String {
        switch self {
        case .waiting(let place, let total):
            return total <= 1 ? "waiting" : "waiting, \(ordinal(place)) of \(total)"
        case .running(let stage, _):
            return stage
        }
    }

    private func ordinal(_ n: Int) -> String {
        switch n % 100 {
        case 11, 12, 13: return "\(n)th"
        default:
            switch n % 10 {
            case 1: return "\(n)st"
            case 2: return "\(n)nd"
            case 3: return "\(n)rd"
            default: return "\(n)th"
            }
        }
    }
}
