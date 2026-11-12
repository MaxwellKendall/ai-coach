import StoreKitTest
import XCTest

/// FIT-445: what each role sees: its tabs, and that its key screens open with something on them. Each test launches
/// with `-uiTesting YES -role …` (App/DebugRole.swift): an empty in-memory store, signed out, nothing from the server.
/// With SCREENS_DIR in the test runner's environment (TEST_RUNNER_SCREENS_DIR for xcodebuild), each screen is saved
/// there as after-<name>.png.
final class RoleUITests: XCTestCase {
    private let athlete = ["Today", "Program", "Progress"]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCoachSeesClientsAlone() {
        let app = launch("coach")
        XCTAssertEqual(tabs(app), ["Clients"])
        XCTAssertTrue(app.navigationBars["Clients"].waitForExistence(timeout: 10), "Clients did not open")
        let mike = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Mike Torres'")).firstMatch
        XCTAssertTrue(mike.waitForExistence(timeout: 10), "The roster has no clients")
        shot(app, "coach-clients")
        mike.tap()
        XCTAssertTrue(app.navigationBars["Mike Torres"].waitForExistence(timeout: 10), "A client's screen did not open")
        shot(app, "coach-client-detail")
        app.navigationBars.buttons.firstMatch.tap()
        openYou(app)
        shot(app, "coach-you")
        // FIT-437: Coach Pro, in coach mode only; no Lifter Pro.
        XCTAssertFalse(app.buttons["you.lifterPro"].exists, "A coach is offered Lifter Pro")
    }

    /// FIT-437: in coach mode, You's Coach from Claude (Coach Pro's MCP) opens Coach Pro's paywall.
    @MainActor
    func testCoachReachesTheCoachProPaywall() throws {
        let session = try storeKit()
        defer { _ = session }
        let app = launch("coach")
        XCTAssertEqual(tabs(app), ["Clients"])
        openYou(app)
        let row = app.buttons["you.coachPro"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "You has no Coach Pro for a coach")
        shot(app, "coach-you-plans")
        row.tap()
        assertPaywall(app, "Coach Pro", prices: ["$19.99/month", "$199.00/year"], trial: false)
        shot(app, "coach-coach-pro-paywall")
    }

    @MainActor
    func testClientSeesTheirCoachesWeekAndNoClients() {
        let app = launch("client")
        XCTAssertEqual(tabs(app), athlete)
        XCTAssertFalse(app.tabBars.buttons["Clients"].exists)
        XCTAssertFalse(app.navigationBars["Clients"].exists)
        // Sam's session for today, to log.
        let check = app.buttons["Check off as done"].firstMatch
        XCTAssertTrue(check.waitForExistence(timeout: 15), "Today has no session from the coach")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Squat'")).firstMatch.exists,
                      "Sam's Back Squat isn't on Today")
        shot(app, "client-today")
        tap(check)
        XCTAssertTrue(app.buttons["today.save"].waitForExistence(timeout: 8), "Checking a lift off did not offer Save workout")
        openTab(app, "Program")
        shot(app, "client-program")
        openTab(app, "Progress")
        shot(app, "client-progress")
        openTab(app, "Today")
        openYou(app)
        // A coach's client picks no program of their own, and has a coach already.
        XCTAssertFalse(app.buttons["you.program"].exists, "You offers a client a program of their own")
        XCTAssertFalse(app.buttons["you.joinCoach"].exists, "You offers a client Join Your Coach")
        // FIT-437: a coach's client never sees a paywall, nor a way to one.
        XCTAssertFalse(app.buttons["you.lifterPro"].exists, "You offers a client Lifter Pro")
        XCTAssertFalse(app.buttons["you.coachPro"].exists, "You offers a client Coach Pro")
        XCTAssertFalse(app.otherElements["paywall.lifter"].exists || app.otherElements["paywall.coach"].exists, "A client saw a paywall")
        shot(app, "client-you")
    }

    /// The bug: a sample roster (the server's Mike, before FIT-445) made a coached client a coach, opening on Clients.
    @MainActor
    func testClientWithASampleRosterHasNoClientsTab() {
        let app = launch("client", ["-sampleClients", "YES"])
        XCTAssertEqual(tabs(app), athlete)
        XCTAssertFalse(app.tabBars.buttons["Clients"].exists)
        XCTAssertTrue(app.tabBars.buttons["Today"].isSelected, "A client didn't open on Today")
        shot(app, "client-sample-regression-tabs")
    }

    @MainActor
    func testSoloLifterHasAWeekPlannedAndCanFindACoach() {
        let app = launch("solo")
        XCTAssertEqual(tabs(app), athlete)
        XCTAssertTrue(app.buttons["Check off as done"].firstMatch.waitForExistence(timeout: 15), "Today has no session")
        XCTAssertFalse(app.buttons["today.pickProgram"].exists, "A lifter with a program is asked to pick one")
        shot(app, "solo-free-today")
        openTab(app, "Program")
        shot(app, "solo-free-program")
        openTab(app, "Progress")
        shot(app, "solo-free-progress")
        openTab(app, "Today")
        openYou(app)
        XCTAssertTrue(app.buttons["you.program"].waitForExistence(timeout: 5), "You has no Program for a lifter on their own")
        XCTAssertTrue(app.buttons["you.joinCoach"].exists, "You has no Join Your Coach")
        shot(app, "solo-free-you")
    }

    @MainActor
    func testSoloLifterWithNoProgramIsOfferedOne() {
        let app = launch("solo", ["-noProgram", "YES"])
        XCTAssertEqual(tabs(app), athlete)
        // Today renders the days beside it too, so the button is there for each: today's is the one on screen.
        XCTAssertTrue(app.buttons["today.pickProgram"].firstMatch.waitForExistence(timeout: 10), "Today doesn't offer a program")
        let pick = app.buttons.matching(identifier: "today.pickProgram").allElementsBoundByIndex.first { $0.isHittable }!
        shot(app, "solo-noprogram-today")
        pick.tap()
        XCTAssertTrue(app.staticTexts["What’s your goal?"].waitForExistence(timeout: 10), "Pick a program did not open the picker")
    }

    /// FIT-437: Lifter Pro's AI planning is reached from You, never by itself: not on Today, not after picking a program.
    /// A free lifter's paywall has both prices, the trial, the renewal terms, Restore and the Terms and Privacy links.
    @MainActor
    func testSoloFreeReachesTheLifterProPaywall() throws {
        let session = try storeKit()
        defer { _ = session }
        let app = launch("solo", ["-trialEligible", "YES"])
        XCTAssertTrue(app.buttons["Check off as done"].firstMatch.waitForExistence(timeout: 15), "Today has no session")
        XCTAssertFalse(app.buttons["paywall.buy"].exists, "A paywall showed by itself")
        openYou(app)
        let row = app.buttons["you.lifterPro"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "You has no Lifter Pro for a lifter on their own")
        XCTAssertFalse(app.buttons["you.coachPro"].exists, "A lifter is offered Coach Pro")
        shot(app, "solo-free-you-plans")
        row.tap()
        assertPaywall(app, "Lifter Pro", prices: ["$5.99/month", "$39.99/year"], trial: true)
        shot(app, "solo-free-lifter-pro-paywall")
    }

    /// FIT-437: a Pro lifter sees no paywall: You says Lifter Pro, and opening it says they have it, with no offer.
    @MainActor
    func testSoloProSeesNoPaywall() {
        let app = launch("soloPro")
        XCTAssertEqual(tabs(app), athlete)
        XCTAssertTrue(app.buttons["Check off as done"].firstMatch.waitForExistence(timeout: 15), "Today has no session")
        XCTAssertFalse(app.buttons["paywall.buy"].exists, "A paywall showed")
        shot(app, "solo-pro-today")
        openYou(app)
        let row = app.buttons["you.lifterPro"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "You has no Lifter Pro row")
        XCTAssertTrue(row.label.contains("Lifter Pro"), "You doesn't say they have Lifter Pro: \(row.label)")
        shot(app, "solo-pro-you")
        row.tap()
        XCTAssertTrue(app.staticTexts["You have Lifter Pro"].waitForExistence(timeout: 10), "Lifter Pro isn't shown as theirs")
        XCTAssertFalse(app.buttons["paywall.buy"].exists, "A Pro lifter was offered Lifter Pro")
        XCTAssertFalse(app.buttons["paywall.yearly"].exists, "A Pro lifter was shown the prices")
        shot(app, "solo-pro-lifter-pro-unlocked")
    }

    @MainActor
    func testFirstLaunchOpensOnWelcome() {
        let app = launch(nil, ["-welcomed", "NO"])
        XCTAssertTrue(app.buttons["welcome.join"].waitForExistence(timeout: 30), "Welcome did not show Join them")
        // Its splash hands over to the doors.
        Thread.sleep(forTimeInterval: 2)
        shot(app, "first-launch-welcome")
    }

    // MARK: Helpers

    /// The App Store's products from AICoach.storekit, for as long as the returned session lives.
    private func storeKit() throws -> SKTestSession {
        let session = try SKTestSession(configurationFileNamed: "AICoach")
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        return session
    }

    /// What App Review looks for on a paywall (guideline 3.1.2), once its products load.
    @MainActor
    private func assertPaywall(_ app: XCUIApplication, _ name: String, prices: [String], trial: Bool) {
        XCTAssertTrue(app.buttons["paywall.yearly"].waitForExistence(timeout: 30), "\(name)'s products didn't load")
        XCTAssertTrue(app.staticTexts[name].exists, "No \(name) title")
        for price in prices {
            XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", price)).firstMatch.exists,
                          "No price \(price)")
        }
        // The yearly option says its free trial ("2 weeks free"), and only Lifter Pro has one.
        let yearly = app.buttons["paywall.yearly"].label
        XCTAssertEqual(yearly.contains(" free"), trial, trial ? "No free trial shown: \(yearly)" : "A free trial shown for a plan without one")
        let terms = app.staticTexts["paywall.terms.renewal"]
        XCTAssertTrue(terms.exists, "No renewal terms")
        XCTAssertTrue(terms.label.localizedCaseInsensitiveContains("renew"), "The terms don't say it renews: \(terms.label)")
        XCTAssertTrue(app.buttons["paywall.buy"].exists, "No buy button")
        XCTAssertTrue(app.buttons["paywall.restore"].exists, "No Restore Purchases")
        XCTAssertTrue(app.buttons["paywall.terms"].exists || app.links["paywall.terms"].exists, "No Terms of Use link")
        XCTAssertTrue(app.buttons["paywall.privacy"].exists || app.links["paywall.privacy"].exists, "No Privacy Policy link")
    }

    @MainActor
    private func launch(_ role: String?, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            + (role.map { ["-role", $0] } ?? []) + extra
        app.launch()
        return app
    }

    /// The tab bar's buttons, in order, once it's there.
    @MainActor
    private func tabs(_ app: XCUIApplication) -> [String] {
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "No tab bar")
        return app.tabBars.firstMatch.buttons.allElementsBoundByIndex.map(\.label)
    }

    @MainActor
    private func openTab(_ app: XCUIApplication, _ name: String) {
        app.tabBars.buttons[name].tap()
        XCTAssertTrue(app.tabBars.buttons[name].isSelected)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'couldn’t' OR label CONTAINS[c] 'error'")).firstMatch.exists,
                       "\(name) shows an error")
    }

    @MainActor
    private func openYou(_ app: XCUIApplication) {
        let you = app.buttons["Account and library"]
        XCTAssertTrue(you.waitForExistence(timeout: 10), "No account button")
        you.tap()
        XCTAssertTrue(app.staticTexts["You"].waitForExistence(timeout: 10), "You did not open")
    }

    /// The check-off circle is a plain button that XCTest often reports as not hittable while it's on screen.
    @MainActor
    private func tap(_ element: XCUIElement) {
        if element.isHittable { element.tap() } else { element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
    }

    @MainActor
    private func shot(_ app: XCUIApplication, _ name: String) {
        Thread.sleep(forTimeInterval: 0.8)
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let dir = ProcessInfo.processInfo.environment["SCREENS_DIR"] else { return }
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appending(path: "after-\(name).png"))
    }
}
