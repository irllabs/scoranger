import Foundation

/// Every screen you can push to (NAV_MODAL_FREE_0.4.2 §1, §3).
///
/// Nothing floats. A destination is a screen, and a choice happens in place --
/// so what used to be a sheet is a case here, and what used to be an alert is
/// an inline reveal that needs no route at all.
///
/// The score view is deliberately NOT in this enum. It is presented over the
/// tabs rather than pushed into a stack, which is what lets its page, zoom and
/// selection survive going back to the library and returning (§8.6).
enum Route: Hashable {
    /// A piece and its arrangements (§3.1).
    case piece(String)
    /// One arrangement's actions -- the per-item screen the row's ☰ opens (§3.2).
    case arrangement(String)
    /// Where an arrangement (or a selection) should be filed (§3.3).
    case moveToPiece([String])
    /// Which pieces are about to become one, and what that costs. A screen
    /// rather than a confirm strip because combining cannot be undone and the
    /// consequences are several sentences, not one.
    case combinePieces([String])
    /// Which set lists an arrangement belongs to (§3.4).
    case setlistsFor(String)
    /// A set list, its running order, and what can be done to it (§3.5).
    case setlist(String)
    /// A SHARED set list, addressed by its Firestore id rather than a slug: it
    /// is not in the local manifest and has no slug to be addressed by
    /// (design/FIREBASE.md §4.2).
    case sharedSetlist(String)
    /// The one confirmation between a tapped invite link and joining (§6A.5).
    case joinSetlist(String)
    /// Which arrangements a set list holds.
    case addArrangements(String)
    /// The version history of an arrangement (§3.6).
    case versions(String)
    /// Parts and ranges.
    case parts(String)
    /// Title, composer, arranger, slug.
    case details(String)
    /// Settings, and its second layer (§6).
    case settings
    case settingsSection(String)
    /// A book, and the pages you might take out of it.
    case book(String)
    /// One tune of a book's contents, read in place: (book slug, entry id).
    /// A page like a set list's arrangement, but no arrangement exists -- it
    /// is the book's own pages from `from` to `to` (0.14.0).
    case bookEntry(String, String)
    /// Taking tunes out of a book: found and ticked, or marked with Start and
    /// End (0.19.0, design/BOOK_EXTRACT_0.19.md §C).
    case bookExtract(String)
    /// What a file shared into the app should become (0.14.0 §1). Carries
    /// nothing: the files wait on AppState.importOffer, as a folder's plan
    /// waits on AppState for `folderImport`.
    case importAs
    /// The plan for importing a whole exported folder, read before it is run.
    /// Carries nothing: the plan itself lives on AppState, because a route is
    /// a place and this one can only be reached by having just made one.
    case folderImport

    // 0.8: states the PANEL shows (design/DESIGN_SYSTEM.md §7.2). They are
    // routes because the panel is a stack of them, and because half of what
    // it shows used to be a pushed screen and keeps its builder.
    /// The library's Sort and Filter (L3, L4), and the ways to bring a score in.
    case sort
    case filter
    case importMenu
    /// A piece row's Arrangements, beside the row (L6).
    case pieceArrangements(String)
    /// The piece screen's panel at rest: details, sources, delete (P1).
    case thisPiece(String)
    /// The set list screen's panel at rest: tools, people, marks, delete (S1).
    case thisSetlist(String)
    /// Invite somebody to a shared set list (S4).
    case setlistInvite(String)

    /// Whether this route is a page on the table or a state of the panel.
    var presentation: Presentation {
        switch self {
        case .piece, .setlist, .sharedSetlist, .book, .bookEntry, .bookExtract, .importAs,
             .settings, .settingsSection:
            return .page
        case .arrangement, .moveToPiece, .combinePieces, .setlistsFor,
             .addArrangements, .versions,
             .parts, .details, .folderImport, .joinSetlist, .sort, .filter,
             .importMenu, .pieceArrangements, .thisPiece, .thisSetlist, .setlistInvite:
            return .panel
        }
    }

    enum Presentation { case page, panel }

    /// The noun the panel is headed by when the screen inside has no title of
    /// its own (§7.2: "headed by its name").
    var panelTitle: String {
        switch self {
        case .piece:            return "Piece"
        case .arrangement:      return "Arrangement"
        case .moveToPiece:      return "Move to piece"
        case .combinePieces:    return "Combine"
        case .setlistsFor:      return "Set lists"
        case .setlist:          return "Set list"
        case .sharedSetlist:    return "People"
        case .joinSetlist:      return "Join"
        case .addArrangements:  return "Add"
        case .versions:         return "Versions"
        case .parts:            return "Parts"
        case .details:          return "Details"
        case .settings, .settingsSection: return "Settings"
        case .book:             return "Book"
        case .bookEntry:        return "Tune"
        case .bookExtract:      return "Extract"
        case .importAs:         return "Import as"
        case .folderImport:     return "Import folder"
        case .sort:             return "Sort"
        case .filter:           return "Filter"
        case .importMenu:       return "Import"
        case .pieceArrangements: return "Arrangements"
        case .thisPiece:        return "This piece"
        case .thisSetlist:      return "This set list"
        case .setlistInvite:    return "Invite"
        }
    }

    /// What the back button says you are returning to. A back label that names
    /// the place is the difference between a stack you can trust and one you
    /// count taps out of.
    var backLabel: String {
        switch self {
        case .piece, .setlist, .sharedSetlist, .joinSetlist, .settings, .importAs:
            return "Library"
        case .bookEntry, .bookExtract:
            return "Book"
        case .arrangement, .moveToPiece, .combinePieces, .setlistsFor,
             .addArrangements,
             .versions, .parts, .details, .settingsSection, .folderImport, .book,
             .sort, .filter, .importMenu, .pieceArrangements, .thisPiece,
             .thisSetlist, .setlistInvite:
            return "Back"
        }
    }
}

/// Which of a row's actions decides how its ☰ behaves (§3.5).
///
/// > *if any action on the row needs a second screen, `☰` pushes; if they are
/// > all one tap, `☰` expands.*
///
/// Stated here so the rule is one line and testable, rather than a habit that
/// drifts between two view files.
enum RowMenuBehaviour: Equatable {
    /// Opens the item's own screen.
    case push
    /// Expands in place: every action is immediate and positional.
    case expand

    /// `needsATarget` means at least one action leads to a list of somewhere
    /// else to put this, or to more detail.
    static func forRow(needsATarget: Bool) -> RowMenuBehaviour {
        needsATarget ? .push : .expand
    }
}

extension Route {
    /// The same route, pointing at wherever its arrangement has since moved.
    ///
    /// `moves` is old-slug to new-slug; chains are followed, with a stop so a
    /// cycle cannot hang the screen.
    func following(_ moves: [String: String]) -> Route {
        guard !moves.isEmpty else { return self }
        func now(_ slug: String) -> String {
            var at = slug
            var hops = 0
            while let next = moves[at], hops < 8 { at = next; hops += 1 }
            return at
        }
        switch self {
        case .arrangement(let s):     return .arrangement(now(s))
        case .moveToPiece(let s):     return .moveToPiece(s.map { now($0) })
        // pieces, not arrangements: a piece slug is not rewritten by a
        // rename, so these follow nothing
        case .combinePieces:          return self
        case .setlistsFor(let s):     return .setlistsFor(now(s))
        case .addArrangements(let s): return .addArrangements(now(s))
        case .versions(let s):        return .versions(now(s))
        case .parts(let s):           return .parts(now(s))
        case .details(let s):         return .details(now(s))
        case .pieceArrangements(let s):  return .pieceArrangements(s)
        case .thisPiece(let s):          return .thisPiece(s)
        case .piece, .setlist, .sharedSetlist, .joinSetlist, .settings,
             .settingsSection, .folderImport, .book, .bookEntry, .bookExtract, .importAs,
             .sort, .filter, .importMenu, .thisSetlist, .setlistInvite:
            return self
        }
    }
}
