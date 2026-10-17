import Foundation

/// What a reader is told after an import that did not take everything.
///
/// One ABC file from thesession.org is every setting of a tune, and one bad
/// setting used to fail the whole file ("Bad chord indicator: [[Ee"). Since
/// 0.19.0 the engine imports what it can read and names what it cannot
/// (`tunes_skipped` in the import report, `workspace.abc_report`); this is
/// the sentence that reaches the screen. Nil when there is nothing to say.
enum ImportReport {

    static func notice(from result: [String: Any]) -> String? {
        let abc = result["abc"] as? [String: Any] ?? [:]
        var sentences: [String] = []
        let skipped = (abc["tunes_skipped"] as? [[String: Any]] ?? [])
            .compactMap { $0["title"] as? String }
        if !skipped.isEmpty {
            let imported = (result["arrangements"] as? [Any])?.count ?? 1
            let total = imported + skipped.count
            sentences.append("Imported \(imported) of \(total) tunes. "
                + "\(skipped.count == 1 ? "This one" : "These") could not be read: "
                + "\(names(skipped)).")
        }
        // ABC words that could not be proved to belong to their notes are
        // left off and named, never placed one note out (0.21.0)
        let wordless = (abc["lyrics_withheld"] as? [[String: Any]] ?? [])
            .compactMap { $0["title"] as? String }
        if !wordless.isEmpty {
            sentences.append("The words of \(names(wordless)) could not be placed "
                             + "on their notes and were left off.")
        }
        // a transcription imported with its PDF beside it
        if let pass = TextPassReport.notice(from: result["text_pass"] as? [String: Any]) {
            sentences.append(pass)
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    private static func names(_ titles: [String]) -> String {
        titles.prefix(3).joined(separator: ", ")
            + (titles.count > 3 ? " and \(titles.count - 3) more" : "")
    }
}
