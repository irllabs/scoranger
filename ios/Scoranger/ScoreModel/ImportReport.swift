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
        let skipped = (abc["tunes_skipped"] as? [[String: Any]] ?? [])
            .compactMap { $0["title"] as? String }
        guard !skipped.isEmpty else { return nil }
        let imported = (result["arrangements"] as? [Any])?.count ?? 1
        let total = imported + skipped.count
        let names = skipped.prefix(3).joined(separator: ", ")
            + (skipped.count > 3 ? " and \(skipped.count - 3) more" : "")
        return "Imported \(imported) of \(total) tunes. "
            + "\(skipped.count == 1 ? "This one" : "These") could not be read: \(names)."
    }
}
