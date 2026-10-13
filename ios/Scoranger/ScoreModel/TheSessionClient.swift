import Foundation

/// What Search asks of thesession.org. A protocol so the UI tests run against
/// the captured answers in `FixtureTuneFinder` rather than the live site.
protocol TuneFinder: Sendable {
    func search(_ query: String, page: Int) async throws -> TheSessionSearch
    func tune(_ id: Int) async throws -> TheSessionTune
    /// The ABC of every setting, as the site writes it.
    func abc(ofTune id: Int) async throws -> String
}

enum TuneFinderError: LocalizedError {
    case badURL
    case status(Int)
    case notText

    var errorDescription: String? {
        switch self {
        case .badURL:            return "That search could not be turned into a request."
        case .status(let code):  return "thesession.org answered \(code)."
        case .notText:           return "thesession.org sent something that is not ABC."
        }
    }
}

/// thesession.org over its own JSON interface (0.20.0).
///
/// MANNERS, because this is somebody's site and not a service sold to us:
/// a User-Agent that names the app and where to complain; one request per
/// search the reader SUBMITS, never per keystroke (robots.txt asks for a
/// 10-second crawl delay); and a tune's page and ABC fetched once a session.
final class TheSessionClient: TuneFinder, @unchecked Sendable {
    static let userAgent = "Scoranger/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "0") (iPad; +https://github.com/irllabs/scoranger)"

    private let cache = Cache()

    private actor Cache {
        var tunes: [Int: TheSessionTune] = [:]
        var abc: [Int: String] = [:]
        func tune(_ id: Int) -> TheSessionTune? { tunes[id] }
        func keep(_ tune: TheSessionTune) { tunes[tune.id] = tune }
        func abc(_ id: Int) -> String? { abc[id] }
        func keep(abc text: String, for id: Int) { abc[id] = text }
    }

    func search(_ query: String, page: Int) async throws -> TheSessionSearch {
        guard let url = TheSessionURL.search(query, page: page) else { throw TuneFinderError.badURL }
        return try TheSessionSearch.decode(try await fetch(url))
    }

    func tune(_ id: Int) async throws -> TheSessionTune {
        if let held = await cache.tune(id) { return held }
        guard let url = TheSessionURL.tune(id) else { throw TuneFinderError.badURL }
        let tune = try TheSessionTune.decode(try await fetch(url))
        await cache.keep(tune)
        return tune
    }

    func abc(ofTune id: Int) async throws -> String {
        if let held = await cache.abc(id) { return held }
        guard let url = TheSessionURL.abc(id) else { throw TuneFinderError.badURL }
        guard let text = String(data: try await fetch(url), encoding: .utf8) else {
            throw TuneFinderError.notText
        }
        await cache.keep(abc: text, for: id)
        return text
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        // a fresh ephemeral session, as the chat and OMR paths do: a pooled
        // connection the far end has dropped fails every retry until discarded
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw TuneFinderError.status(code) }
        return data
    }
}

/// The captured answers for one tune, for the tests: `-stubTheSession`
/// makes every search find Drowsy Maggie's page of results and every tune
/// be Drowsy Maggie. The answers are the site's own, fetched 2026-10-12
/// (ios/ScorangerTests/Fixtures/thesession-*, which the unit tests read),
/// and ride into the app in `samples-seed/` -- the Debug-only folder the
/// test library is seeded from (project.yml's copy phase), absent from
/// Release builds.
struct FixtureTuneFinder: TuneFinder {
    let searchData: Data
    let noneData: Data
    let tuneData: Data
    let abcText: String

    /// The app's copy, in the Debug-only seed folder.
    static var seedFolder: URL? {
        Bundle.main.resourceURL?.appending(path: "samples-seed")
    }

    /// `folder` holds the four files: the app's `samples-seed`, or the unit
    /// test bundle's Fixtures.
    init?(folder: URL?) {
        guard let folder else { return nil }
        let search = folder.appending(path: "thesession-search-drowsy.json")
        let none = folder.appending(path: "thesession-search-none.json")
        let tune = folder.appending(path: "thesession-tune-27.json")
        let abc = folder.appending(path: "thesession-tune-27.abc")
        guard let s = try? Data(contentsOf: search), let n = try? Data(contentsOf: none),
              let t = try? Data(contentsOf: tune), let a = try? String(contentsOf: abc, encoding: .utf8)
        else { return nil }
        searchData = s; noneData = n; tuneData = t; abcText = a
    }

    func search(_ query: String, page: Int) async throws -> TheSessionSearch {
        try await Task.sleep(for: .milliseconds(200))
        return try TheSessionSearch.decode(query.lowercased().contains("zzz") ? noneData : searchData)
    }

    func tune(_ id: Int) async throws -> TheSessionTune {
        try TheSessionTune.decode(tuneData)
    }

    func abc(ofTune id: Int) async throws -> String { abcText }
}
