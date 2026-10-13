import XCTest

/// What Settings' "How Scoranger works" claims, held to what the app is.
///
/// Two different jobs here. The DIAGRAM's claims are about the product, and
/// the one that matters is the one a musician makes a decision on: exactly two
/// steps need a network, and every other step runs on the iPad. If that ever
/// stops being true, the screen becomes a lie a reader planned a gig around.
///
/// The CREDITS are a legal obligation. BSD-3-Clause, MIT, Apache-2.0, zlib,
/// MPL-2.0, SIL OFL-1.1, LGPL-3.0 and AGPL-3.0 each require the notice to
/// travel with the software. A name quietly dropped in an edit is a breach,
/// and nothing else in the build would notice.
final class PipelineTests: XCTestCase {

    // MARK: - The diagram

    func testEveryStageSaysWhatItIsAndWhereItRuns() {
        XCTAssertFalse(Pipeline.stages.isEmpty)
        var ids: Set<String> = []
        for stage in Pipeline.stages {
            XCTAssertTrue(ids.insert(stage.id).inserted, "two stages called \(stage.id)")
            XCTAssertFalse(stage.title.isEmpty)
            XCTAssertGreaterThan(stage.detail.count, 30,
                                 "\(stage.id) is described too thinly to be a diagram")
        }
    }

    /// Only the first box is pointed at by nothing.
    func testEveryStageButTheFirstSaysWhatArrivesAtIt() {
        XCTAssertNil(Pipeline.stages.first?.arrival)
        for stage in Pipeline.stages.dropFirst() {
            XCTAssertNotNil(stage.arrival, "nothing labels the arrow into \(stage.id)")
        }
    }

    /// The claim the whole section turns on, and the reason it is worth a test:
    /// the recognition service and the chat model are the only two things that
    /// leave the iPad.
    func testExactlyTwoStepsNeedANetwork() {
        let network = Pipeline.stages.filter { $0.locale == .network }.map(\.id)
            + Pipeline.stages.compactMap(\.branch).filter { $0.locale == .network }.map(\.id)
        XCTAssertEqual(network.sorted(), ["agent", "omr"])

        let onDevice = Pipeline.stages.filter { $0.locale == .onDevice }.map(\.id)
        XCTAssertEqual(onDevice.sorted(), ["engine", "page", "versions"])
    }

    /// The agent JOINS the chain; it is not a link in it. The diagram draws it
    /// indented for that reason, and the data has to carry the distinction or
    /// the drawing is decoration.
    func testTheAgentIsABranchAndNotAStep() throws {
        let branches = Pipeline.stages.compactMap { stage in
            stage.branch.map { (stage.id, $0) }
        }
        XCTAssertEqual(branches.count, 1)
        let (joins, agent) = try XCTUnwrap(branches.first)
        XCTAssertEqual(joins, "engine", "the agent calls the engine and nothing else")
        XCTAssertEqual(agent.id, "agent")
        XCTAssertFalse(Pipeline.stages.contains { $0.id == "agent" })
        XCTAssertTrue(agent.hands.contains("never notes"), agent.hands)
    }

    func testTheEngineIsNamedAsTheOnlyThingThatChangesNotation() {
        let engine = Pipeline.stages.first { $0.id == "engine" }
        XCTAssertTrue(engine?.detail.contains("only part of Scoranger that changes notation")
                      ?? false, engine?.detail ?? "no engine stage")
    }

    // MARK: - The prose

    func testEveryPassageIsTitledAndSaysSomething() {
        XCTAssertFalse(Pipeline.passages.isEmpty)
        var ids: Set<String> = []
        for passage in Pipeline.passages {
            XCTAssertTrue(ids.insert(passage.id).inserted, "two passages called \(passage.id)")
            XCTAssertFalse(passage.title.isEmpty)
            XCTAssertGreaterThan(passage.body.count, 80, passage.id)
        }
    }

    /// The five things the section exists to say. Written as a search for the
    /// claim rather than for the wording, so the prose can be edited and the
    /// substance cannot quietly go.
    func testTheSectionMakesTheFiveClaimsItIsFor() {
        let prose = Pipeline.passages.map(\.body).joined(separator: " ")
        XCTAssertTrue(prose.contains("optical music recognition"),
                      "a reader has to be told a scan is a reading")
        XCTAssertTrue(prose.contains("MIDI"), "the two formats that skip recognition")
        XCTAssertTrue(prose.contains("None of it is written by a language model"))
        XCTAssertTrue(prose.contains("new version beside"))
        XCTAssertTrue(prose.contains("never writes a note itself"))
        XCTAssertTrue(prose.contains("run on this iPad"))
    }

    /// Said plainly, in the words a musician standing on a stage would use.
    func testTheOfflineAnswerIsGivenInFull() {
        let offline = Pipeline.passages.first { $0.id == "offline" }?.body ?? ""
        XCTAssertTrue(offline.contains("no wifi"), offline)
        XCTAssertTrue(offline.contains("You cannot scan a new PDF"), offline)
        XCTAssertTrue(offline.contains("you cannot search for a tune"), offline)   // 0.20.0
        XCTAssertTrue(offline.contains("you cannot ask the agent"), offline)
    }

    // MARK: - The credits

    func testEveryCreditNamesAProjectALicenceAndAJob() {
        XCTAssertFalse(Pipeline.creditGroups.isEmpty)
        var names: Set<String> = []
        for group in Pipeline.creditGroups {
            XCTAssertFalse(group.title.isEmpty)
            XCTAssertFalse(group.credits.isEmpty, "\(group.id) credits nobody")
            for credit in group.credits {
                XCTAssertTrue(names.insert(credit.name).inserted,
                              "\(credit.name) is credited twice")
                XCTAssertFalse(credit.licence.isEmpty, credit.name)
                XCTAssertGreaterThan(credit.role.count, 15,
                                     "\(credit.name) is credited without saying what it does")
            }
        }
    }

    /// The five the app could not run without, with the licence each one's own
    /// file states. These are typed out here so that changing one in `Pipeline`
    /// and not in the tree fails rather than ships.
    func testTheLicencesOfWhatTheAppCannotRunWithout() {
        let expected = [
            "music21": "BSD-3-Clause",
            "Verovio": "LGPL-3.0",
            "SwiftDraw": "zlib",
            "CPython 3.14": "PSF-2.0",
            "Audiveris": "AGPL-3.0",
        ]
        for (name, licence) in expected {
            let credit = Pipeline.credits.first { $0.name == name }
            XCTAssertEqual(credit?.licence, licence, "\(name) is credited wrongly or not at all")
        }
    }

    /// README.md credits OpenSheetMusicDisplay in the same paragraph as the
    /// rest, and it is not in this app -- it renders the desktop prototype's
    /// web viewer. Crediting it on an iPad would be a claim about the app that
    /// is not true.
    func testNothingIsCreditedThatTheAppDoesNotShip() {
        let names = Pipeline.credits.map(\.name).joined(separator: " | ")
        // SwiftProtobuf is in Package.resolved and links into nothing (checked
        // against the build products for 0.15.0); Liberation's copy is not
        // shipped, because it is GPLv2 (fetch_python.sh).
        for absent in ["OpenSheetMusicDisplay", "OSMD", "cairosvg", "MuseScore",
                       "SwiftProtobuf", "Liberation"] {
            XCTAssertFalse(names.contains(absent),
                           "\(absent) is not in the iPad app and must not be credited in it")
        }
    }

    /// `ios/Vendor/SoundFonts` is a folder reference in the app target, so the
    /// bank ships, so it is credited. Its licence is a bespoke one and must not
    /// be labelled with an SPDX name it does not have.
    func testTheSoundBankIsCreditedUnderItsOwnLicence() {
        let bank = Pipeline.credits.first { $0.name.contains("GeneralUser GS") }
        XCTAssertNotNil(bank, "the bank ships in the bundle and is not credited")
        XCTAssertEqual(bank?.licence, "GeneralUser GS License v2.0")
        XCTAssertTrue(bank?.name.contains("S. Christian Collins") ?? false,
                      "the licence is granted by a person, who is named in it")
    }

    /// Each of the three typefaces ships as a file in the bundle and the OFL
    /// requires its notice to travel with it.
    func testTheTypefacesAreCredited() {
        for face in ["Inter", "IBM Plex Mono", "Space Grotesk"] {
            let credit = Pipeline.credits.first { $0.name == face }
            XCTAssertEqual(credit?.licence, "SIL OFL-1.1", face)
        }
    }

    /// Everything music21 drags into the bundle with it. Found by reading
    /// `ios/PythonApp/app_packages`, not by reading README.md, which lists
    /// pypdf as desktop-only and ships it anyway.
    func testThePythonPackagesInTheBundleAreCredited() {
        let expected = ["pypdf": "BSD-3-Clause", "requests": "Apache-2.0",
                        "urllib3": "MIT", "certifi": "MPL-2.0",
                        "idna": "BSD-3-Clause", "chardet": "0BSD",
                        "charset-normalizer": "MIT", "joblib": "BSD-3-Clause",
                        "jsonpickle": "BSD-3-Clause", "more-itertools": "MIT",
                        "webcolors": "BSD-3-Clause"]
        for (name, licence) in expected {
            XCTAssertEqual(Pipeline.credits.first { $0.name == name }?.licence, licence,
                           "\(name) ships in app_packages and is credited wrongly or not at all")
        }
    }

    /// Everything the app ships carries its licence text, from 0.15.0.
    /// Only what is NOT in the app goes without: Audiveris runs on a server,
    /// and OpenRouter is a service. deploy_testflight.sh checks that each of
    /// these paths is in the archive.
    func testEverythingShippedPointsAtALicenceTextAndNothingElseDoes() {
        let notShipped: Set<String> = ["Audiveris", "OpenRouter"]
        for credit in Pipeline.credits {
            if notShipped.contains(credit.name) {
                XCTAssertNil(credit.text, "\(credit.name) is not in the app; no text ships for it")
            } else {
                XCTAssertNotNil(credit.text, "\(credit.name) ships and its licence text does not")
            }
        }
    }

    /// Each Python package's text is where vendor_engine.sh puts it:
    /// `Licences/python/<distribution>`, the distribution name as its .dist-info
    /// spells it (charset_normalizer, not charset-normalizer).
    func testEveryPythonPackagePointsAtTheLicenceTextThatShipsWithIt() {
        let expected = ["music21": "music21", "pypdf": "pypdf", "requests": "requests",
                        "urllib3": "urllib3", "certifi": "certifi", "idna": "idna",
                        "chardet": "chardet", "charset-normalizer": "charset_normalizer",
                        "joblib": "joblib", "jsonpickle": "jsonpickle",
                        "more-itertools": "more_itertools", "webcolors": "webcolors"]
        for (name, dist) in expected {
            XCTAssertEqual(Pipeline.credits.first { $0.name == name }?.text,
                           "Licences/python/\(dist)",
                           "\(name) ships its licence text and the credit does not point at it")
        }
    }

    /// A licence identifier with a space in the middle of it is usually a
    /// sentence that got typed into the wrong field.
    func testLicencesAreIdentifiersAndNotProse() {
        for credit in Pipeline.credits {
            XCTAssertLessThan(credit.licence.count, 40, credit.name)
            XCTAssertFalse(credit.licence.contains("TODO"), credit.name)
        }
    }
}
