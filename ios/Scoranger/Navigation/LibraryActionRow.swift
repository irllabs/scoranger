import CoreGraphics
import Foundation

/// The four library-level actions, and how their row is laid out (§4C).
///
/// They were four large coloured panels on Home, taking two thirds of a screen
/// for four occasional actions. Home is gone; these move into My Library as a
/// compact row of bordered buttons under the search field, deliberately quiet:
/// the lists are what the screen is for.
enum LibraryQuickAction: String, CaseIterable, Identifiable {
    case importScore, importPhotos, importFolder, importBook

    var id: String { rawValue }

    /// The panels' old order, kept so the muscle memory survives the move --
    /// less Ask, which Ali had removed (#47): the score's own Ask button is
    /// where a question about an arrangement belongs, and the library's copy
    /// was a fourth button that spent most of its life dimmed.
    static let ordered: [LibraryQuickAction] = [.importScore, .importPhotos,
                                                .importFolder, .importBook]

    /// The two verbs these five actions actually are (§14.2). Three flavours
    /// of Import and two of New, which is why five permanent buttons was
    /// always a lot of toolbar for what they are.
    /// §15's order. Photos sits SECOND, and the divider after it is the
    /// meaning: the first two rows are one arrangement from one thing, the
    /// last two are a collection.
    ///
    /// There is no separate "image from Files" row. An image from Files is a
    /// Score file the way a PDF is, and the subtitle on Score is what makes it
    /// findable -- which is why every row keeps one.
    static let imports: [LibraryQuickAction] = [.importScore, .importPhotos,
                                                .importFolder, .importBook]

    /// Where the band rules off: after Photos.
    static let importsDividerAfter: LibraryQuickAction = .importPhotos

    /// How the action names itself INSIDE its band, where there is room for a
    /// word and no glyph to lean on. "Import" is the button above it, so the
    /// band says what KIND -- Score, Folder, Book -- rather than repeating the
    /// verb three times.
    /// The one line under each row (§15).
    ///
    /// It is not decoration: "or a picture -- from Files" is what keeps Score
    /// findable for someone looking to import a photograph they have already
    /// filed, now that there is no row of its own for it.
    var bandSubtitle: String {
        switch self {
        case .importScore:  return "MusicXML, ABC, MIDI, PDF, or a picture — from Files"
        case .importPhotos: return "a picture of the music, from your photo library"
        case .importFolder: return "a whole exported library"
        case .importBook:   return "a collection to take arrangements out of"
        }
    }

    var bandTitle: String {
        switch self {
        case .importScore:  return "Score"
        case .importPhotos: return "Photos"
        case .importFolder: return "Folder"
        case .importBook:   return "Book"
        }
    }

    /// Identifiers move with the actions. The `home-*` ids retire with Home,
    /// and `library-add` with the `+` that used to offer the same two things.
    /// `library-import-folder` and `library-import-book` keep the identifiers
    /// they had -- §14.3 says so in terms.
    ///
    /// `importScore`'s changed, and had to: it was `library-import`, which is
    /// now the VERB button on the row. Two elements with one identifier is a
    /// test that taps whichever SwiftUI happened to put first.
    var identifier: String {
        switch self {
        case .importScore:  return "library-import-score"
        case .importPhotos: return "library-import-photos"
        case .importFolder: return "library-import-folder"
        case .importBook:   return "library-import-book"
        }
    }

    var glyph: String {
        switch self {
        case .importScore:  return "arrow.down.to.line"
        case .importPhotos: return "photo.on.rectangle"
        case .importFolder: return "folder"
        case .importBook:   return "books.vertical"
        }
    }

    var title: String {
        switch self {
        // Short, because the row now holds five. "Import" keeps the label it
        // has always had -- the two new ones sit beside it under their own
        // glyphs (a folder, a stack of books), which is what says what they
        // take. Thirteen characters would not fit the button.
        case .importScore:  return "Import"
        case .importPhotos: return "Photos"
        case .importFolder: return "Folder"
        case .importBook:   return "Book"
        }
    }
}

/// The two verbs the row's left cluster collapses to (§14.3).
enum LibraryVerb: String, CaseIterable, Identifiable {
    case importing, creating

    var id: String { rawValue }

    /// `library-import` and `library-new` keep the identifiers the two
    /// single-purpose buttons had: they still open the same work, one tap
    /// further in, and everything that addressed them goes on working.
    var identifier: String {
        switch self {
        case .importing: return "library-import"
        case .creating:  return "library-new"
        }
    }

    var title: String {
        switch self {
        case .importing: return "Import"
        case .creating:  return "New"
        }
    }

    var glyph: String {
        switch self {
        case .importing: return "arrow.down.to.line"
        case .creating:  return "plus"
        }
    }
}

enum LibraryActionRow {
    /// 32pt controls with 6pt above and below.
    static let height: CGFloat = 44
    static let buttonHeight: CGFloat = 32
    /// Within a cluster; the clusters are held apart by `clusterGap` at least.
    static let gap: CGFloat = 8
    static let clusterGap: CGFloat = 16
    /// Between the search field above and the first row below.
    static let spaceAboveRow: CGFloat = 12
    static let spaceBelowRow: CGFloat = 16
    static let sidePadding: CGFloat = 20
    static let buttonPadding: CGFloat = 10

    /// Below this the labels do not fit beside the list controls, so the left
    /// cluster becomes icons. Sort keeps its value -- it is the one control
    /// whose label is an ANSWER rather than a name.
    static let compactBelow: CGFloat = 700

    static func isCompact(width: CGFloat) -> Bool {
        width > 0 && width < compactBelow
    }
}

// `LastOpened` lived here: the one piece of "recent" the app still kept, so
// the library's Ask button had something to open. Ask is gone from the library
// (#47) and nothing else read it, so it is gone too rather than left behind as
// a store nobody consults.
