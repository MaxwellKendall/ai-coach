import XCTest

final class CoachMotionUITests: XCTestCase {
    @MainActor
    func testSampleRosterLeadsWithNeedsAndMovesRepliedClientDown() {
        let app = launch()
        let mike = app.buttons["coach.client.Mike Torres"]
        let sara = app.buttons["coach.client.Sara Kim"]
        XCTAssertTrue(mike.waitForExistence(timeout: 10))
        XCTAssertLessThan(mike.frame.minY, sara.frame.minY)
        mike.tap()
        XCTAssertTrue(app.navigationBars["Mike Torres"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'coach.day.'")).firstMatch.exists)
        shot(app, "Sample coach client week")

        let reply = app.buttons["coach.flagReply"].firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 5))
        reply.tap()
        let composer = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("Let's check your next workout.")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.staticTexts["Let's check your next workout."].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(mike.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(mike.frame.minY, sara.frame.minY)
        app.scrollViews.firstMatch.swipeDown()
    }

    @MainActor
    func testSamplePlanRepeatsAndInviteCanBeCopied() {
        let app = launch()
        app.buttons["Invite a client"].tap()
        app.buttons["Make the Invite"].tap()
        let copy = app.buttons["Copy Code"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Share Link"].exists)
        shot(app, "Sample invite ready to share")
        copy.tap()
        XCTAssertTrue(app.buttons["Copied"].exists)
        dismissSheet(app, titled: "Invite a client")

        let mike = app.buttons["coach.client.Mike Torres"]
        XCTAssertTrue(mike.waitForExistence(timeout: 5))
        tap(mike)
        let actions = app.buttons["coach.dayActions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        actions.tap()
        app.buttons["Repeat for More Weeks…"].tap()
        app.buttons["Repeat"].tap()
        XCTAssertTrue(app.staticTexts["Repeated for 3 weeks"].waitForExistence(timeout: 5))
        shot(app, "Sample repeated weeks")
    }

    @MainActor
    func testSampleCopiesMovesAndStartsAProgram() {
        let app = launch()
        app.buttons["coach.client.Mike Torres"].tap()
        let actions = app.buttons["coach.dayActions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        actions.tap()
        app.buttons["Copy to Another Day"].tap()
        app.navigationBars.buttons["Copy"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Copied to '")).firstMatch.waitForExistence(timeout: 5))
        actions.tap()
        app.buttons["Move to Another Day"].tap()
        app.navigationBars.buttons["Move"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Moved to '")).firstMatch.waitForExistence(timeout: 5))
        // The move leaves today empty. Pick the copied session on the next day.
        dayButton(1, in: app).tap()
        actions.tap()
        app.buttons["Start a Program…"].tap()
        let availableProgram = app.buttons.matching(NSPredicate(format: "label CONTAINS 'weeks'")).firstMatch
        XCTAssertTrue(availableProgram.waitForExistence(timeout: 5))
        availableProgram.tap()
        app.navigationBars.buttons["Start"].tap()
        let replace = app.buttons["Replace"]
        if replace.waitForExistence(timeout: 2) { replace.tap() }
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS ' starts '")).firstMatch.waitForExistence(timeout: 5))
        shot(app, "Sample ready program sent")
    }

    @MainActor
    func testSampleClientProgressShowsCharts() {
        let app = launch()
        app.buttons["coach.client.Mike Torres"].tap()
        app.buttons["Mike Torres’s progress"].tap()
        XCTAssertTrue(app.staticTexts["Estimated max"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Sessions, last 8 weeks"].exists)
        shot(app, "Sample client progress")
    }

    @MainActor
    func testSampleCorrectedSetShowsNewWeightAndEstimate() {
        let app = launch()
        app.buttons["coach.client.Mike Torres"].tap()
        dayButton(-2, in: app).tap()
        let row = app.buttons["coach.correct.back-squat"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("Est."))
        row.tap()
        let load = app.textFields.firstMatch
        load.tap()
        load.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3) + "255")
        app.navigationBars.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Corrected"].waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("255"))
        shot(app, "Sample corrected set")
    }

    @MainActor
    private func dayButton(_ offset: Int, in app: XCUIApplication) -> XCUIElement {
        let date = Calendar.current.date(byAdding: .day, value: offset, to: .now)!
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let id = String(format: "coach.day.%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
        let button = app.buttons[id]
        if !button.exists {
            let strip = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'coach.day.'"))
            if offset < 0 { strip.element(boundBy: 3).swipeRight() } else { strip.element(boundBy: 3).swipeLeft() }
        }
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        return button
    }

    /// The invite sheet has no Done: a swipe on its title can bounce it back, so fall back to tapping
    /// the dimmed area above it, and don't go on until its title has left the screen.
    @MainActor
    private func dismissSheet(_ app: XCUIApplication, titled title: String) {
        let sheet = app.staticTexts[title].firstMatch
        for attempt in 0..<4 where sheet.exists {
            if attempt % 2 == 0 {
                // Drag the sheet itself down to the bottom of the screen, as a thumb does.
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
                    .press(forDuration: 0.1,
                           thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
            } else {
                // Or tap the dimmed roster above it: at the very top the status bar takes the tap.
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
            }
            _ = sheet.waitForNonExistence(timeout: 3)
        }
        XCTAssertFalse(sheet.exists, "The \(title) sheet would not close")
    }

    /// The row is there before the sheet above it has finished leaving, and a tap into a sheet is lost.
    @MainActor
    private func tap(_ element: XCUIElement) {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline && !element.isHittable {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        XCTAssertTrue(element.isHittable, "\(element) never took a tap")
        element.tap()
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "YES", "-role", "coach", "-sampleClients", "YES",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Clients"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func shot(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
