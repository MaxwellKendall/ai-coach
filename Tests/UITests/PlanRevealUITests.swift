import XCTest

final class PlanRevealUITests: XCTestCase {
    @MainActor
    func testTrainingDayEditUpdatesTheRevealedPlan() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting", "YES", "-role", "solo", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        let account = app.buttons["Account and library"]
        XCTAssertTrue(account.waitForExistence(timeout: 30))
        account.tap()
        let program = app.buttons["you.program"]
        XCTAssertTrue(program.waitForExistence(timeout: 10))
        program.tap()

        let start = app.buttons["Start Program"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertTrue(start.isEnabled)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Plan reveal"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let days = app.staticTexts["Training days"]
        XCTAssertTrue(days.waitForExistence(timeout: 3))
        let monday = app.buttons["Monday"].firstMatch
        if monday.isHittable {
            monday.tap()
        } else {
            // The nested sheet can report the day button as unhittable even while it is visible.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.24, dy: 0))
                .withOffset(CGVector(dx: 0, dy: days.frame.maxY - app.frame.minY + 26))
                .tap()
        }
        let updated = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", ".*[24] days a week.*")).firstMatch
        XCTAssertTrue(updated.waitForExistence(timeout: 3))
        XCTAssertFalse(start.isEnabled)
    }
}
