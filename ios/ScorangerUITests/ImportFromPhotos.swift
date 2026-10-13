import XCTest

/// Photo is in the Import band, and it opens the camera roll.
///
/// Ali: "in addition to opening files, I need an option to open the local
/// photo gallery too." Files cannot reach the camera roll, and a photographed
/// page is how a score arrives when it is not already a file.
///
/// What this can assert from out here is the affordance and the presentation:
/// the entry exists where §14's band puts it, tapping it presents Apple's own
/// picker, and the picker can be dismissed without leaving the app somewhere
/// odd. What happens to a chosen photo is `PhotoImport`'s own path into
/// `receiveFile`, which is the same entry point every filed score uses.
final class ImportFromPhotos: XCTestCase {

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testPhotoIsOfferedAndOpensTheGallery() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetLibrary", "-seedTestLibrary"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        let search = app.descendants(matching: .any)["library-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 240),
                      "the library never appeared")
        settle(search, still: 0.8)

        app.descendants(matching: .any)["library-import"].firstMatch.tap()
        let photo = app.descendants(matching: .any)["library-import-photos"].firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 20),
                      "Photos is not in the Import band")
        XCTAssertTrue(photo.isHittable)
        snap("import-band-with-photos")

        // §15's order and its divider: Score and Photos are one arrangement
        // out of one thing; Folder and Book are a collection. And every row
        // carries its subtitle, which is what keeps Score findable for a
        // picture that is already in Files.
        for (identifier, expected) in [("library-import-score", "Score"),
                                       ("library-import-photos", "Photos"),
                                       ("library-import-folder", "Folder"),
                                       ("library-import-book", "Book"),
                                       ("library-import-search", "Search")] {
            let row = app.descendants(matching: .any)[identifier].firstMatch
            XCTAssertTrue(row.exists, "\(expected) is missing from the band")
            XCTAssertTrue(row.label.contains(expected),
                          "\(identifier) says \"\(row.label)\"")
        }
        let score = app.descendants(matching: .any)["library-import-score"].firstMatch
        let photos = app.descendants(matching: .any)["library-import-photos"].firstMatch
        let folder = app.descendants(matching: .any)["library-import-folder"].firstMatch
        XCTAssertLessThan(score.frame.minY, photos.frame.minY,
                          "Photos should sit under Score")
        XCTAssertLessThan(photos.frame.minY, folder.frame.minY,
                          "Folder should sit under Photos")
        // The subtitle is on the row, so the row's label carries it.
        XCTAssertTrue(score.label.lowercased().contains("picture"),
                      "Score does not say it takes a picture, which is what "
                      + "makes it findable for one: \"\(score.label)\"")

        photo.tap()
        // PHPicker runs OUT OF PROCESS, so it is not part of this app's
        // element tree: it is found through the springboard. Its Cancel is
        // the one thing reliably addressable in every locale this runs in.
        let gallery = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        let cancel = app.buttons["Cancel"].firstMatch
        let appeared = cancel.waitForExistence(timeout: 20)
            || gallery.wait(for: .runningForeground, timeout: 20)
        XCTAssertTrue(appeared,
                      "tapping Photos did not present the photo picker")
        snap("photo-picker-open")

        if cancel.exists { cancel.tap() }
        XCTAssertTrue(search.waitForExistence(timeout: 30),
                      "dismissing the photo picker did not return to the library")
    }
}
