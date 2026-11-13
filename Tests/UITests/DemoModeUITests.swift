import StoreKitTest
import XCTest

/// FIT-446: `-demo YES` is the App Review demo: no debug rows, already signed in as a local demo account, and a
/// Lifter Pro purchase that completes at once (Pro.buy's demo branch) and unlocks Pro, with nothing sent to a server.
/// The paywall's products still come from AICoach.storekit (SKTestSession); the purchase itself can't run there:
/// SKTestSession is "notEntitled" in a UI-test process, and the app's own purchase asks for a real Apple Account.
final class DemoModeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDemoBuysLifterProWithoutSigningIn() async throws {
        let session = try SKTestSession(configurationFileNamed: "AICoach")
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        try await buyInDemo(session)
        withExtendedLifetime(session) {}
    }

    @MainActor
    private func buyInDemo(_ session: SKTestSession) async throws {

        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting", "YES", "-role", "solo", "-demo", "YES", "-aiWeeks", "YES", "-trialEligible", "YES",
                                "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "No tab bar")

        // You: no debug chrome.
        let you = app.buttons["Account and library"]
        XCTAssertTrue(you.waitForExistence(timeout: 10))
        you.tap()
        XCTAssertTrue(app.staticTexts["You"].waitForExistence(timeout: 10), "You did not open")
        XCTAssertTrue(app.buttons["you.lifterPro"].waitForExistence(timeout: 5), "You has no Lifter Pro")
        let debug = NSPredicate(format: "label CONTAINS[c] '(debug)'")
        XCTAssertFalse(app.descendants(matching: .any).matching(debug).firstMatch.exists, "You shows a debug row")
        app.swipeUp()
        XCTAssertFalse(app.descendants(matching: .any).matching(debug).firstMatch.exists, "You shows a debug row below the fold")
        XCTAssertFalse(app.staticTexts["Backend (debug)"].exists)
        app.swipeDown()
        // Close You (a sheet).
        if app.buttons["Done"].exists { app.buttons["Done"].tap() } else { app.swipeDown(velocity: .fast) }

        // Program → Plan my next week → the paywall.
        app.tabBars.buttons["Program"].tap()
        let plan = app.buttons["program.planNextWeek"]
        for _ in 0..<3 where !plan.isHittable {
            app.swipeLeft()
            try await Task.sleep(for: .seconds(1))
        }
        XCTAssertTrue(plan.waitForExistence(timeout: 10) && plan.isHittable, "No Plan my next week")
        plan.tap()
        let buy = app.buttons["paywall.buy"]
        XCTAssertTrue(buy.waitForExistence(timeout: 30), "Lifter Pro's products didn't load")
        XCTAssertFalse(app.descendants(matching: .any).matching(debug).firstMatch.exists, "The paywall shows a debug row")
        buy.tap()

        // Apple's confirmation, if StoreKit shows one.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for name in ["Subscribe", "Confirm"] {
            let button = springboard.buttons[name]
            if button.waitForExistence(timeout: 2) { button.tap(); break }
        }
        // A purchase closes the paywall.
        let gone = NSPredicate(format: "exists == false")
        await fulfillment(of: [expectation(for: gone, evaluatedWith: buy)], timeout: 30)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Sign in first'")).firstMatch.exists)
        XCTAssertFalse(app.buttons["signin.email"].exists, "A sign-in sheet opened")

        // Pro is unlocked: You says so, and opening it says they have it.
        app.tabBars.buttons["Today"].tap()
        let account = app.buttons["Account and library"]
        XCTAssertTrue(account.waitForExistence(timeout: 10))
        account.tap()
        let row = app.buttons["you.lifterPro"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "You has no Lifter Pro row")
        row.tap()
        XCTAssertTrue(app.staticTexts["You have Lifter Pro"].waitForExistence(timeout: 15), "Lifter Pro is not unlocked after buying")
        XCTAssertFalse(app.buttons["paywall.buy"].exists, "A Pro lifter was offered Lifter Pro")
    }

    // Coach and client: the demo shows no debug chrome on You (or on the first screen), and nothing asks to sign in.
    @MainActor func testDemoCoachHasNoDebugChrome() throws { try assertNoDebugChrome(role: "coach") }
    @MainActor func testDemoClientHasNoDebugChrome() throws { try assertNoDebugChrome(role: "client") }

    @MainActor
    private func assertNoDebugChrome(role: String) throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting", "YES", "-role", role, "-demo", "YES",
                                "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30) || app.buttons["Account and library"].waitForExistence(timeout: 30), "\(role): no home screen")
        let debug = NSPredicate(format: "label CONTAINS[c] '(debug)'")
        XCTAssertFalse(app.descendants(matching: .any).matching(debug).firstMatch.exists, "\(role): home shows a debug row")
        let you = app.buttons["Account and library"]
        XCTAssertTrue(you.waitForExistence(timeout: 10), "\(role): no You button")
        you.tap()
        XCTAssertTrue(app.staticTexts["You"].waitForExistence(timeout: 10), "\(role): You did not open")
        XCTAssertFalse(app.descendants(matching: .any).matching(debug).firstMatch.exists, "\(role): You shows a debug row")
        app.swipeUp()
        XCTAssertFalse(app.descendants(matching: .any).matching(debug).firstMatch.exists, "\(role): You shows a debug row below the fold")
        XCTAssertFalse(app.buttons["signin.email"].exists, "\(role): asked to sign in")
    }
}
