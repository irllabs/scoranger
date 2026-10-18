import Foundation

/// Where Search looks (0.20.0, design/SEARCH_0.20.md). Each is a tick box on
/// the Search screen, remembered between visits.
enum SearchSource: String, CaseIterable, Identifiable, Codable {
    /// Irish traditional music as ABC, through the site's own JSON interface.
    case thesession
    /// Scores on musescore.com, through the site itself in a web view: there
    /// is no API, and the terms forbid automated download.
    case musescore

    var id: String { rawValue }

    var title: String {
        switch self {
        case .thesession: return "thesession.org"
        case .musescore:  return "MuseScore"
        }
    }

    /// The one line under the tick box: what it finds and how.
    var line: String {
        switch self {
        case .thesession: return "Irish and folk tunes, imported as notation"
        case .musescore:  return "opens the site; sign in there to download as MusicXML"
        }
    }

    var identifier: String { "search-source-\(rawValue)" }

    static let `default`: Set<SearchSource> = [.thesession, .musescore]

    /// Stored as a comma-joined list under one key, so an unknown name
    /// written by a later build is dropped rather than failing the decode.
    static func decode(_ stored: String) -> Set<SearchSource> {
        let names = stored.split(separator: ",").map(String.init)
        let found = Set(names.compactMap(SearchSource.init(rawValue:)))
        return stored.isEmpty ? `default` : found
    }

    static func encode(_ sources: Set<SearchSource>) -> String {
        allCases.filter(sources.contains).map(\.rawValue).joined(separator: ",")
    }
}

/// thesession.org's URLs. The site's own structure, with `format=json`
/// appended: there is no separate API host.
enum TheSessionURL {
    static let host = "https://thesession.org"

    static func search(_ query: String, page: Int = 1) -> URL? {
        var parts = URLComponents(string: host + "/tunes/search")
        parts?.queryItems = [URLQueryItem(name: "q", value: query),
                             URLQueryItem(name: "format", value: "json")]
        if page > 1 { parts?.queryItems?.append(URLQueryItem(name: "page", value: String(page))) }
        return parts?.url
    }

    static func tune(_ id: Int) -> URL? {
        URL(string: host + "/tunes/\(id)?format=json")
    }

    /// The ABC of EVERY setting of a tune, as the site writes it: headers,
    /// `S:` naming each setting's page, `M:` and `L:` present. There is no
    /// per-setting download; `ABCSettings.select` cuts the file down.
    static func abc(_ id: Int) -> URL? {
        URL(string: host + "/tunes/\(id)/abc")
    }

    static func page(_ id: Int) -> URL? { URL(string: host + "/tunes/\(id)") }

    /// The site's search page, for the one case a search has to be finished
    /// in a browser.
    static func musescoreSearch(_ query: String) -> URL? {
        var parts = URLComponents(string: "https://musescore.com/sheetmusic")
        parts?.queryItems = [URLQueryItem(name: "text", value: query)]
        return parts?.url
    }
}

/// One hit from `/tunes/search?format=json`.
struct TheSessionHit: Identifiable, Equatable {
    let id: Int
    let name: String
    /// reel, jig, hornpipe ...
    let type: String?
    /// The name the search matched when it was not the tune's own.
    let alias: String?
}

/// A page of hits.
struct TheSessionSearch: Equatable {
    let query: String
    let hits: [TheSessionHit]
    let page: Int
    /// Nil when the site did not say (it omits `pages` and `total` when
    /// nothing matched).
    let pages: Int?
    let total: Int?

    var hasMore: Bool { page < (pages ?? 1) }

    /// "51 tunes", "1 tune", "No tunes".
    var countLine: String {
        guard let total, total > 0 else { return "No tunes" }
        return "\(total) tune\(total == 1 ? "" : "s")"
    }

    static func decode(_ data: Data) throws -> TheSessionSearch {
        let raw = try JSONDecoder().decode(RawSearch.self, from: data)
        return TheSessionSearch(
            query: raw.q,
            hits: raw.tunes.map { TheSessionHit(id: $0.id, name: $0.name, type: $0.type, alias: $0.alias) },
            page: raw.page, pages: raw.pages, total: raw.total)
    }

    private struct RawSearch: Decodable {
        let q: String
        let page: Int
        let pages: Int?
        let total: Int?
        let tunes: [RawHit]
    }

    private struct RawHit: Decodable {
        let id: Int
        let name: String
        let type: String?
        let alias: String?
    }
}

/// One setting of a tune: one member's way of playing it.
struct TheSessionSetting: Identifiable, Equatable {
    let id: Int
    /// As the site names it: "Edorian", "Gmajor".
    let key: String
    let member: String?
    let date: String?

    /// "E dorian": the site runs the tonic and the mode together.
    var keyLine: String {
        guard key.count > 1 else { return key }
        let tonic = key.prefix(while: { $0.isUppercase || $0 == "#" || $0 == "b" })
        let mode = key.dropFirst(tonic.count)
        return mode.isEmpty ? String(tonic) : "\(tonic) \(mode)"
    }
}

/// A tune's page: name, type, and every setting.
struct TheSessionTune: Equatable {
    let id: Int
    let name: String
    let type: String?
    let aliases: [String]
    let settings: [TheSessionSetting]

    static func decode(_ data: Data) throws -> TheSessionTune {
        let raw = try JSONDecoder().decode(RawTune.self, from: data)
        return TheSessionTune(
            id: raw.id, name: raw.name, type: raw.type, aliases: raw.aliases ?? [],
            settings: raw.settings.map {
                TheSessionSetting(id: $0.id, key: $0.key, member: $0.member?.name, date: $0.date)
            })
    }

    private struct RawTune: Decodable {
        let id: Int
        let name: String
        let type: String?
        let aliases: [String]?
        let settings: [RawSetting]
    }

    private struct RawSetting: Decodable {
        let id: Int
        let key: String
        let member: RawMember?
        let date: String?
    }

    private struct RawMember: Decodable {
        let name: String?
    }
}

/// Cutting the site's whole-tune ABC file down to the settings chosen.
///
/// `/tunes/N/abc` holds every setting as its own `X:` block, each carrying
/// an `S:` line that ends `#setting<id>`. Importing the file whole is what
/// the app has always done with a downloaded tune (38 arrangements of one
/// piece); this keeps the file as the site wrote it and drops the blocks
/// not asked for, renumbering `X:` so the result is still a valid file.
enum ABCSettings {

    /// The `X:` blocks of a file, as written, in order.
    static func blocks(of abc: String) -> [String] {
        let text = abc.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var blocks: [String] = []
        var current: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("X:") {
                if current.contains(where: { $0.hasPrefix("X:") }) {
                    blocks.append(current.joined(separator: "\n"))
                    current = []
                }
            }
            current.append(line)
        }
        if current.contains(where: { $0.hasPrefix("X:") }) {
            blocks.append(current.joined(separator: "\n"))
        }
        return blocks.map { $0.trimmingCharacters(in: .newlines) }
    }

    /// The setting a block is, from its `S:` line; nil when it has none.
    static func settingID(of block: String) -> Int? {
        for line in block.split(separator: "\n") where line.hasPrefix("S:") {
            guard let hash = line.lastIndex(of: "#") else { continue }
            let tail = line[line.index(after: hash)...]
            guard tail.hasPrefix("setting") else { continue }
            return Int(tail.dropFirst("setting".count))
        }
        return nil
    }

    /// The file holding only `ids`, in the site's order, `X:` renumbered
    /// from 1. An id the file does not hold is simply absent, and the
    /// result is nil when nothing is left -- the caller says so rather than
    /// importing an empty file.
    static func select(_ ids: Set<Int>, from abc: String) -> String? {
        let kept = blocks(of: abc).filter { block in
            settingID(of: block).map(ids.contains) ?? false
        }
        guard !kept.isEmpty else { return nil }
        let renumbered = kept.enumerated().map { index, block -> String in
            var lines = block.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            if let x = lines.firstIndex(where: { $0.hasPrefix("X:") }) {
                lines[x] = "X: \(index + 1)"
            }
            return lines.joined(separator: "\n")
        }
        return renumbered.joined(separator: "\n\n") + "\n"
    }

    /// Everything, line endings normalised.
    static func whole(_ abc: String) -> String {
        blocks(of: abc).joined(separator: "\n\n") + "\n"
    }

    /// A file name for the import, which is what names the arrangement
    /// when the tune does not name itself (it always does, here).
    static func fileName(tune: String, settingCount: Int) -> String {
        let safe = tune.replacingOccurrences(of: "/", with: "-")
        return settingCount == 1 ? "\(safe).abc" : "\(safe) (\(settingCount) settings).abc"
    }
}

/// What a reader is told after importing settings from a search (0.22.0).
///
/// An import files a tune under the piece of its title, and joins one that
/// already has it. Ali imported one setting of a tune he had imported whole
/// before and read the piece's 28 arrangements as "it imported all of them".
/// So the sentence says which piece the settings went to, and when that piece
/// already had arrangements, how many it has now.
enum SearchImport {
    static func sentence(count: Int, slug: String, manifest: Manifest?) -> String {
        let settings = count == 1 ? "1 setting" : "\(count) settings"
        guard let piece = manifest?.pieces?.first(where: { $0.arrangements.contains(slug) }) else {
            return "Imported \(settings)."
        }
        let total = piece.arrangements.count
        if total <= count {
            return "Imported \(settings) as the piece \(piece.name)."
        }
        return "Added \(settings) to \(piece.name), which now has \(total) arrangements."
    }
}
