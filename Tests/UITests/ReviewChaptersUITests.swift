import XCTest

/// TKL-460: the review demo's invited-client and coach chapters, recorded by `scripts/demo-video.mjs --chapters`
/// (`scripts/review-demo.sh`). Both run the Debug build in the no-server demo mode (`-demo YES`, Maxwell's choice on
/// TKL-460): signed in as a local demo account, no debug rows, nothing written to production, no hosted tokens. The
/// invite and a coach's changes are answered by `DemoCloud`. Each part cues `begin` once the app is on screen and `end`
/// before it relaunches, so the video never shows the home screen; no demo-account secrets are needed.
final class ReviewChaptersUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: Invited client

    /// Accept the coach's invite, then the coach's week: today's session, logging it, Program and Progress, You and
    /// the account. No coach tabs.
    @MainActor
    func testClientChapter() throws {
        // Part 1: a first launch, joining Sam by the invite code.
        var app = launch(role: "new")
        let join = app.buttons["welcome.join"]
        XCTAssertTrue(join.waitForExistence(timeout: 40), "Welcome did not show Have a coach?")
        hold(1.5)
        DemoScreens.cue("begin", .client)
        DemoScreens.shown("WelcomeView", as: .client)
        hold(2)
        join.tap()
        let field = app.textFields["Invite code"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Join your coach did not ask for the code")
        hold(1.2)
        field.tap()
        field.typeText("K7Q2MX")
        hold(0.8)
        app.buttons["Join"].firstMatch.tap()
        let allow = app.buttons["Allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 15), "The invite did not ask to let Sam coach them")
        XCTAssertTrue(app.staticTexts["Let Sam Rivera coach you?"].exists)
        hold(2.2)
        allow.tap()
        // The app's own why-notifications screen, before any system prompt: Not Now, so no system alert shows.
        let notNow = app.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 6) {
            hold(1.6)
            notNow.tap()
        }
        let skip = app.buttons["Skip All"]
        if skip.waitForExistence(timeout: 8) {
            hold(1.6)
            skip.tap()
        }
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 20), "Joining did not open the app")
        XCTAssertFalse(app.tabBars.buttons["Clients"].exists, "A client was shown the coach's Clients tab")
        hold(2)
        DemoScreens.cue("end", .client)

        // Part 2: the coach's week, as it syncs once Sam has written it.
        app = launch(role: "client")
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 40), "The client's app did not open")
        XCTAssertFalse(app.tabBars.buttons["Clients"].exists, "A client was shown the coach's Clients tab")
        hold(1.5)
        DemoScreens.cue("begin", .client)
        DemoScreens.shown("tab.Today", as: .client)
        hold(2.5)
        logOpenSession(app)
        app.tabBars.buttons["Program"].tap()
        DemoScreens.shown("tab.Program", as: .client)
        hold(2.5)
        app.tabBars.buttons["Progress"].tap()
        DemoScreens.shown("tab.Progress", as: .client)
        hold(2.5)
        app.tabBars.buttons["Today"].tap()
        hold(1)
        openYou(app, as: .client)
        assertNoDebugRows(app)
        showAccount(app, as: .client)
        DemoScreens.cue("end", .client)
    }

    // MARK: Coach

    /// The coach door and a first invite, then a full roster: messaging everyone, a client's week (planning, a note,
    /// moving and repeating it, a program), their messages and progress, correcting a logged set, copying a session,
    /// Coach Pro's paywall, and the account with Delete Account.
    @MainActor
    func testCoachChapter() throws {
        // Part 1: in by the coach's door, to an empty roster, and the first invite.
        var app = launch(role: "new")
        let door = app.buttons["welcome.coach"]
        XCTAssertTrue(door.waitForExistence(timeout: 40), "Welcome did not show I'm a coach")
        hold(1.5)
        DemoScreens.cue("begin", .coach)
        DemoScreens.shown("WelcomeView", as: .coach)
        hold(1.5)
        door.tap()
        let clients = app.buttons["welcome.clients"]
        XCTAssertTrue(clients.waitForExistence(timeout: 10), "The coach door did not offer My Clients")
        hold(2.2)
        clients.tap()
        let first = app.buttons["Invite a Client"]
        XCTAssertTrue(first.waitForExistence(timeout: 20), "A new coach was not offered their first invite")
        DemoScreens.shown("tab.Clients", as: .coach)
        hold(2)
        first.tap()
        let who = app.textFields["Who’s it for? (optional)"]
        XCTAssertTrue(who.waitForExistence(timeout: 10), "The invite sheet did not open")
        DemoScreens.shown("InviteSheet", as: .coach)
        hold(1)
        who.tap()
        who.typeText("Jess Park")
        app.buttons["Make the Invite"].tap()
        XCTAssertTrue(app.staticTexts["R4TB9W"].waitForExistence(timeout: 10), "The invite's code did not show")
        hold(3)
        DemoScreens.cue("end", .coach)

        // Part 2: a coach with a roster.
        app = launch(role: "coach")
        XCTAssertTrue(app.navigationBars["Clients"].waitForExistence(timeout: 40), "The roster did not open")
        XCTAssertTrue(app.staticTexts["Mike Torres"].waitForExistence(timeout: 10), "The roster has no Mike Torres")
        hold(1.5)
        DemoScreens.cue("begin", .coach)
        DemoScreens.shown("tab.Clients", as: .coach)
        hold(2.5)

        app.buttons["Message clients"].tap()
        XCTAssertTrue(app.navigationBars["Message Clients"].waitForExistence(timeout: 10), "Message Clients did not open")
        DemoScreens.shown("MessageClientsSheet", as: .coach)
        hold(2)
        cancel(app)

        app.staticTexts["Mike Torres"].tap()
        XCTAssertTrue(app.buttons["Messages with Mike Torres"].waitForExistence(timeout: 10), "Mike's week did not open")
        DemoScreens.shown("ClientScreen", as: .coach)
        hold(2.5)

        app.buttons["Messages with Mike Torres"].tap()
        hold(1)
        DemoScreens.shown("DayThread", as: .coach)
        hold(2.2)
        back(app)

        app.buttons["Mike Torres’s progress"].tap()
        XCTAssertTrue(app.navigationBars["Mike’s progress"].waitForExistence(timeout: 10), "Mike's progress did not open")
        DemoScreens.shown("ClientProgressScreen", as: .coach)
        hold(1.5)
        app.swipeUp()
        hold(1.2)
        back(app)

        dayMenu(app, "Add a Note for Mike")
        let note = app.alerts["Note on Today"]
        XCTAssertTrue(note.waitForExistence(timeout: 8), "The note did not open")
        DemoScreens.shown("ClientScreen.alert.note-on", as: .coach)
        note.textFields.firstMatch.typeText("Keep the bar speed up")
        hold(1)
        note.buttons["Send"].tap()
        hold(1.8)

        dayMenu(app, "Add a Run")
        XCTAssertTrue(app.navigationBars["Run Today"].waitForExistence(timeout: 8), "Add a Run did not open")
        DemoScreens.shown("PlanRunSheet", as: .coach)
        hold(1.8)
        cancel(app)

        dayMenu(app, "Move to Another Day")
        XCTAssertTrue(app.navigationBars["Move to Another Day"].waitForExistence(timeout: 8), "Move did not open")
        DemoScreens.shown("PlanDaySheet", as: .coach)
        hold(1.8)
        cancel(app)

        dayMenu(app, "Repeat for More Weeks…")
        XCTAssertTrue(app.navigationBars["Repeat This Week"].waitForExistence(timeout: 8), "Repeat did not open")
        DemoScreens.shown("RepeatWeekSheet", as: .coach)
        hold(1.8)
        cancel(app)

        dayMenu(app, "Start a Program…")
        XCTAssertTrue(app.navigationBars["Start a Program"].waitForExistence(timeout: 8), "Start a Program did not open")
        DemoScreens.shown("StartProgramSheet", as: .coach)
        hold(1.8)
        cancel(app)

        // Two days ago Mike logged squats: correct a set.
        openDay(app, daysAgo: 2)
        let squat = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Back Squat'")).firstMatch
        XCTAssertTrue(squat.waitForExistence(timeout: 8), "Mike's logged squats were not on his day")
        hold(1.5)
        squat.tap()
        XCTAssertTrue(app.navigationBars["Back Squat"].waitForExistence(timeout: 8), "Correcting sets did not open")
        DemoScreens.shown("CorrectSetsSheet", as: .coach)
        hold(1.8)
        cancel(app)
        back(app)

        // Ben has nothing planned: copy a session onto today.
        app.staticTexts["Ben Okafor"].tap()
        let copy = app.buttons["Copy a Session"]
        XCTAssertTrue(copy.waitForExistence(timeout: 10), "Ben's empty day did not offer Copy a Session")
        hold(1.5)
        copy.tap()
        XCTAssertTrue(app.navigationBars["Copy a Session"].waitForExistence(timeout: 8), "Copy a Session did not open")
        DemoScreens.shown("CopySessionSheet", as: .coach)
        hold(2)
        cancel(app)
        back(app)

        openYou(app, as: .coach)
        assertNoDebugRows(app)
        let pro = app.buttons["you.coachPro"]
        XCTAssertTrue(pro.waitForExistence(timeout: 8), "You has no Coach Pro row")
        pro.tap()
        let close = app.buttons["paywall.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 15), "Coach Pro's paywall did not open")
        // Both plans with their prices (AICoach.storekit), as App Review sees them, before the hold.
        XCTAssertTrue(app.buttons["paywall.yearly"].waitForExistence(timeout: 30), "Coach Pro's prices did not load")
        XCTAssertTrue(app.buttons["paywall.monthly"].exists)
        DemoScreens.shown("PaywallView.coach", as: .coach)
        hold(3)
        close.tap()
        hold(1)
        showAccount(app, as: .coach)
        DemoScreens.cue("end", .coach)
    }

    // MARK: Steps

    @MainActor
    private func launch(role: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting", "YES", "-role", role, "-demo", "YES",
                                "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    /// Today's session from the coach: check the lifts off and save.
    @MainActor
    private func logOpenSession(_ app: XCUIApplication) {
        let check = app.buttons["Check off as done"].firstMatch
        if !check.waitForExistence(timeout: 8) { app.swipeUp(); hold(0.5) }
        XCTAssertTrue(check.exists, "Today has no session from the coach to log")
        var taps = 0
        while app.buttons["Check off as done"].firstMatch.exists && taps < 8 {
            let box = app.buttons["Check off as done"].firstMatch
            if box.isHittable { box.tap() } else { box.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
            taps += 1
            hold(0.5)
        }
        let save = app.buttons["today.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 8), "Checking the lifts off did not offer Save workout")
        hold(1)
        if save.isHittable { save.tap() } else { save.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        // How it felt, if asked: skipped.
        let skip = app.buttons["Skip"]
        if skip.waitForExistence(timeout: 5) { hold(0.8); skip.tap() }
        hold(2)
    }

    @MainActor
    private func openYou(_ app: XCUIApplication, as role: DemoScreens.Role) {
        let you = app.buttons["Account and library"].firstMatch
        XCTAssertTrue(you.waitForExistence(timeout: 10), "No account button")
        you.tap()
        XCTAssertTrue(app.staticTexts["You"].waitForExistence(timeout: 10), "You did not open")
        DemoScreens.shown("YouScreen", as: role)
        hold(2)
    }

    /// The account, with Delete Account on it (not tapped).
    @MainActor
    private func showAccount(_ app: XCUIApplication, as role: DemoScreens.Role) {
        let row = app.descendants(matching: .any).matching(identifier: "you.account").firstMatch
        for _ in 0..<5 where !row.isHittable {
            app.swipeUp()
            hold(0.4)
        }
        XCTAssertTrue(row.waitForExistence(timeout: 8), "You did not list the account")
        hold(1)
        row.tap()
        XCTAssertTrue(app.buttons["account.delete"].waitForExistence(timeout: 10), "Delete Account was not on the account screen")
        DemoScreens.shown("AccountView", as: role)
        hold(3)
    }

    @MainActor
    private func assertNoDebugRows(_ app: XCUIApplication) {
        let debug = NSPredicate(format: "label CONTAINS[c] '(debug)'")
        XCTAssertFalse(app.descendants(matching: .any).matching(debug).firstMatch.exists, "A debug row is in frame")
    }

    /// The day's ⋯ on a client's week, then one of its actions.
    @MainActor
    private func dayMenu(_ app: XCUIApplication, _ action: String) {
        let menu = app.buttons["Change Today"]
        XCTAssertTrue(menu.waitForExistence(timeout: 8), "Today has no ⋯")
        if !menu.isHittable { app.swipeUp(); hold(0.4) }
        menu.tap()
        let item = app.buttons[action].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "The day's ⋯ has no \(action)")
        hold(1)
        item.tap()
    }

    /// A day on the client's week strip, by its date. Goes back a week first when the day was last week.
    @MainActor
    private func openDay(_ app: XCUIApplication, daysAgo: Int) {
        let calendar = Calendar.current
        let date = calendar.date(byAdding: .day, value: -daysAgo, to: .now)!
        if calendar.component(.weekOfYear, from: date) != calendar.component(.weekOfYear, from: .now) {
            app.swipeRight()
            hold(1)
        }
        let number = String(calendar.component(.day, from: date))
        let day = app.buttons.matching(NSPredicate(format: "label ENDSWITH %@ OR label == %@", ", \(number)", number)).firstMatch
        XCTAssertTrue(day.waitForExistence(timeout: 5), "The week strip has no \(number)")
        day.tap()
        hold(1.5)
    }

    @MainActor
    private func cancel(_ app: XCUIApplication) {
        let button = app.buttons["Cancel"].firstMatch
        if button.waitForExistence(timeout: 3) { button.tap() } else { app.swipeDown(velocity: .fast) }
        hold(1)
    }

    @MainActor
    private func back(_ app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
        hold(1.2)
    }

    private func hold(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }
}
