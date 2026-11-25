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
        DemoScreens.shown("WelcomeView", as: .client)
        hold(2)
        join.tap()

        signIn(app, email: email, as: .client)
        XCTAssertTrue(waitForToday(app), "Sign-in did not open the coached week. \(failureOnScreen(app))")
        // FIT-445: a client sees no Clients tab, sample client or not.
        XCTAssertFalse(app.tabBars.buttons["Clients"].exists, "A client was shown the coach's Clients tab")
        // The coached week is the Today tab. The week strip also has a control named Today, so the query is the tab.
        let tab = app.tabBars.buttons["Today"]
        if tab.waitForExistence(timeout: 5), !tab.isSelected {
            tab.tap()
            hold(1.2)
        }
        DemoScreens.shown("tab.Today", as: .client)
        hold(2.5)
        logOpenSession(app)
        showDeleteAccount(app)
        signOut(app)

        let coach = app.buttons["welcome.coach"]
        XCTAssertTrue(coach.waitForExistence(timeout: 25), "Coach mode's door did not come back after signing out")
        DemoScreens.shown("WelcomeView", as: .coach)
        hold(1.2)
        coach.tap()
        signIn(app, email: coachEmail, as: .coach)
        let clients = app.buttons["welcome.clients"]
        XCTAssertTrue(clients.waitForExistence(timeout: 90), "Signing in as the coach did not offer My Clients. \(failureOnScreen(app))")
        hold(1.2)
        dismissPasswordPrompt(app, timeout: 3)
        clients.tap()
        XCTAssertTrue(app.navigationBars["Clients"].waitForExistence(timeout: 30) || app.staticTexts["Clients"].waitForExistence(timeout: 5),
                      "The coach roster did not open")
        DemoScreens.shown("tab.Clients", as: .coach)
        _ = app.staticTexts["Sam Rivera"].waitForExistence(timeout: 20)
        hold(3)
    }

    /// Opt-in check using the signed-in demo pair and a disposable rest day. The reviewed
    /// client account is excluded because it belongs to a separate App Store demo flow.
    @MainActor
    func testDemoSessionChangeReachesClient() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["COACH_MOTION_SYNC"] == "YES"
                          && coachEmail == "coach@barbrabell.com" && email == "client@barbrabell.com",
                          "This check requires the disposable coach/client demo pair")
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        app.buttons["welcome.coach"].tap()
        signIn(app, email: coachEmail, as: .coach, password: environment["DEMO_COACH_PASSWORD"])
        let roster = app.buttons["welcome.clients"]
        XCTAssertTrue(roster.waitForExistence(timeout: 90), failureOnScreen(app))
        // The roster button lands before the sign-in sheet has finished leaving, and the keychain
        // prompt can arrive late: wait for the button to take a tap instead of tapping into the sheet.
        dismissPasswordPrompt(app, timeout: 3)
        let ready = Date().addingTimeInterval(30)
        while Date() < ready && !roster.isHittable {
            dismissPasswordPrompt(app, timeout: 1)
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        XCTAssertTrue(roster.isHittable, failureOnScreen(app))
        roster.tap()
        let sam = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Sam Rivera")).firstMatch
        XCTAssertTrue(sam.waitForExistence(timeout: 30))
        sam.tap()
        // A run goes onto today whether or not the demo plan already has a session there: on a rest day
        // from the empty day's buttons, otherwise from the day's ⋯. Nothing already planned is removed.
        let rest = app.staticTexts["Rest day"]
        if rest.waitForExistence(timeout: 8) {
            app.buttons["Run"].tap()
        } else {
            let actions = app.buttons["coach.dayActions"]
            XCTAssertTrue(actions.waitForExistence(timeout: 10), failureOnScreen(app))
            actions.tap()
            app.buttons["Add a Run"].tap()
        }
        app.buttons["Tempo"].tap()
        app.buttons["Add"].tap()
        XCTAssertTrue(app.staticTexts["Run added"].waitForExistence(timeout: 10), "The coach did not see a send confirmation")
        attach(app, "Coach sent a session")

        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Account and library"].tap()
        let coachAccount = accountRow(app)
        XCTAssertTrue(coachAccount.waitForExistence(timeout: 10))
        coachAccount.tap()
        signOut(app)

        let join = app.buttons["welcome.join"]
        XCTAssertTrue(join.waitForExistence(timeout: 30))
        join.tap()
        signIn(app, email: email, as: .client)
        XCTAssertTrue(waitForToday(app), failureOnScreen(app))
        // The run reaches them as the catalog names it ("Trail Running/Walking"), with "tempo" as its note.
        let sent = NSPredicate(format: "label CONTAINS[c] 'Trail Running' OR label CONTAINS[c] 'tempo'")
        let delivered = app.descendants(matching: .any).matching(sent).firstMatch
        var arrived = delivered.waitForExistence(timeout: 45)
        if !arrived {
            // Their phone may have read the plan before the coach's edit landed: pull Today down once.
            app.swipeDown()
            arrived = delivered.waitForExistence(timeout: 45)
        }
        XCTAssertTrue(arrived, "The demo client did not show the session sent by the coach")
        // The keychain prompt arrives over Today a few seconds after sign-in: it would sit in the evidence.
        dismissPasswordPrompt(app, timeout: 5)
        attach(app, "Client received the session")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func signIn(_ app: XCUIApplication, email: String, as role: DemoScreens.Role, password override: String? = nil) {
        let emailButton = app.buttons["signin.email"]
        XCTAssertTrue(emailButton.waitForExistence(timeout: 15), "Sign in with email was not on screen")
        DemoScreens.shown("SignInSheet", as: role)
        hold(1)
        emailButton.tap()
        let emailField = app.textFields["signin.emailField"]
        let passwordField = app.secureTextFields["signin.passwordField"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 8))
        emailField.tap()
        emailField.typeText(email)
        passwordField.tap()
        // Return submits. The password field is secure, so the recording shows dots.
        passwordField.typeText((override ?? password) + "\n")
        dismissPasswordPrompt(app)
    }

    /// Today's session, when it is still to do: check the lifts off and save. An already-logged day, a rest day,
    /// or a week the coach has not written yet stays on screen. "Train this today" is left alone: it moves the plan.
    @MainActor
    private func logOpenSession(_ app: XCUIApplication) {
        dismissPasswordPrompt(app, timeout: 2)
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
        closeCelebration(app, timeout: 6)
    }

    /// TKL-1021: since TKL-934 a save that earns a win (the demo client's usually does) ends on the "Nice work"
    /// sheet, which covers Today and swallows the tap on "Account and library". Show it, then close it.
    @MainActor
    private func closeCelebration(_ app: XCUIApplication, timeout: TimeInterval) {
        let nice = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Nice work'")).firstMatch
        guard nice.waitForExistence(timeout: timeout) else { return }
        DemoScreens.shown("CelebrationSheet", as: .client)
        hold(2.4)
        let close = app.buttons["Close"].firstMatch
        if close.isHittable { close.tap() }
        else { close.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        _ = nice.waitForNonExistence(timeout: 6)
        hold(0.8)
    }

    @MainActor
    private func showDeleteAccount(_ app: XCUIApplication) {
        let you = app.buttons["Account and library"]
        XCTAssertTrue(you.waitForExistence(timeout: 10), "Today has no account button")
        you.tap()
        if !app.staticTexts["You"].waitForExistence(timeout: 5) {
            // A late celebration or toast can still cover Today: clear it and try once more.
            closeCelebration(app, timeout: 1)
            if you.isHittable { you.tap() }
            else { you.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        }
        XCTAssertTrue(app.staticTexts["You"].waitForExistence(timeout: 10), "You did not open")
        DemoScreens.shown("YouScreen", as: .client)
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
        DemoScreens.shown("AccountView", as: .client)
        hold(2.2)
    }

    /// The account row is the link at the bottom of You. Its identifier, the email, or the demo client's name will do.
    @MainActor
    private func accountRow(_ app: XCUIApplication) -> XCUIElement {
        let identified = app.descendants(matching: .any).matching(identifier: "you.account").firstMatch
        // The account section is the last one on You, so a long list (a coach's, above all) has not
        // drawn it yet: scroll down until it is there.
        for _ in 0..<8 where !identified.exists { app.swipeUp() }
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
        let out = app.buttons["account.signOut"]
        if !out.waitForExistence(timeout: 10) {
            // The account row's push can be swallowed while the list is still settling: open it again.
            let row = accountRow(app)
            if row.exists { row.tap() }
        }
        XCTAssertTrue(out.waitForExistence(timeout: 15), failureOnScreen(app))
        out.tap()
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
    /// iOS offers "Save Password?" a few seconds after sign-in on a simulator that has never been asked. It covers
    /// Today, so wait for it (up to `timeout`) and say Not Now, wherever it is drawn.
    private func dismissPasswordPrompt(_ app: XCUIApplication, timeout: TimeInterval = 8) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for owner in [app, springboard] where owner.buttons["Not Now"].exists {
                owner.buttons["Not Now"].tap()
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        } while Date() < deadline
    }

    @MainActor
    private func hold(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }
}
