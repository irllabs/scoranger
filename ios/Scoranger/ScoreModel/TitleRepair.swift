import Foundation

/// The offer to fix titles that were engraved wrong before the engine guarded
/// the way in.
///
/// `ScoreTitle` stops a poisoned title being SHOWN. It cannot touch what is
/// ENGRAVED, because that lives in the notation of versions already written --
/// so a library OMR'd before the fix still prints "v001.mxl" at the top of
/// every page and in every export. The engine's `repair-titles` corrects that
/// by adding a version; this decides when to offer it and what to say.
///
/// The offer is DERIVED, never remembered. A per-device flag ("we migrated
/// this library") is wrong twice over: it fans out across devices, so the same
/// library gets repaired again on the next iPad, and it makes a large edit --
/// a new version on forty arrangements -- happen at launch without anyone
/// asking for it. Reading the library instead means the offer exists exactly
/// while there is damage, on every device, with no state kept anywhere.
enum TitleRepair {

    /// The button says how many (§10): "Fix 3 titles", "Fix 1 title".
    static func buttonTitle(count: Int) -> String {
        count == 1 ? "Fix 1 title" : "Fix \(count) titles"
    }


    /// Whether one arrangement is engraving an internal file name.
    ///
    /// Mirrors `workspace.title_repairs`, including its exclusion: an
    /// arrangement whose latest version is still a PDF has no notation to
    /// write a correction into, and its title never came from a file anyway.
    static func needsRepair(title: String?, name: String, slug: String,
                            latestFile: String?) -> Bool {
        guard let latestFile, !latestFile.isEmpty,
              ScoreArtifact.kind(ofFile: latestFile) == .notation else { return false }
        guard let title, !title.trimmingCharacters(in: .whitespaces).isEmpty else {
            return false
        }
        guard ScoreTitle.isInternalArtifactName(title)
                || ScoreTitle.isSlugLike(title, slug: slug) else { return false }
        // and only when there is a name to put in its place -- an arrangement
        // nothing can name is reported by the engine, not silently retitled
        return ScoreTitle.arrangementName(title: title, name: name, slug: slug)
            != "Untitled arrangement"
    }

    static func affected(_ scores: [ScoreDoc]) -> [String] {
        scores.filter {
            needsRepair(title: $0.title, name: $0.name, slug: $0.slug,
                        latestFile: $0.versions.last?.file)
        }.map(\.slug)
    }

    /// The offer on the SCORE SCREEN, for the arrangement that is open: what
    /// the page prints now, and what fixing it would print. Nil when it needs
    /// nothing.
    ///
    /// Settings has offered the repair since 0.12, and it reaches nobody who
    /// is not looking for it: Ali photographed "v001.mxl" over The Star of
    /// County Down on 0.23.3 with "fix title" written beside it, six such
    /// arrangements in his library and the button in Settings the whole time.
    /// The page that prints the file name is where the reader sees it.
    static func offerOnScore(title: String?, name: String, slug: String,
                             latestFile: String?) -> (printed: String, proposed: String)? {
        guard needsRepair(title: title, name: name, slug: slug, latestFile: latestFile),
              let title else { return nil }
        return (title, ScoreTitle.arrangementName(title: title, name: name, slug: slug))
    }

    /// What the score screen's offer says.
    static func scoreOffer(printed: String, proposed: String) -> (summary: String, detail: String) {
        ("This page prints \u{201C}\(printed)\u{201D} as its title.",
         "Fixing it prints \u{201C}\(proposed)\u{201D} and adds a version you can step back from.")
    }

    /// What the offer says, or nil when there is nothing to offer.
    static func offer(count: Int) -> String? {
        guard count > 0 else { return nil }
        let what = count == 1 ? "1 arrangement has" : "\(count) arrangements have"
        return "\(what) a file name printed at the top of the page instead of a "
            + "title. Fixing them adds one version to each, which you can step "
            + "back from like any other."
    }

    /// What it says afterwards.
    static func outcome(repaired: Int, failed: Int) -> String {
        var lines: [String] = []
        switch repaired {
        case 0:  lines.append("Nothing needed fixing.")
        case 1:  lines.append("Fixed 1 arrangement.")
        default: lines.append("Fixed \(repaired) arrangements.")
        }
        if failed > 0 {
            lines.append("\(failed) could not be read and "
                         + (failed == 1 ? "was" : "were") + " left alone.")
        }
        return lines.joined(separator: " ")
    }
}
