import XCTest

/// FIT-386, FIT-437: the paywall review screenshots, one per plan, saved where `npm run release` uploads them from
/// (appstore/subscriptions.json: appstore/screenshots/lifter-pro.png and coach-pro.png). `-paywall lifter|coach`
/// (Debug) opens that plan's paywall alone. Each is checked for what App Review looks for (guideline 3.1.2): both
/// prices, the renewal terms, Restore Purchases, and the terms and privacy links.
final class PaywallScreenshotUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor func testLifterProPaywall() throws { try capture("lifter", to: "lifter-pro.png") }

    @MainActor func testCoachProPaywall() throws { try capture("coach", to: "coach-pro.png") }

    @MainActor
    private func capture(_ plan: String, to name: String) throws {
        let app = XCUIApplication()
        app.launchArguments += ["-paywall", plan, "-trialEligible", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        // The App Store's products, with their prices, once loaded.
        let yearly = app.buttons["paywall.yearly"]
        XCTAssertTrue(yearly.waitForExistence(timeout: 30), "The \(plan) paywall's products didn't load.")
        XCTAssertTrue(app.buttons["paywall.monthly"].exists)
        XCTAssertTrue(app.buttons["paywall.buy"].exists)
        XCTAssertTrue(app.staticTexts["paywall.terms.renewal"].exists)
        XCTAssertTrue(app.staticTexts[plan == "lifter" ? "Lifter Pro" : "Coach Pro"].exists)
        XCTAssertTrue(app.buttons["paywall.restore"].exists)
        XCTAssertTrue(app.buttons["paywall.terms"].exists || app.links["paywall.terms"].exists)
        XCTAssertTrue(app.buttons["paywall.privacy"].exists || app.links["paywall.privacy"].exists)

        // A simulator with no sandbox Apple Account gets the App Store's own sign-in over the app (it's StoreKit's,
        // in its own process); the screenshot is of the paywall, so it's dismissed.
        for owner in [app, XCUIApplication(bundleIdentifier: "com.apple.springboard")] {
            let cancel = owner.alerts.buttons["Cancel"]
            if cancel.waitForExistence(timeout: 2) { cancel.tap() }
        }
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 1))
        sleep(1)

        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        // The simulator shares the Mac's disk, so the file lands in the repo for the release command.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appending(path: "appstore/screenshots/\(name)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try shot.pngRepresentation.write(to: url)
    }
}
