import XCTest

/// Search on thesession.org (0.20.0): the site's answers decode, a tune's
/// ABC file is cut down to the settings chosen, and the sources remember
/// their ticks. The answers are the site's own, fetched 2026-10-12
/// (Fixtures/thesession-*).
final class TuneSearchTests: XCTestCase {

    /// The same files the app's own stub reads under -stubTheSession
    /// (copied into samples-seed by project.yml's Debug copy phase).
    private var folder: URL { Bundle(for: Self.self).resourceURL!.appending(path: "Fixtures") }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: folder.appending(path: name))
    }

    func testTheAppsStubReadsTheSameFiles() async throws {
        let stub = try XCTUnwrap(FixtureTuneFinder(folder: folder))
        let page = try await stub.search("drowsy", page: 1)
        XCTAssertEqual(page.hits.first?.name, "Drowsy Maggie")
        let none = try await stub.search("zzz", page: 1)
        XCTAssertTrue(none.hits.isEmpty)
        let tune = try await stub.tune(27)
        XCTAssertEqual(tune.settings.count, 38)
        let abc = try await stub.abc(ofTune: 27)
        XCTAssertEqual(ABCSettings.blocks(of: abc).count, 38)
    }

    func testASearchPageDecodes() throws {
        let page = try TheSessionSearch.decode(try fixture("thesession-search-drowsy.json"))
        XCTAssertEqual(page.query, "drowsy maggie")
        XCTAssertEqual(page.total, 51)
        XCTAssertEqual(page.pages, 6)
        XCTAssertEqual(page.page, 1)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.hits.count, 10)
        XCTAssertEqual(page.hits[0], TheSessionHit(id: 27, name: "Drowsy Maggie", type: "reel",
                                                   alias: "Drowsey Maggie"))
        XCTAssertEqual(page.countLine, "51 tunes")
    }

    /// The site omits `pages` and `total` when nothing matched.
    func testAnEmptySearchDecodes() throws {
        let page = try TheSessionSearch.decode(try fixture("thesession-search-none.json"))
        XCTAssertTrue(page.hits.isEmpty)
        XCTAssertNil(page.total)
        XCTAssertFalse(page.hasMore)
        XCTAssertEqual(page.countLine, "No tunes")
    }

    func testATunesSettingsDecode() throws {
        let tune = try TheSessionTune.decode(try fixture("thesession-tune-27.json"))
        XCTAssertEqual(tune.name, "Drowsy Maggie")
        XCTAssertEqual(tune.type, "reel")
        XCTAssertEqual(tune.settings.count, 38)
        XCTAssertEqual(tune.settings[0].id, 27)
        XCTAssertEqual(tune.settings[0].key, "Edorian")
        XCTAssertEqual(tune.settings[0].keyLine, "E dorian")
        XCTAssertEqual(tune.settings[0].member, "Jeremy")
        XCTAssertTrue(tune.aliases.contains("Maggie Tuirseach"))
    }

    /// The whole-tune file is every setting as its own X: block, each
    /// naming its setting in S:.
    func testTheABCFileSplitsIntoItsSettings() throws {
        let abc = try XCTUnwrap(String(data: try fixture("thesession-tune-27.abc"), encoding: .utf8))
        let blocks = ABCSettings.blocks(of: abc)
        XCTAssertEqual(blocks.count, 38)
        XCTAssertEqual(ABCSettings.settingID(of: blocks[0]), 27)
        XCTAssertEqual(ABCSettings.settingID(of: blocks[1]), 12406)
        XCTAssertTrue(blocks[0].hasPrefix("X: 1\n"))
        XCTAssertTrue(blocks[0].contains("\nK: Edor\n"), "the site's headers are kept as written")
    }

    func testChoosingSettingsKeepsThemInOrderAndRenumbers() throws {
        let abc = try XCTUnwrap(String(data: try fixture("thesession-tune-27.abc"), encoding: .utf8))
        let chosen = try XCTUnwrap(ABCSettings.select([12406, 27], from: abc))
        let blocks = ABCSettings.blocks(of: chosen)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(ABCSettings.settingID(of: blocks[0]), 27, "the site's order, not the set's")
        XCTAssertEqual(ABCSettings.settingID(of: blocks[1]), 12406)
        XCTAssertTrue(blocks[1].hasPrefix("X: 2\n"), "renumbered so the file stays valid")
        XCTAssertTrue(chosen.hasSuffix("\n"))
        // an id the file does not hold is absent; nothing chosen is nil
        XCTAssertEqual(ABCSettings.blocks(of: try XCTUnwrap(ABCSettings.select([27, 1], from: abc))).count, 1)
        XCTAssertNil(ABCSettings.select([1], from: abc))
    }

    func testWindowsLineEndingsAreNormalised() {
        let abc = "X: 1\r\nT: A\r\nS: https://thesession.org/tunes/5#setting9\r\nK: D\r\n|D|\r\n\r\nX: 2\r\nT: A\r\nS: https://thesession.org/tunes/5#setting10\r\nK: G\r\n|G|\r\n"
        let blocks = ABCSettings.blocks(of: abc)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertFalse(blocks[0].contains("\r"))
        XCTAssertEqual(ABCSettings.settingID(of: blocks[1]), 10)
        XCTAssertEqual(ABCSettings.whole(abc).components(separatedBy: "\n\n").count, 2)
    }

    func testFileNamesNameTheTune() {
        XCTAssertEqual(ABCSettings.fileName(tune: "Drowsy Maggie", settingCount: 1), "Drowsy Maggie.abc")
        XCTAssertEqual(ABCSettings.fileName(tune: "The Bucks of Oranmore / Set", settingCount: 3),
                       "The Bucks of Oranmore - Set (3 settings).abc")
    }

    func testTheSessionURLs() {
        XCTAssertEqual(TheSessionURL.search("drowsy maggie")?.absoluteString,
                       "https://thesession.org/tunes/search?q=drowsy%20maggie&format=json")
        XCTAssertEqual(TheSessionURL.search("x", page: 2)?.absoluteString,
                       "https://thesession.org/tunes/search?q=x&format=json&page=2")
        XCTAssertEqual(TheSessionURL.tune(27)?.absoluteString, "https://thesession.org/tunes/27?format=json")
        XCTAssertEqual(TheSessionURL.abc(27)?.absoluteString, "https://thesession.org/tunes/27/abc")
        XCTAssertEqual(TheSessionURL.musescoreSearch("autumn leaves")?.absoluteString,
                       "https://musescore.com/sheetmusic?text=autumn%20leaves")
    }

    /// The ticks survive a relaunch, and a name a later build might write is
    /// dropped rather than failing the whole set.
    func testSourcesRoundTripAndDropUnknownNames() {
        XCTAssertEqual(SearchSource.decode(""), SearchSource.default)
        XCTAssertEqual(SearchSource.decode(SearchSource.encode([.musescore])), [.musescore])
        XCTAssertEqual(SearchSource.decode("thesession,imslp"), [.thesession])
        XCTAssertEqual(SearchSource.encode([.musescore, .thesession]), "thesession,musescore")
    }

    func testTheUserAgentNamesTheApp() {
        XCTAssertTrue(TheSessionClient.userAgent.hasPrefix("Scoranger/"))
        XCTAssertTrue(TheSessionClient.userAgent.contains("github.com/irllabs/scoranger"))
    }
}
