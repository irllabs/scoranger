import Foundation

/// One row of the library, and the derived facts shown on it.
///
/// Everything here is computed from the manifest the engine already publishes:
/// no tag store, no new fields, no engine change (NAVIGATION_SYSTEM.md §7).
struct LibraryRow: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    /// Small caps chips: "3 ARR", "OMR DRAFT", "UNFILED", "1 SOURCE".
    let chips: [Chip]
    /// Trailing meta, in mono: the version and when it last changed.
    let meta: String
    /// What the row sorts and indexes under.
    let sortName: String
    let composer: String
    let changed: String
    let arrangementCount: Int
    /// When it was added -- the first version's day -- for the second mono
    /// line on the row and the Date added sort [C10]. Empty when unknown.
    var added: String = ""
    /// The same, unformatted, for the sort.
    var addedRaw: String = ""
    /// What the filters read [C9]: the latest artifact's kind, the instruments
    /// in the parts snapshot, and the tags on the piece and its arrangements.
    var holding: ArtifactHolding? = nil
    var instruments: Set<String> = []
    var tags: Set<String> = []

    struct Chip: Equatable {
        let text: String
        let kind: Kind
        enum Kind: Equatable { case count, warning, plain }
    }
}

/// The library's own logic: what to show, in what order, under which letter.
///
/// Pure over the manifest so every rule can be stated in a test -- the sorts,
/// the derived filters, the alphabet rail and the search all decide what a
/// person sees, and none of them needs a screen to be checked.
enum LibraryModel {

    /// The rows a set of filters keeps [C9]. Pure, so the Filter panel can
    /// count what each capsule would keep with the same rule the list uses.
    /// Filters in one group widen (a row matching any of them passes that
    /// group); groups narrow (a row has to pass every group that has a
    /// filter on).
    static func filtered(_ rows: [LibraryRow], by filters: Set<LibraryFilter>,
                         manifest: Manifest) -> [LibraryRow] {
        guard !filters.isEmpty else { return rows }
        let inSetlist = Set((manifest.setlists ?? []).flatMap(\.arrangements))
        let piecesWithSetlisted = Set((manifest.pieces ?? [])
            .filter { !$0.arrangements.filter(inSetlist.contains).isEmpty }
            .map(\.slug))
        func passes(_ row: LibraryRow, _ filter: LibraryFilter) -> Bool {
            switch filter {
            case .type(let holding):     return row.holding == holding
            case .composer(let name):    return row.composer.caseInsensitiveCompare(name) == .orderedSame
            case .instrument(let name):  return row.instruments.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
            case .tag(let tag):          return row.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
            case .status(.unfiled):      return row.chips.contains { $0.text == "UNFILED" }
            case .status(.omrDrafts):    return row.chips.contains { $0.text == "OMR DRAFT" }
            case .status(.hasSources):   return row.chips.contains { $0.text.hasSuffix("SOURCE") }
            case .status(.inASetlist):   return piecesWithSetlisted.contains(row.id) || inSetlist.contains(row.id)
            }
        }
        let groups = Dictionary(grouping: filters, by: \.group)
        return rows.filter { row in
            groups.values.allSatisfy { inGroup in inGroup.contains { passes(row, $0) } }
        }
    }

    /// One capsule per value the rows actually have, with the count each
    /// would keep on its own (L4). Groups with nothing to offer are absent.
    struct FilterGroup: Identifiable {
        let group: LibraryFilter.Group
        let options: [(filter: LibraryFilter, count: Int)]
        var id: String { group.rawValue }
    }

    static func filterGroups(rows: [LibraryRow], manifest: Manifest) -> [FilterGroup] {
        var found: [LibraryFilter.Group: Set<LibraryFilter>] = [:]
        for row in rows {
            if let holding = row.holding { found[.type, default: []].insert(.type(holding)) }
            if !row.composer.isEmpty { found[.composer, default: []].insert(.composer(row.composer)) }
            for instrument in row.instruments { found[.instrument, default: []].insert(.instrument(instrument)) }
            for tag in row.tags { found[.tag, default: []].insert(.tag(tag)) }
        }
        found[.status] = Set(LibraryFilter.Status.allCases.map { LibraryFilter.status($0) })
        return LibraryFilter.Group.allCases.compactMap { group in
            guard let filters = found[group], !filters.isEmpty else { return nil }
            let options = filters
                .map { (filter: $0, count: filtered(rows, by: [$0], manifest: manifest).count) }
                .filter { $0.count > 0 || group == .status }
                .sorted { a, b in
                    if a.count != b.count { return a.count > b.count }
                    return a.filter.label.localizedCaseInsensitiveCompare(b.filter.label) == .orderedAscending
                }
            return options.isEmpty ? nil : FilterGroup(group: group, options: options)
        }
    }

    /// A day for a row's mono line [C10]: "today", "Tue" within the week,
    /// "3 Sep" this year, "3 Sep 2025" before. Empty for nothing.
    static func day(_ iso: String?, now: Date = Date()) -> String {
        guard let iso, let date = parse(iso) else { return "" }
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) { return "today" }
        if let week = cal.date(byAdding: .day, value: -6, to: now), date > week {
            let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEE"); return f.string(from: date)
        }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(cal.isDate(date, equalTo: now, toGranularity: .year) ? "d MMM" : "d MMM y")
        return f.string(from: date)
    }

    private static func parse(_ iso: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: iso) { return d }
        let plain = ISO8601DateFormatter()
        if let d = plain.date(from: iso) { return d }
        // The engine writes local timestamps without a zone in older libraries.
        let local = DateFormatter(); local.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return local.date(from: String(iso.prefix(19)))
    }

    // MARK: - Pieces

    static func pieceRows(manifest: Manifest,
                          arrangementTags: [String: [String]] = [:]) -> [LibraryRow] {
        let scores = Dictionary(uniqueKeysWithValues: manifest.scores.map { ($0.slug, $0) })
        return (manifest.pieces ?? []).map { piece in
            let arrangements = piece.arrangements.compactMap { scores[$0] }
            let firstAdded = arrangements.compactMap { $0.versions.first?.time ?? nil }.min() ?? ""
            // No composer is no composer. It used to read "unknown", which is
            // a word where a fact should be -- and after a PDF import, which
            // carries no metadata, EVERY row said it.
            //
            // The PIECE's own credit wins: a scan has no notation to carry one,
            // so for an imported library it is the only credit there is.
            let composer = (piece.composer?.isEmpty == false ? piece.composer! : nil)
                ?? arrangements.compactMap { $0.composer }.first { !$0.isEmpty }
                ?? ""
            let sources = arrangements.reduce(0) { $0 + ($1.sources?.count ?? 0) }
            // No count chip: the subtitle already says "3 arrangements" in
            // words, and saying it twice on one row is noise (0.4.1 §5). The
            // warning and plain chips stay -- they are facts you cannot read
            // anywhere else on the row.
            // What this piece HOLDS leads every other chip (0.6.3 #3, #4).
            // A library of imported PDFs and OMR'd notation looked identical
            // row by row, and it is the fact that decides whether anything
            // else on the row can be transposed, selected, asked about or
            // played -- so it goes ahead of where the tune is from.
            var chips = ArtifactTag.chips(
                files: arrangements.flatMap { $0.versions.map(\.file) })
            for tag in piece.tags ?? [] {
                chips.append(.init(text: tag, kind: .plain))
            }
            if sources > 0 {
                chips.append(.init(text: "\(sources) SOURCE", kind: .plain))
            }
            if arrangements.contains(where: isOMRDraft) {
                chips.append(.init(text: "OMR DRAFT", kind: .warning))
            }
            let latest = arrangements.compactMap { $0.versions.last?.time ?? nil }.max() ?? ""
            let version = arrangements.compactMap { $0.latestLabel }.last ?? ""
            // A piece hid the same fault the arrangement row did: it counts
            // what it holds, and a piece whose arrangements all have NO
            // versions has an empty `meta` too, so it read like any other.
            // Said only when there is nothing to open ANYWHERE in the piece --
            // one broken arrangement among three is not a broken piece, and a
            // piece holding nothing at all already says "0 arrangements".
            let nothingToOpen = !arrangements.isEmpty
                && arrangements.allSatisfy { $0.versions.isEmpty }
            return LibraryRow(
                id: piece.slug,
                title: piece.name,
                subtitle: [composer, "\(arrangements.count) "
                    + (arrangements.count == 1 ? "arrangement" : "arrangements"),
                           nothingToOpen ? "no versions" : ""]
                    .filter { !$0.isEmpty }.joined(separator: " · "),
                chips: chips,
                meta: [version, shortTime(latest)].filter { !$0.isEmpty }
                    .joined(separator: " · "),
                sortName: piece.name,
                composer: composer,
                changed: latest,
                arrangementCount: arrangements.count,
                added: day(firstAdded),
                addedRaw: firstAdded,
                holding: ArtifactTag.holding(ofScores: arrangements),
                instruments: instruments(of: arrangements),
                tags: Set((piece.tags ?? []) + arrangements.flatMap { arrangementTags[$0.slug] ?? [] }))
        }
    }

    /// The instruments a set of arrangements is scored for, from the parts
    /// snapshot of each one's latest version [C9]. A never-converted scan has
    /// no snapshot and matches no instrument; the counts show it.
    static func instruments(of scores: [ScoreDoc]) -> Set<String> {
        Set(scores.flatMap { score in
            (score.versions.last?.parts ?? []).map { part in
                (part.instrument?.isEmpty == false ? part.instrument! : part.name)
                    .trimmingCharacters(in: .whitespaces)
            }
        }.filter { !$0.isEmpty })
    }

    /// Arrangements filed under no piece. They have no `#N` -- a number is only
    /// meaningful inside a piece (§2) -- so the row shows no numeral and
    /// reserves no space for one.
    ///
    /// ## What the subtitle says, and why it changed (Ali, 2026-09-14 item 11)
    ///
    /// Two row kinds share the Pieces list. A PIECE row is a folder and says
    /// how many arrangements it holds; this row IS one arrangement. It used to
    /// say "20 versions", which put a version count where the row above it put
    /// an arrangement count -- "Under Paris Skies accordion Solo, 1 version"
    /// directly above "Une nuit, 0 arrangements" in the photographs -- and
    /// nothing on either row said which kind it was.
    ///
    /// The count was also a second copy of a fact already on the row: `meta`
    /// carries the latest version label (`v020`) on BOTH kinds. So the
    /// subtitle now names the KIND and the version fact stays where the piece
    /// row keeps it. Both rows then read the same way: what it is or holds,
    /// then the version and the day.
    ///
    /// ## Except when there is nothing in it
    ///
    /// An arrangement with NO versions has no `meta` either -- no label, no
    /// day -- so naming the kind and stopping made a broken row read exactly
    /// like a healthy one. Ali's device grew a "Morrison's jig" with zero
    /// versions that sat on "Opening…" for ever, and the row saying so is how
    /// a reader learns it is broken before opening it. So the state is said
    /// too, in the subtitle rather than as a chip: chips do not reach the
    /// row's accessibility label (`LRow.spoken` is title, subtitle, meta), so
    /// a chip-only warning is invisible to VoiceOver.
    static func unfiledRows(manifest: Manifest,
                            arrangementTags: [String: [String]] = [:]) -> [LibraryRow] {
        manifest.scores.filter { ($0.piece ?? "").isEmpty }.map { score in
            let firstAdded = (score.versions.first?.time ?? nil) ?? ""
            var chips = ArtifactTag.chips(files: score.versions.map(\.file))
            chips.append(.init(text: "UNFILED", kind: .warning))
            if isOMRDraft(score) { chips.append(.init(text: "OMR DRAFT", kind: .warning)) }
            return LibraryRow(
                id: score.slug,
                title: ScoreTitle.arrangementName(title: score.title, name: score.name,
                                                  slug: score.slug),
                subtitle: [score.composer ?? "", "Arrangement",
                           score.versions.isEmpty ? "no versions" : ""]
                    .filter { !$0.isEmpty }.joined(separator: " · "),
                chips: chips,
                meta: [score.latestLabel ?? "", shortTime((score.versions.last?.time ?? nil) ?? "")]
                    .filter { !$0.isEmpty }.joined(separator: " · "),
                sortName: ScoreTitle.arrangementName(title: score.title, name: score.name,
                                                     slug: score.slug),
                composer: score.composer ?? "",
                changed: (score.versions.last?.time ?? nil) ?? "",
                arrangementCount: 1,
                added: day(firstAdded),
                addedRaw: firstAdded,
                holding: ArtifactTag.holding(of: score),
                instruments: instruments(of: [score]),
                tags: Set(arrangementTags[score.slug] ?? []))
        }
    }

    // MARK: - Setlists

    /// Books: a collection is one row, and what it says about itself is how
    /// long it is. No chips -- a book has no arrangements of its own, which is
    /// exactly what distinguishes it from a piece.
    static func bookRows(manifest: Manifest) -> [LibraryRow] {
        (manifest.books ?? []).map { book in
            LibraryRow(id: book.slug,
                       title: book.name,
                       subtitle: book.pages.map { "\($0) pages" } ?? "",
                       chips: [],
                       meta: "",
                       sortName: book.name,
                       composer: "",
                       changed: "",
                       arrangementCount: 0)
        }
    }

    static func setlistRows(manifest: Manifest) -> [LibraryRow] {
        let scores = Dictionary(uniqueKeysWithValues: manifest.scores.map { ($0.slug, $0) })
        let pieces = manifest.pieces ?? []
        return (manifest.setlists ?? []).map { setlist in
            // The running order, named the way chat names it: piece #N. Our
            // setlists hold ARRANGEMENTS, not pieces (§2), so the subtitle has
            // to say which arrangement of which piece.
            let order = setlist.arrangements.compactMap { slug -> String? in
                guard let score = scores[slug] else { return nil }
                guard let piece = pieces.first(where: { $0.arrangements.contains(slug) }),
                      let index = piece.arrangements.firstIndex(of: slug) else {
                    return ScoreTitle.arrangementName(title: score.title,
                                                      name: score.name,
                                                      slug: score.slug)
                }
                return "\(piece.name) #\(index + 1)"
            }
            // the same wording pieces use, then the running order
            let count = setlist.arrangements.count
            let heading = "\(count) arrangement\(count == 1 ? "" : "s")"
            // A set list is a gig's running order, and what a player needs to
            // know before the gig is whether any of it is still a PDF (#4).
            var chips = ArtifactTag.chips(
                files: setlist.arrangements.compactMap { scores[$0] }
                    .flatMap { $0.versions.map(\.file) })
            chips.append(.init(text: "ORDERED", kind: .plain))
            return LibraryRow(
                id: setlist.slug,
                title: setlist.name,
                subtitle: ([heading] + order).joined(separator: " · "),
                chips: chips,
                meta: "",
                sortName: setlist.name,
                composer: "",
                changed: "",
                arrangementCount: setlist.arrangements.count)
        }
    }

    // MARK: - Sorting, filtering, searching

    static func sorted(_ rows: [LibraryRow], by sort: LibrarySort) -> [LibraryRow] {
        switch sort {
        case .name:
            return rows.sorted { $0.sortName.localizedCaseInsensitiveCompare($1.sortName) == .orderedAscending }
        case .composer:
            // A row with no composer sorts LAST. Empty string sorts first
            // otherwise, which would put every un-credited piece above the
            // named ones -- the opposite of what sorting by composer is for.
            return rows.sorted { a, b in
                if a.composer.isEmpty != b.composer.isEmpty { return !a.composer.isEmpty }
                let c = a.composer.localizedCaseInsensitiveCompare(b.composer)
                if c != .orderedSame { return c == .orderedAscending }
                return a.sortName.localizedCaseInsensitiveCompare(b.sortName) == .orderedAscending
            }
        case .recent:
            // newest first; a row that has never changed sorts last
            return rows.sorted { $0.changed > $1.changed }
        case .added:
            // newest first [C10]; a row with no first version sorts last
            return rows.sorted { $0.addedRaw > $1.addedRaw }
        case .arrangements:
            return rows.sorted {
                $0.arrangementCount == $1.arrangementCount
                    ? $0.sortName.localizedCaseInsensitiveCompare($1.sortName) == .orderedAscending
                    : $0.arrangementCount > $1.arrangementCount
            }
        }
    }

    /// Client-side search over what the manifest holds: names, composers and
    /// tags (§7). Case- and diacritic-insensitive, matching anywhere in the
    /// field, because a person searching "tango" should find "Libertango".
    ///
    /// Tags are in here rather than behind a filter control: they are already
    /// on the row as chips, and typing "Serbia" to see the Serbian tunes needs
    /// no new affordance to learn.
    static func searched(_ rows: [LibraryRow], query: String) -> [LibraryRow] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return rows }
        return rows.filter { row in
            ([row.title, row.subtitle, row.composer] + row.chips.map(\.text)).contains {
                $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    /// The letter a row files under. Anything not starting with a letter goes
    /// to "#", which is what the rail's last entry is for.
    static func indexLetter(for row: LibraryRow) -> String {
        let folded = row.sortName.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                          locale: .current)
        guard let first = folded.first, first.isLetter else { return "#" }
        return String(first).uppercased()
    }

    static func grouped(_ rows: [LibraryRow]) -> [(letter: String, rows: [LibraryRow])] {
        var buckets: [String: [LibraryRow]] = [:]
        for row in rows { buckets[indexLetter(for: row), default: []].append(row) }
        return buckets.keys.sorted { a, b in
            if a == "#" { return false }
            if b == "#" { return true }
            return a < b
        }.map { ($0, buckets[$0] ?? []) }
    }

    /// Every letter of the rail, and whether it has anything under it.
    static let alphabet: [String] =
        (UnicodeScalar("A").value...UnicodeScalar("Z").value)
            .compactMap { UnicodeScalar($0).map { String(Character($0)) } } + ["#"]

    static func lettersPresent(in rows: [LibraryRow]) -> Set<String> {
        Set(rows.map(indexLetter(for:)))
    }

    // MARK: - Derived facts

    /// An OMR draft: a scan's transcription, not edited since. In the app a
    /// scan arrives as the page (`import-pdf`) and is transcribed into a NEW
    /// version whose op is `omr` (bridge `add-version-from-file`), so the draft
    /// is the arrangement whose CURRENT version is that transcription.
    ///
    /// It used to be "one version, op `import`", the shape of the desktop
    /// route (Audiveris, then `scor import`). In the app that labelled every
    /// MusicXML, ABC and MIDI import a scan, and never labelled a real one.
    static func isOMRDraft(_ score: ScoreDoc) -> Bool {
        let current = score.versions.first { $0.id == score.latest } ?? score.versions.last
        return current?.op == "omr"
    }

    /// Whatever time the engine wrote, shortened for a row's trailing edge.
    /// The engine's stamps are ISO-8601, so the date and the clock split on "T".
    static func shortTime(_ stamp: String) -> String {
        guard !stamp.isEmpty else { return "" }
        let parts = stamp.split(separator: "T")
        guard parts.count == 2 else { return stamp }
        return String(parts[1].prefix(5))
    }
}

// MARK: - What the library says it holds (L11, #39)

extension LibraryModel {

    /// The count under "My library", as a phrase rather than a bare number --
    /// and counting the rows that are actually on screen, by what they are.
    ///
    /// It read "My library 1", which names nothing. Then it read "2 pieces · 2
    /// arrangements" over two rows that were both UNFILED ARRANGEMENTS (#39):
    /// an arrangement with no piece is not a piece, and the total counted the
    /// same music twice under two names. Neither number matched what the
    /// reader could see.
    ///
    /// So the header counts top-level ROWS by their true kind, and nothing
    /// else: "1 piece · 3 unfiled" over four rows. The cross-total is gone on
    /// purpose -- arrangements inside a piece are visible when you open it,
    /// and a number in the header that does not match the rows under it is
    /// the whole of what went wrong here.
    static func countPhrase(segment: LibrarySegment, rows: [LibraryRow]) -> String {
        switch segment {
        case .pieces:
            guard !rows.isEmpty else { return "No pieces yet" }
            let unfiled = rows.filter(isUnfiled).count
            let pieces = rows.count - unfiled
            switch (pieces, unfiled) {
            case (0, let u):  return "\(plural(u, "unfiled arrangement"))"
            case (let p, 0):  return plural(p, "piece")
            case (let p, let u): return "\(plural(p, "piece")) · \(u) unfiled"
            }
        case .setlists:
            guard !rows.isEmpty else { return "No set lists yet" }
            return plural(rows.count, "set list")
        case .books:
            guard !rows.isEmpty else { return "No books yet" }
            return plural(rows.count, "book")
        }
    }

    /// An arrangement that belongs to no piece. The row says so itself -- the
    /// same signal the Unfiled filter reads, so the header and the filter can
    /// never disagree about what is unfiled.
    static func isUnfiled(_ row: LibraryRow) -> Bool {
        row.chips.contains { $0.text == "UNFILED" }
    }

    /// "1 piece", "2 pieces" -- the noun is never dropped and never mis-agreed.
    static func plural(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}

// MARK: - What the list is showing right now (#42)

/// Loading is not emptiness.
///
/// At launch the manifest is nil and the engine has not answered yet, which
/// looks exactly like a library with nothing in it -- so the empty state, with
/// its "No music yet" and its Import button, flashed up on every launch of a
/// device that is full of music. The score view already knew the difference
/// (`AppState.libraryLoaded`); the library itself did not.
enum LibraryListState: Equatable {
    /// Still looking. Nothing is known yet, so nothing may be claimed.
    case loading
    /// Looked, and there is genuinely nothing here.
    case empty
    /// There is music, but not any that matches what was typed.
    case noMatches
    case rows
}

extension LibraryModel {

    /// What an EMPTY segment says, and the one button that resolves it.
    ///
    /// It used to be a two-way choice -- pieces, or everything else -- so the
    /// Books segment said "No set lists yet" and offered "New set list". A
    /// reader whose book import had just failed was told, in the place they
    /// went looking for it, about a feature they had not asked for. Three
    /// segments, three states, decided here so a fourth cannot inherit the
    /// wrong copy.
    struct EmptyState: Equatable {
        var systemImage: String
        var title: String
        var message: String
        var actionTitle: String
    }

    static func emptyState(segment: LibrarySegment) -> EmptyState {
        switch segment {
        case .pieces:
            return EmptyState(
                systemImage: "music.note.list",
                title: "No music yet",
                message: "Import a score, or make a blank arrangement and ask.",
                actionTitle: "Import")
        case .setlists:
            return EmptyState(
                systemImage: "list.bullet",
                title: "No set lists yet",
                message: "A set list is a gig's running order of arrangements.",
                actionTitle: "New set list")
        case .books:
            return EmptyState(
                systemImage: "books.vertical",
                title: "No books yet",
                message: "A book is a collection you take arrangements out of "
                       + "— a fake book, a method book. Import a PDF of one.",
                actionTitle: "Import book")
        }
    }

    static func listState(loaded: Bool, rows: Int, pendingImports: Int,
                          isFiltered: Bool) -> LibraryListState {
        if rows > 0 || pendingImports > 0 { return .rows }
        // An import in flight is content: the row for it is already on screen.
        guard loaded else { return .loading }
        return isFiltered ? .noMatches : .empty
    }
}
