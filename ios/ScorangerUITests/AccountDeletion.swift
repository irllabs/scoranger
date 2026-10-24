import XCTest

/// Deleting the account, from inside the app.
///
/// Apple's App Review guideline 5.1.1(v): an app that supports account
/// creation must support account deletion from within the app. Scoranger has
/// Sign in with Apple and Google sign-in, so it has accounts, and until this
/// branch it had no deletion path anywhere -- an automatic rejection.
///
/// The signed-in state is faked with `-pretendSignedIn` (`SignIn`), because a
/// simulator has no Apple ID and no Google account to sign in with, and the
/// destructive half of the Account section only exists when somebody is
/// signed in. Firebase is still not configured under that flag, so the
/// deletion itself REFUSES -- which is the other thing worth asserting: it
/// says so, and the reader is not left half-deleted.
final class AccountDeletion: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-resetLibrary", "-resetViewPreferences", "-pretendSignedIn"]
        app.launch()
    }

    /// Open Settings and the Account section. The same route `SignInReachable`
    /// takes, which is the only other test that goes in here.
    @discardableResult
    private func openAccount() -> Bool {
        _ = app.descendants(matching: .any)["library-search"].waitForExistence(timeout: 240)
        let gear = app.descendants(matching: .any)["library-settings"]
        guard gear.waitForExistence(timeout: 60) else { return false }
        gear.tap()
        let account = app.buttons["settings-account"]
        if account.waitForExistence(timeout: 30) { account.tap() }
        return app.descendants(matching: .any)["account-identity"]
            .waitForExistence(timeout: 30)
    }

    private func snap(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["SCORANGER_SHOT_DIR"],
           let png = screenshot.pngRepresentation as NSData? {
            png.write(toFile: directory + "/\(name).png", atomically: true)
        }
    }

    /// A destructive row, last, under Careful -- the idiom Delete piece and
    /// Delete arrangement already use, and NOT a hidden setting -- and what
    /// will NOT be deleted, said before the question is even asked.
    ///
    /// One launch for both: they read the same screen and change nothing.
    func testDeletingTheAccountIsOfferedUnderCarefulAndTheLibraryStays() {
        XCTAssertTrue(openAccount(), "the Account section never appeared")

        let row = app.descendants(matching: .any)["account-delete"]
        XCTAssertTrue(row.waitForExistence(timeout: 20),
                      "there is no way to delete an account, which is an "
                      + "automatic App Store rejection under 5.1.1(v)")
        XCTAssertTrue(row.isHittable, "the delete row is not tappable")
        XCTAssertTrue(app.staticTexts["Careful"].exists,
                      "a destructive action must sit under Careful")
        snap("account-delete-row")

        // What will NOT be deleted, said before the question is even asked.
        let keeps = app.descendants(matching: .any)["account-delete-keeps"]
        XCTAssertTrue(keeps.waitForExistence(timeout: 20),
                      "nothing tells the reader their music is not going too")
        XCTAssertTrue(keeps.label.contains("stays on this iPad"),
                      "the promise does not say the thing it exists to say: "
                      + keeps.label)
    }

    /// TWO STEPS. One tap opens the question; a second confirms. The first tap
    /// must not delete anything, Keep backs out, and confirming without a
    /// configuration says so rather than doing nothing.
    ///
    /// One launch: backing out and then confirming is also the order a reader
    /// who changed their mind back would take.
    func testTheConfirmIsTwoStepsKeepBacksOutAndConfirmingSaysNothingWasDeleted() {
        XCTAssertTrue(openAccount(), "the Account section never appeared")

        app.descendants(matching: .any)["account-delete"].tap()

        let confirm = app.descendants(matching: .any)["confirm-delete-account"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 15),
                      "the first tap did not open a confirm")
        XCTAssertTrue(app.staticTexts["Delete your account?"].exists,
                      "the confirm does not ask a question")
        // The confirm has to SAY what happens, per set list and by name --
        // otherwise it is a red button with no information behind it. The
        // fixture owns one set list with other people in it, owns one alone,
        // and is a member of a third, so all three fates are on screen.
        let consequence = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "cannot be undone")).firstMatch
        XCTAssertTrue(consequence.exists,
                      "the confirm does not say it is irreversible")
        let said = consequence.label
        XCTAssertTrue(said.contains("Practice is deleted"),
                      "the confirm does not name the set list it will destroy: " + said)
        XCTAssertTrue(said.contains("Friday at the Bell passes to the next person invited"),
                      "the confirm does not say the shared one is handed on: " + said)
        XCTAssertTrue(said.contains("The quintet's book"),
                      "the confirm does not mention somebody else's set list: " + said)
        XCTAssertTrue(said.contains("pencil marks"),
                      "the confirm does not mention the markup: " + said)
        snap("account-delete-confirm")

        // Nothing has happened yet: the account is still signed in.
        XCTAssertTrue(app.descendants(matching: .any)["account-identity"].exists,
                      "the first tap deleted something")

        app.descendants(matching: .any)["confirm-delete-account-keep"].tap()
        XCTAssertTrue(waitUntil("the confirm to close", timeout: 15) { !confirm.exists },
                      "Keep did not close the confirm")
        XCTAssertTrue(app.descendants(matching: .any)["account-delete"].exists,
                      "backing out lost the row")
        XCTAssertTrue(app.descendants(matching: .any)["account-identity"].exists,
                      "Keep signed the account out")

        // Then the second time through, CONFIRMED. With no live Firebase
        // session that must SAY so.
        //
        // A destructive action that quietly does nothing is the worst outcome
        // available here: the reader believes their account is gone and it is
        // not. This is the path `-pretendSignedIn` can actually reach, and it
        // is the same error branch a misconfigured real build would take.
        // Keep left nothing behind (asserted above), so this starts from the
        // same row a fresh launch would.
        app.descendants(matching: .any)["account-delete"].tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 15), "no confirm")
        confirm.tap()

        let note = app.descendants(matching: .any)["account-delete-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 30),
                      "confirming said nothing at all")
        XCTAssertTrue(note.label.contains("nothing was deleted"),
                      "the refusal does not say that nothing was deleted, "
                      + "which is the one thing the reader has to know: "
                      + note.label)
        snap("account-delete-refused")
    }
}
