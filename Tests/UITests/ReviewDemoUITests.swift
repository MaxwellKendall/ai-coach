import XCTest

/// FIT-431: the path App Review is shown. `scripts/demo-video.mjs` records the simulator while this runs.
/// Sign in as the demo client, show the coached week, log today's session when it is still open, show where
/// Delete Account is (without deleting), then sign in as the demo coach and show the roster.
final class ReviewDemoUITests: XCTestCase {
    private let email = ReviewDemoSecrets.clientEmail
    private let coachEmail = ReviewDemoSecrets.coachEmail
    private let password = ReviewDemoSecrets.password

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(email.isEmpty || coachEmail.isEmpty || password.isEmpty, "Demo account environment was not provided to the UI test")
    }

    @MainActor
    func testReviewPath() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        let join = app.buttons["welcome.join"]
        XCTAssertTrue(join.waitForExistence(timeout: 40), "Welcome did not show Join them")
        hold(2)
        join.tap()

        signIn(app, email: email)
        XCTAssertTrue(waitForToday(app), "Sign-in did not open the coached week. \(failureOnScreen(app))")
        // FIT-445: a client sees no Clients tab, sample client or not.
        XCTAssertFalse(app.tabBars.buttons["Clients"].exists, "A client was shown the coach's Clients tab")
        // The coached week is the Today tab. The week strip also has a control named Today, so the query is the tab.
        let tab = app.tabBars.buttons["Today"]
        if tab.waitForExistence(timeout: 5), !tab.isSelected {
            tab.tap()
            hold(1.2)
        }
        hold(2.5)
        logOpenSession(app)
        showDeleteAccount(app)
        signOut(app)

        let coach = app.buttons["welcome.coach"]
        XCTAssertTrue(coach.waitForExistence(timeout: 25), "Coach mode's door did not come back after signing out")
        hold(1.2)
        coach.tap()
        signIn(app, email: coachEmail)
        let clients = app.buttons["welcome.clients"]
        XCTAssertTrue(clients.waitForExistence(timeout: 90), "Signing in as the coach did not offer My Clients. \(failureOnScreen(app))")
        hold(1.2)
        clients.tap()
        XCTAssertTrue(app.navigationBars["Clients"].waitForExistence(timeout: 30) || app.staticTexts["Clients"].waitForExistence(timeout: 5),
                      "The coach roster did not open")
        _ = app.staticTexts["Sam Rivera"].waitForExistence(timeout: 20)
        hold(3)
    }

    @MainActor
    private func signIn(_ app: XCUIApplication, email: String) {
        let emailButton = app.buttons["signin.email"]
        XCTAssertTrue(emailButton.waitForExistence(timeout: 15), "Sign in with email was not on screen")
        hold(1)
        emailButton.tap()
        let emailField = app.textFields["signin.emailField"]
        let passwordField = app.secureTextFields["signin.passwordField"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 8))
        emailField.tap()
        emailField.typeText(email)
        passwordField.tap()
        // Return submits. The password field is secure, so the recording shows dots.
        passwordField.typeText(password + "\n")
        dismissPasswordPrompt(app)
    }

    /// Today's session, when it is still to do: check the lifts off and save. An already-logged day, a rest day,
    /// or a week the coach has not written yet stays on screen. "Train this today" is left alone: it moves the plan.
    @MainActor
    private func logOpenSession(_ app: XCUIApplication) {
        let check = app.buttons["Check off as done"].firstMatch
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline && !check.exists {
            let saved = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Saved'")).firstMatch.exists
            let resting = app.staticTexts["Rest day"].exists || app.staticTexts["Not planned yet"].exists
            let waiting = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'written'")).firstMatch.exists
            if saved || resting || waiting { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        if !check.exists { app.swipeUp(); hold(0.5) }
        guard check.exists else {
            hold(2)
            return
        }
        var taps = 0
        while app.buttons["Check off as done"].firstMatch.exists && taps < 8 {
            let box = app.buttons["Check off as done"].firstMatch
            // The circle is a plain button. XCTest often reports it as not hittable even when it is on screen.
            if box.isHittable { box.tap() }
            else { box.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
            taps += 1
            hold(0.45)
        }
        let identified = app.buttons["today.save"]
        let labeled = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Save workout'")).firstMatch
        let save = identified.waitForExistence(timeout: 8) ? identified : labeled
        XCTAssertTrue(save.exists, "Checking a lift off did not offer Save workout")
        hold(1)
        if save.isHittable { save.tap() }
        else { save.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        let skip = app.buttons["Skip"]
        if skip.waitForExistence(timeout: 6) {
            hold(0.8)
            skip.tap()
        }
        hold(1.6)
    }

    @MainActor
    private func showDeleteAccount(_ app: XCUIApplication) {
        let you = app.buttons["Account and library"]
        XCTAssertTrue(you.waitForExistence(timeout: 10), "Today has no account button")
        you.tap()
        XCTAssertTrue(app.staticTexts["You"].waitForExistence(timeout: 10), "You did not open")
        hold(1)
        var row = accountRow(app)
        for _ in 0..<4 where !row.exists {
            app.swipeUp()
            hold(0.4)
            row = accountRow(app)
        }
        XCTAssertTrue(row.waitForExistence(timeout: 8), "You did not list the account")
        hold(1.4)
        row.tap()
        let delete = app.buttons["account.delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 10), "Delete Account was not on the account screen")
        hold(2.2)
    }

    /// The account row is the link at the bottom of You. Its identifier, the email, or the demo client's name will do.
    @MainActor
    private func accountRow(_ app: XCUIApplication) -> XCUIElement {
        let identified = app.descendants(matching: .any).matching(identifier: "you.account").firstMatch
        if identified.exists { return identified }
        for label in [email, "Sam Rivera", "Account"] {
            let text = app.staticTexts[label]
            if text.exists { return text }
            let button = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
            if button.exists { return button }
        }
        return identified
    }

    @MainActor
    private func signOut(_ app: XCUIApplication) {
        app.buttons["account.signOut"].tap()
    }

    @MainActor
    private func waitForToday(_ app: XCUIApplication) -> Bool {
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            dismissPasswordPrompt(app)
            if app.staticTexts["Couldn't sign in. Check the email and password."].exists { return false }
            if app.buttons["Account and library"].exists { return true }
            if app.staticTexts["Today"].exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        return app.buttons["Account and library"].exists
    }

    @MainActor
    private func failureOnScreen(_ app: XCUIApplication) -> String {
        app.staticTexts["Couldn't sign in. Check the email and password."].exists
            ? "The demo sign-in was rejected."
            : "No sign-in error was on screen."
    }

    @MainActor
    private func dismissPasswordPrompt(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.buttons["Not Now"].waitForExistence(timeout: 1) { springboard.buttons["Not Now"].tap() }
        if app.buttons["Not Now"].exists { app.buttons["Not Now"].tap() }
    }

    @MainActor
    private func hold(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }
}
