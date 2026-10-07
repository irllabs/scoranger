import Foundation

/// What the Extract screen says and decides, with no view in it
/// (design/BOOK_EXTRACT_0.19.md §C). The engine does the extracting; this is
/// the arithmetic and the words around it, so they can be tested.
enum ExtractModel {

    /// A piece already in the library with this name, matched as the engine
    /// matches it (`resolve_piece`: case-insensitive, trimmed) -- because
    /// "New piece" called that goes into the one that exists.
    static func existingPiece(named name: String, in pieces: [PieceDoc]) -> PieceDoc? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return nil }
        return pieces.first { $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == wanted }
    }

    /// The line under "New piece".
    static func newPieceLine(name: String, pieces: [PieceDoc]) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "A new piece, named after the tune." }
        if let piece = existingPiece(named: trimmed, in: pieces) {
            return "You already have a piece called “\(piece.name)”, so it goes there."
        }
        return "A new piece called “\(trimmed)”."
    }

    /// Where the found list came from, in one phrase.
    static func source(of entries: [BookEntry], saved: Bool) -> String {
        if saved { return "Your tune list" }
        let kinds = Set(entries.compactMap(\.evidence))
        let names: [(String, String)] = [("bookmark", "From the book's bookmarks"),
                                         ("heading", "From the titles on its pages"),
                                         ("ocr", "Read from its scanned pages")]
        let said = names.filter { kinds.contains($0.0) }.map(\.1)
        guard let first = said.first else { return "Found in the book" }
        return ([first] + said.dropFirst().map { $0.prefix(1).lowercased() + $0.dropFirst() })
            .joined(separator: " and ")
    }

    static func extractTunesTitle(_ count: Int, busy: Bool = false) -> String {
        "\(busy ? "Extracting" : "Extract") \(count) tune\(count == 1 ? "" : "s")\(busy ? "…" : "")"
    }

    static func pagesText(from: Int, to: Int) -> String {
        from == to ? "page \(from)" : "pages \(from)–\(to)"
    }

    static func extractPagesTitle(from: Int, to: Int) -> String {
        "Extract " + pagesText(from: from, to: to)
    }

    /// The line under Start and End in Choose pages.
    static func rangeLine(from: Int?, to: Int?) -> String {
        switch (from, to) {
        case let (from?, to?): return "P" + pagesText(from: from, to: to).dropFirst()
        case (_?, nil):        return "Now its last page, then End."
        default:               return "Turn to the tune's first page, then press Start."
        }
    }

    /// The name Start fills in: the found tune that begins on that page, but
    /// only into a field that is empty or still holds an earlier fill.
    static func prefill(at page: Int, entries: [BookEntry], current: String,
                        lastFill: String?) -> String? {
        guard current.isEmpty || current == lastFill,
              let tune = entries.first(where: { $0.from == page }) else { return nil }
        return tune.title
    }

    /// "Added “Autumn Leaves” to Autumn Leaves."
    static func madeLine(name: String, piece: String) -> String {
        "Added “\(name)” to \(piece)."
    }
}

/// What is drawn ON the pages in Extract: the page Start and End act on, and
/// the span chosen. Nothing in the reader.
struct BookPageMarks: Equatable {
    /// 1-based.
    var current: Int?
    /// 1-based, inclusive.
    var span: ClosedRange<Int>?

    static let none = BookPageMarks()

    /// How a screen reader hears a page.
    func label(page: Int, of pages: Int) -> String {
        var text = "Page \(page) of \(pages)"
        if let span, span.contains(page) {
            text += page == span.lowerBound ? ", start of the range"
                : (page == span.upperBound ? ", end of the range" : ", in the range")
        }
        return text
    }
}
