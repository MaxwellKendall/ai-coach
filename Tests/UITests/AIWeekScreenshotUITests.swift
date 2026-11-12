import XCTest

/// FIT-426: screenshots of "Plan my next week" for a Lifter Pro solo lifter (the week designed by `StubDesigner`, with
/// `-aiWeeks YES`: no network, no model) and the paywall a free lifter gets instead. Each PNG is also written to
/// SHOTS_DIR (TEST_RUNNER_SHOTS_DIR for xcodebuild), /tmp/fit426-shots by default, named `<prefix>-<name>.png`.
final class AIWeekScreenshotUITests: XCTestCase {
    private var prefix: String { ProcessInfo.processInfo.environment["SHOTS_PREFIX"] ?? "after" }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLifterProPlansNextWeek() {
        let app = launch("soloPro", ["-aiWeeks", "YES"])
        XCTAssertTrue(app.buttons["Check off as done"].firstMatch.waitForExistence(timeout: 30), "Today has no session")
        openTab(app, "Program")
        let plan = revealPlanButton(app)
        shot(app, "1-program")
        plan.tap()
        // The designed week's per-change reasons are on the session, one tap from the week's day (WorkoutDetailView).
        let monday = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Squat'")).firstMatch
        XCTAssertTrue(monday.waitForExistence(timeout: 10), "Next week has no Squat session to open")
        monday.tap()
        let squat = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Squat up 5 lb'")).firstMatch
        XCTAssertTrue(squat.waitForExistence(timeout: 30), "The redesigned week shows no reason lines")
        shot(app, "2-week")
        // Today, with its own coach line; next week's reasons belong to next week's days, not today's.
        if app.buttons["Close"].exists { app.buttons["Close"].tap() } else { app.swipeDown() }
        openTab(app, "Today")
        XCTAssertTrue(app.buttons["Check off as done"].firstMatch.waitForExistence(timeout: 10), "Today has no session")
        shot(app, "3-today")
    }

    @MainActor
    func testFreeLifterGetsThePaywall() {
        let app = launch("solo", ["-trialEligible", "YES"])
        XCTAssertTrue(app.buttons["Check off as done"].firstMatch.waitForExistence(timeout: 30), "Today has no session")
        openTab(app, "Program")
        revealPlanButton(app).tap()
        XCTAssertTrue(app.buttons["paywall.buy"].waitForExistence(timeout: 30), "No Lifter Pro paywall")
        for owner in [app, XCUIApplication(bundleIdentifier: "com.apple.springboard")] {
            let cancel = owner.alerts.buttons["Cancel"]
            if cancel.waitForExistence(timeout: 2) { cancel.tap() }
        }
        shot(app, "4-free-paywall")
    }

    @MainActor
    private func launch(_ role: String, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-role", role] + extra
        app.launch()
        return app
    }

    @MainActor
    private func openTab(_ app: XCUIApplication, _ name: String) {
        XCTAssertTrue(app.tabBars.buttons[name].waitForExistence(timeout: 10))
        app.tabBars.buttons[name].tap()
    }

    /// The button is on the Next week card, behind this week's in the deck.
    @MainActor
    @discardableResult
    private func revealPlanButton(_ app: XCUIApplication) -> XCUIElement {
        let plan = app.buttons["program.planNextWeek"]
        for _ in 0..<3 where !plan.isHittable {
            app.swipeLeft()
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(plan.waitForExistence(timeout: 10) && plan.isHittable, "Program's Next week has no Plan my next week")
        return plan
    }

    @MainActor
    private func shot(_ app: XCUIApplication, _ name: String) {
        Thread.sleep(forTimeInterval: 0.8)
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let dir = ProcessInfo.processInfo.environment["SHOTS_DIR"] ?? "/tmp/fit426-shots"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appending(path: "\(prefix)-\(name).png"))
    }
}
