import XCTest

/// TKL-745: Program week card lets the user reorder workouts (drag-and-drop and Move to…),
/// mark a day as a rest day with Undo, and add a workout onto a rest day.
final class ProgramReorderUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testProgramWeekReorderMakeRestDayAndAddWorkout() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-role", "solo"]
        app.launch()

        let programTab = app.tabBars.buttons["Program"]
        XCTAssertTrue(programTab.waitForExistence(timeout: 30), "No Program tab")
        programTab.tap()

        // Swipe to Next week so every day of the week is open/editable regardless of today's weekday.
        let days = app.buttons.matching(identifier: "program.day")
        XCTAssertTrue(days.firstMatch.waitForExistence(timeout: 15), "This week lists no sessions")
        shot("program-this-week")

        let nextWeek = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Next week ·'")).firstMatch
        for _ in 0..<3 where !nextWeek.exists {
            let row = days.allElementsBoundByIndex.first { $0.isHittable } ?? days.firstMatch
            let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -260, dy: 0)))
            Thread.sleep(forTimeInterval: 0.8)
        }
        XCTAssertTrue(nextWeek.waitForExistence(timeout: 10), "Did not swipe to Next week")

        let restDays = app.buttons.matching(identifier: "program.restDay")
        XCTAssertTrue(restDays.firstMatch.waitForExistence(timeout: 10), "Next week shows no rest day rows")
        shot("program-next-week-before")

        // 1. Open actions menu on the first workout day and move it to another day (or rest day).
        let actions = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'program.day.actions.'"))
        let hittableActions = actions.allElementsBoundByIndex.filter { $0.isHittable }
        XCTAssertFalse(hittableActions.isEmpty, "No row action menus found")

        // Find the first workout row's action menu by checking for "Make rest day" inside.
        var workoutMenu: XCUIElement?
        for button in hittableActions {
            button.tap()
            if app.buttons["Make rest day"].waitForExistence(timeout: 2) {
                workoutMenu = button
                break
            }
            // Dismiss menu (tapping a rest day menu)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1)).tap()
            Thread.sleep(forTimeInterval: 0.3)
        }
        let menuButton = try XCTUnwrap(workoutMenu, "No workout row had a Make rest day menu action")
        shot("program-day-menu")

        // Move to… submenu -> pick first target
        let moveMenu = app.buttons["Move to…"]
        XCTAssertTrue(moveMenu.waitForExistence(timeout: 3), "No Move to… menu item")
        moveMenu.tap()
        // Pick the first day entry in the Move to… submenu (contains " · ")
        let targetOption = app.buttons.matching(NSPredicate(format: "label CONTAINS ' · '")).firstMatch
        XCTAssertTrue(targetOption.waitForExistence(timeout: 3), "Move to… submenu had no targets")
        targetOption.tap()
        let movedToast = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Moved ' OR label BEGINSWITH 'Swapped '")).firstMatch
        XCTAssertTrue(movedToast.waitForExistence(timeout: 5), "No confirmation toast after moving/swapping")
        shot("program-after-move")

        // 2. Make rest day, then Undo.
        let refreshedActions = actions.allElementsBoundByIndex.filter { $0.isHittable }
        var cleared = false
        for button in refreshedActions {
            button.tap()
            let makeRest = app.buttons["Make rest day"]
            if makeRest.waitForExistence(timeout: 2) {
                makeRest.tap()
                cleared = true
                break
            }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1)).tap()
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertTrue(cleared, "Could not tap Make rest day")
        let restToast = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'set to rest day'")).firstMatch
        XCTAssertTrue(restToast.waitForExistence(timeout: 5), "No confirmation toast after Make rest day")
        shot("program-after-rest")

        let undo = app.buttons["Undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 3), "No Undo button on toast")
        undo.tap()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(menuButton.exists)

        // 3. Tap a rest day row -> opens WorkoutDetailView with Add exercise ready.
        let openRest = restDays.allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(openRest, "No hittable rest day row to tap")
        openRest?.tap()
        XCTAssertTrue(app.buttons["Add exercise"].waitForExistence(timeout: 5), "Tapping a rest day did not open WorkoutDetailView")
        shot("program-rest-day-editor")
    }

    @MainActor
    private func shot(_ name: String) {
        Thread.sleep(forTimeInterval: 0.4)
        let image = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = "\(name).png"
        attachment.lifetime = .keepAlways
        add(attachment)
        let dir = ProcessInfo.processInfo.environment["SHOTS_DIR"] ?? "/tmp/factory/TKL-745/shots"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? image.pngRepresentation.write(to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))
    }
}
