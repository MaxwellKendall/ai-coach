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
        // Part 1: a first launch, signed out: sign in, then join Sam by the invite code.
        var app = launch(role: "new", signedOut: true)
        let join = app.buttons["welcome.join"]
        XCTAssertTrue(join.waitForExistence(timeout: 40), "Welcome did not show Have a coach?")
        hold(1.5)
        DemoScreens.cue("begin", .client)
        DemoScreens.shown("WelcomeView", as: .client)
        hold(2)
        join.tap()
        signIn(app, email: "jordan@example.com", as: .client)
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
        clientTodayTour(app)
        logOpenSession(app)
        clientAfterLogging(app)
        app.tabBars.buttons["Program"].tap()
        DemoScreens.shown("tab.Program", as: .client)
        hold(2.5)
        visit("WorkoutDetailView", by: app.buttons["program.day"].firstMatch, until: app.buttons["Done"].firstMatch, in: app)
        app.tabBars.buttons["Progress"].tap()
        DemoScreens.shown("tab.Progress", as: .client)
        hold(2.5)
        clientProgressTour(app)
        app.tabBars.buttons["Today"].tap()
        hold(1)
        openYou(app, as: .client)
        assertNoDebugRows(app)
        clientYouTour(app)
        showAccount(app, as: .client)
        DemoScreens.cue("end", .client)
    }

    // MARK: Coach

    /// The coach door and a first invite, then a full roster: messaging everyone, a client's week (planning, a note,
    /// moving and repeating it, a program), their messages and progress, correcting a logged set, copying a session,
    /// Coach Pro's paywall, and the account with Delete Account.
    @MainActor
    func testCoachChapter() throws {
        // Part 1: in by the coach's door, signing in (a new coach's account is made the same way), to an empty
        // roster, and the first invite.
        var app = launch(role: "new", signedOut: true)
        let door = app.buttons["welcome.coach"]
        XCTAssertTrue(door.waitForExistence(timeout: 40), "Welcome did not show I'm a coach")
        hold(1.5)
        DemoScreens.cue("begin", .coach)
        DemoScreens.shown("WelcomeView", as: .coach)
        hold(1.5)
        door.tap()
        signIn(app, email: "coach@example.com", as: .coach)
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
    private func launch(role: String, signedOut: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting", "YES", "-role", role, "-demo", "YES",
                                "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        // TKL-460: signed out, so the chapter shows signing in; demo mode signs any email in locally (DemoCloud.user).
        if signedOut { app.launchArguments += ["-demoSignedOut", "YES"] }
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

    /// Sign in with email, as App Review does. Demo mode signs in locally with any email and password, so the
    /// password typed here is a placeholder, not a demo account's; the field is secure, so the video shows dots.
    @MainActor
    private func signIn(_ app: XCUIApplication, email: String, as role: DemoScreens.Role) {
        let withEmail = app.buttons["signin.email"]
        XCTAssertTrue(withEmail.waitForExistence(timeout: 15), "Sign in with email was not on screen")
        DemoScreens.shown("SignInSheet", as: role)
        hold(2)
        withEmail.tap()
        let field = app.textFields["signin.emailField"]
        XCTAssertTrue(field.waitForExistence(timeout: 8), "The email form did not open")
        hold(0.6)
        field.tap()
        field.typeText(email)
        let password = app.secureTextFields["signin.passwordField"]
        password.tap()
        password.typeText("demo-only\n")
        notNow(app)
        _ = field.waitForNonExistence(timeout: 10)
        // The keyboard can stay up after the form goes; a tap on the empty top of the screen puts it away.
        for _ in 0..<3 where app.keyboards.firstMatch.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
            hold(0.6)
        }
        hold(1.5)
    }

    /// iOS's Save Password? offer, if it shows: Not Now.
    @MainActor
    private func notNow(_ app: XCUIApplication, timeout: TimeInterval = 3) {
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

    /// One screen of the tour: tap `control`; once `until` shows, mark `id`, hold, and close it. A control that isn't
    /// there leaves the screen unmarked, so the coverage check reports it rather than the recording stopping.
    @MainActor
    @discardableResult
    private func visit(_ id: String, by control: XCUIElement, until shown: XCUIElement, in app: XCUIApplication,
                       as role: DemoScreens.Role = .client, hold seconds: TimeInterval = 2, close: Bool = true) -> Bool {
        guard control.waitForExistence(timeout: 4) else { return false }
        if !control.isHittable { app.swipeUp(); hold(0.4) }
        guard control.isHittable else { return false }
        control.tap()
        guard shown.waitForExistence(timeout: 8) else { dismiss(app); return false }
        DemoScreens.shown(id, as: role)
        hold(seconds)
        if close { dismiss(app) }
        return true
    }

    /// Closes whatever is on top: Cancel, Done or Close, or back, or a swipe down.
    @MainActor
    private func dismiss(_ app: XCUIApplication) {
        for label in ["Cancel", "Done", "Close"] {
            let button = app.navigationBars.buttons[label].firstMatch
            if button.exists && button.isHittable { button.tap(); hold(1); return }
        }
        for label in ["Cancel", "Done", "Skip", "Not Now"] {
            let button = app.buttons[label].firstMatch
            if button.exists && button.isHittable { button.tap(); hold(1); return }
        }
        app.swipeDown(velocity: .fast)
        hold(1)
    }

    /// Today, before logging: the coach's messages, the check-ins, how a lift is done, its sets, adding a lift, moving
    /// the day, logging it another way, and workout mode.
    @MainActor
    private func clientTodayTour(_ app: XCUIApplication) {
        let top = { app.swipeDown(); self.hold(0.4) }
        visit("CoachConversation", by: app.buttons["Messages with Sam"], until: app.navigationBars["Sam"], in: app, hold: 2.5)
        top()
        visit("CheckInSheet", by: app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Check in'")).firstMatch,
              until: app.navigationBars.buttons["Save"], in: app)
        visit("WeeklyCheckInSheet", by: app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Weekly check-in'")).firstMatch,
              until: app.navigationBars["Weekly Check-in"], in: app)
        visit("HowToSheet", by: app.buttons["Open Back Squat"], until: app.navigationBars["Back Squat"], in: app, hold: 2.5)
        visit("SetStepper", by: app.buttons.matching(identifier: "session.lift").firstMatch, until: app.buttons["stepper.done"], in: app,
              close: false)
        if app.buttons["stepper.done"].exists { app.buttons["stepper.done"].tap(); hold(1) }
        visit("ExercisePicker", by: app.buttons["Add exercise"], until: app.navigationBars.buttons["Cancel"], in: app)
        let more = app.buttons["More"].firstMatch
        if more.waitForExistence(timeout: 3) {
            if !more.isHittable { app.swipeUp(); hold(0.4) }
            more.tap()
            visit("MoveSheet", by: app.buttons["Move to Another Day"], until: app.staticTexts["Move to another day"], in: app)
        }
        if more.exists && more.isHittable {
            more.tap()
            visit("LogChoiceSheet", by: app.buttons["Log It Without Starting"], until: app.staticTexts["Log a workout"].firstMatch, in: app)
        }
        visit("WorkoutModeView", by: app.buttons["Start"].firstMatch, until: app.buttons["Done"].firstMatch, in: app, hold: 3, close: false)
        // Leaving workout mode before a set is logged: Done, and discard nothing logged if asked.
        if app.buttons["Done"].firstMatch.exists { app.buttons["Done"].firstMatch.tap(); hold(1) }
        if app.buttons["Discard sets"].exists { app.buttons["Discard sets"].tap(); hold(1) }
        top()
    }

    /// Today, once the session's logged: what was logged and a note on it.
    @MainActor
    private func clientAfterLogging(_ app: XCUIApplication) {
        visit("SessionRecordView", by: app.buttons["Edit the sets"].firstMatch, until: app.navigationBars.buttons["Done"], in: app, hold: 2.5)
        visit("WorkoutNoteSheet", by: app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'note'")).firstMatch,
              until: app.navigationBars["Note"], in: app)
    }

    /// Progress: adding a goal, a goal's change, Wins and History with the day just logged.
    @MainActor
    private func clientProgressTour(_ app: XCUIApplication) {
        visit("NewGoalSheet", by: app.buttons["Add a goal"].firstMatch, until: app.navigationBars["Add a goal"], in: app)
        visit("GoalChangeSheet", by: app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Back squat max'")).element(boundBy: 1),
              until: app.navigationBars["Change Goal"], in: app)
        let wins = app.buttons["Wins"].firstMatch
        if wins.waitForExistence(timeout: 3) {
            wins.tap()
            hold(2)
            if app.staticTexts["No wins yet"].exists { DemoScreens.shown("WinsScreen.empty.no-wins-yet", as: .client) }
        }
        let history = app.buttons["History"].firstMatch
        if history.waitForExistence(timeout: 3) {
            history.tap()
            hold(1.5)
            visit("HistoryDayView", by: app.cells.firstMatch.exists ? app.cells.firstMatch : app.buttons.matching(NSPredicate(format: "label CONTAINS 'Lower A'")).firstMatch,
                  until: app.navigationBars.element(boundBy: 0).buttons.element(boundBy: 0), in: app, close: false)
            if app.navigationBars.buttons.count > 0 { back(app) }
        }
    }

    /// You: the profile, and the exercises with one's detail and a new one.
    @MainActor
    private func clientYouTour(_ app: XCUIApplication) {
        visit("ProfileEditor", by: app.buttons["Profile"], until: app.navigationBars["Profile"], in: app, close: false)
        if app.navigationBars["Profile"].exists { app.navigationBars["Profile"].buttons.element(boundBy: 0).tap(); hold(1) }
        if visit("CatalogScreen", by: app.buttons["Exercises"], until: app.navigationBars["Exercises"], in: app, close: false) {
            visit("TemplateEditor", by: app.navigationBars["Exercises"].buttons["Add"], until: app.navigationBars.buttons["Save"], in: app)
            visit("TemplateDetailView", by: app.cells.element(boundBy: 0), until: app.navigationBars.element(boundBy: 0), in: app, close: false)
            back(app)
            back(app)
        }
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
