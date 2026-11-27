import XCTest

/// TKL-933: one workout on the real Today, cover and store, from Start through banked sets to a win on Today, and the
/// interruptions that must never log, lose or repeat a set. The fixture is a 2-set session with 10 s rests.
/// Run: `xcodebuild -scheme ReviewDemo -only-testing:AICoachUITests/WorkoutMotionUITests test`.
final class WorkoutMotionUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor func testStartToPersonalBest() {
        launch()
        runToPersonalBest()
    }

    @MainActor func testStartToPersonalBestWithReduceMotion() {
        launch("-workoutReduceMotion", "YES")
        runToPersonalBest()
    }

    @MainActor func testSaveWithoutPersonalBestSaysSaved() {
        launch("-workoutNoBest", "YES")
        startWorkout()
        logBothSets()
        app.buttons["Save workout"].tap()
        XCTAssertTrue(app.staticTexts["Workout saved"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Edit the sets"].exists)
        XCTAssertFalse(celebration.exists)
    }

    @MainActor func testLeavingWithoutSavingLogsNothing() {
        launch()
        startWorkout()
        done.tap()
        XCTAssertTrue(skip.waitForExistence(timeout: 5))
        app.buttons["Close"].tap()
        app.buttons["Discard sets"].tap()
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Edit the sets"].exists)
        startWorkout()
        XCTAssertFalse(app.staticTexts["Logged"].exists)
        assertLogged(0)
    }

    /// A zoomed cover can be dismissed by a swipe down or a pinch, which would skip "Leave this workout?".
    @MainActor func testSwipingOrPinchingTheCoverKeepsTheSets() {
        launch()
        startWorkout()
        done.tap()
        XCTAssertTrue(skip.waitForExistence(timeout: 5))
        drag(from: CGVector(dx: 0.5, dy: 0.25), to: CGVector(dx: 0.5, dy: 0.95))
        assertStillInWorkout()
        app.pinch(withScale: 0.4, velocity: -2)
        assertStillInWorkout()
        drag(from: CGVector(dx: 0.01, dy: 0.45), to: CGVector(dx: 0.9, dy: 0.45))
        assertStillInWorkout()
        assertLogged(1)
    }

    @MainActor func testSwipingLogsOnceAndSwipingBackKeepsTheSet() {
        launch()
        startWorkout()
        drag(from: CGVector(dx: 0.8, dy: 0.45), to: CGVector(dx: 0.15, dy: 0.45))
        XCTAssertTrue(skip.waitForExistence(timeout: 5))
        drag(from: CGVector(dx: 0.2, dy: 0.45), to: CGVector(dx: 0.85, dy: 0.45))
        XCTAssertTrue(app.staticTexts["Logged"].waitForExistence(timeout: 5))
        assertLogged(1)
        app.buttons["Next"].tap()
        XCTAssertTrue(skip.waitForExistence(timeout: 5))
        assertLogged(1)
    }

    @MainActor func testDoubleTapOnDoneLogsOneSet() {
        launch()
        startWorkout()
        done.doubleTap()
        XCTAssertTrue(skip.waitForExistence(timeout: 5))
        assertLogged(1)
    }

    /// The button of the next card is under the finger by the second tap.
    @MainActor func testDoubleTapOnTheLastWarmupLogsNothing() {
        launch()
        openWorkout()
        let warmupDone = app.buttons["Done"]
        XCTAssertTrue(warmupDone.waitForExistence(timeout: 5))
        // Every step but the last still names a warm-up dose after "Next:"; the last names the set, 185 × 5.
        for _ in 0..<10 where !app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Next:' AND label CONTAINS '185'")).firstMatch.exists {
            warmupDone.tap()
        }
        warmupDone.doubleTap()
        XCTAssertTrue(firstSet.waitForExistence(timeout: 5))
        XCTAssertFalse(skip.exists)
        assertLogged(0)
    }

    @MainActor func testDoubleTapOnTheLastDoneDoesNotSave() {
        launch()
        startWorkout()
        done.tap()
        XCTAssertTrue(skip.waitForExistence(timeout: 5))
        skip.tap()
        XCTAssertTrue(secondSet.waitForExistence(timeout: 5))
        done.doubleTap()
        XCTAssertTrue(app.staticTexts["All 2 sets"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Save workout"].isHittable)
    }

    // MARK: TKL-1097 Live workout bugs

    /// A swipe up skips the set: on to the next one, nothing logged, no rest.
    @MainActor func testSwipingUpSkipsASetWithoutLoggingIt() {
        launch()
        startWorkout()
        drag(from: CGVector(dx: 0.5, dy: 0.4), to: CGVector(dx: 0.5, dy: 0.08))
        XCTAssertTrue(secondSet.waitForExistence(timeout: 5))
        XCTAssertFalse(skip.exists, "Skipping a set skips its rest too")
        assertLogged(0)
    }

    /// A swipe left on a rest card (and on a set already logged) used to leave the next card where the finger let go,
    /// offset and tilted, with the screen behind it bare.
    @MainActor func testSwipingPastARestLeavesTheNextCardSettled() {
        launch()
        startWorkout()
        let home = firstSet.frame
        done.tap()
        XCTAssertTrue(skip.waitForExistence(timeout: 5))
        drag(from: CGVector(dx: 0.8, dy: 0.45), to: CGVector(dx: 0.3, dy: 0.45))
        XCTAssertTrue(secondSet.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(secondSet.frame.minX, home.minX, accuracy: 2, "The set card settled back where cards sit")
        XCTAssertEqual(secondSet.frame.minY, home.minY, accuracy: 2)
        // Back to the logged set, then a swipe left over it: the rest card it lands on sits home too.
        drag(from: CGVector(dx: 0.2, dy: 0.45), to: CGVector(dx: 0.85, dy: 0.45))
        XCTAssertTrue(skip.waitForExistence(timeout: 5))
        drag(from: CGVector(dx: 0.2, dy: 0.45), to: CGVector(dx: 0.85, dy: 0.45))
        XCTAssertTrue(app.staticTexts["Logged"].waitForExistence(timeout: 5))
        let logged = firstSet.frame
        XCTAssertEqual(logged.minX, home.minX, accuracy: 2)
        drag(from: CGVector(dx: 0.8, dy: 0.45), to: CGVector(dx: 0.3, dy: 0.45))
        XCTAssertTrue(skip.waitForExistence(timeout: 5))
        drag(from: CGVector(dx: 0.8, dy: 0.45), to: CGVector(dx: 0.3, dy: 0.45))
        XCTAssertTrue(secondSet.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(secondSet.frame.minX, home.minX, accuracy: 2)
        capture("tkl-1097-settled")
        assertLogged(1)
    }

    // MARK: TKL-934 Motion Pass 1

    @MainActor func testStepperRepeatUndoSupersetFeelAndPeek() {
        launch("-workoutSuperset", "YES")
        startWorkout()
        // Stepper tap and hold-to-repeat on load.
        let heavier = app.buttons["5 lb heavier"]
        XCTAssertTrue(heavier.waitForExistence(timeout: 5))
        heavier.tap()
        XCTAssertTrue(app.staticTexts["190"].waitForExistence(timeout: 3))
        heavier.press(forDuration: 1.0)
        XCTAssertFalse(app.staticTexts["190"].exists, "Holding + accelerates past 190")

        // Bank set 1 and Undo from the toast to lift the chip back out.
        done.tap()
        XCTAssertTrue(skip.waitForExistence(timeout: 5))
        let undo = app.buttons["Undo"]
        if undo.waitForExistence(timeout: 3) {
            undo.tap()
            XCTAssertTrue(firstSet.waitForExistence(timeout: 5))
        }

        // Re-log set 1, adjust rest with +30 s / -30 s, then Skip to set 2.
        done.tap()
        XCTAssertTrue(skip.waitForExistence(timeout: 5))
        app.buttons["30 seconds more"].tap()
        app.buttons["30 seconds less"].tap()
        skip.tap()
        XCTAssertTrue(secondSet.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(skip.waitForExistence(timeout: 5))
        skip.tap()

        // Superset card with coach cue.
        XCTAssertTrue(app.staticTexts["Set 1 of 1 · superset"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Row between bench sets."].waitForExistence(timeout: 5))

        // Open peek and return.
        app.buttons["Whole workout"].tap()
        XCTAssertTrue(app.staticTexts["2 of 4 sets logged"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["Done"].tap()

        // Log superset → Finish card → tap Feel choices → Save.
        done.tap()
        XCTAssertTrue(app.buttons["Save workout"].waitForExistence(timeout: 5))
        app.buttons["Good"].tap()
        app.buttons["Hard"].tap()
        app.buttons["Save workout"].tap()
        XCTAssertTrue(celebration.waitForExistence(timeout: 8))
    }

    @MainActor func testGoalHitCelebration() {
        launch("-workoutGoalHit", "YES")
        startWorkout()
        logBothSets()
        app.buttons["Save workout"].tap()
        XCTAssertTrue(celebration.waitForExistence(timeout: 8))
        capture("goal-hit")
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Edit the sets"].waitForExistence(timeout: 5))
    }

    @MainActor func testMultipleWinsFannedAndThrowAside() {
        launch("-workoutMultiWin", "YES")
        startWorkout()
        done.tap()
        XCTAssertTrue(skip.waitForExistence(timeout: 5))
        skip.tap()
        XCTAssertTrue(secondSet.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(skip.waitForExistence(timeout: 5))
        skip.tap()
        XCTAssertTrue(app.staticTexts["Set 1 of 1 · superset"].waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(app.buttons["Save workout"].waitForExistence(timeout: 5))
        app.buttons["Save workout"].tap()
        let firstHeading = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Nice work · 1 of '")).firstMatch
        XCTAssertTrue(firstHeading.waitForExistence(timeout: 8))
        capture("multi-win-1")
        drag(from: CGVector(dx: 0.7, dy: 0.4), to: CGVector(dx: 0.05, dy: 0.4))
        let secondHeading = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Nice work · 2 of '")).firstMatch
        XCTAssertTrue(secondHeading.waitForExistence(timeout: 5))
        capture("multi-win-2")
    }

    @MainActor func testFinishedProgramPlaysProgramDoneCard() {
        let appearance = ProcessInfo.processInfo.environment["TEST_RUNNER_APPEARANCE"] ?? "light"
        let outDir = ProcessInfo.processInfo.environment["TEST_RUNNER_SHOT_DIR"]
        app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "YES", "-role", "solo", "-programDoneFixture", "YES"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Program done"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Up next"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["See the recap"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Pick Another"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1.2)
        saveShot("pdone-\(appearance)", to: outDir)
    }

    /// Captures the 5 prototype comparison screens (set, banking, rest, finish, celebration) into /tmp when requested.
    @MainActor func testDesignComparisonShots() {
        let appearance = ProcessInfo.processInfo.environment["TEST_RUNNER_APPEARANCE"] ?? "light"
        let outDir = ProcessInfo.processInfo.environment["TEST_RUNNER_SHOT_DIR"]
        launch()
        startWorkout()
        saveShot("set-\(appearance)", to: outDir)
        done.tap()
        Thread.sleep(forTimeInterval: 0.25)
        saveShot("banking-\(appearance)", to: outDir)
        XCTAssertTrue(skip.waitForExistence(timeout: 5))
        saveShot("rest-\(appearance)", to: outDir)
        skip.tap()
        XCTAssertTrue(secondSet.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(app.buttons["Save workout"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1.0)
        app.buttons["Good"].tap()
        saveShot("finish-\(appearance)", to: outDir)
        app.buttons["Save workout"].tap()
        XCTAssertTrue(celebration.waitForExistence(timeout: 8))
        Thread.sleep(forTimeInterval: 1.3)
        saveShot("celebration-\(appearance)", to: outDir)
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Edit the sets"].waitForExistence(timeout: 5))
    }

    @MainActor private func saveShot(_ name: String, to dir: String?) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? shot.pngRepresentation.write(to: url)
        }
    }

    // MARK: The path

    @MainActor private func runToPersonalBest() {
        let otherDay = app.buttons.matching(identifier: "today.otherDay").firstMatch
        XCTAssertTrue(otherDay.waitForExistence(timeout: 20))
        otherDay.tap()
        XCTAssertTrue(start.waitForNonExistence(timeout: 5) || !start.isHittable)
        app.buttons["today.currentDay"].tap()
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        openWorkout()
        capture("1-start")
        advanceWarmup()
        done.tap()
        capture("2-bank")
        XCTAssertTrue(skip.waitForExistence(timeout: 5))
        XCTAssertTrue(secondSet.waitForExistence(timeout: 20), "The rest ends on the next set")
        capture("3-ready")
        done.tap()
        let save = app.buttons["Save workout"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["All 2 sets"].exists)
        save.tap()
        // The sheet's heading: Today's done card has a "PERSONAL BEST" of its own.
        let win = celebration
        XCTAssertTrue(win.waitForExistence(timeout: 8))
        capture("4-win")
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(win.waitForNonExistence(timeout: 5))
        XCTAssertFalse(win.waitForExistence(timeout: 2), "The celebration is presented once")
        XCTAssertTrue(app.buttons["Edit the sets"].isHittable)
        XCTAssertFalse(start.exists)
        capture("5-today")
    }

    // MARK: Helpers

    @MainActor private var start: XCUIElement { app.buttons["Start"] }
    @MainActor private var skip: XCUIElement { app.buttons["Skip"] }
    @MainActor private var firstSet: XCUIElement { app.staticTexts["Set 1 of 2"] }
    @MainActor private var secondSet: XCUIElement { app.staticTexts["Set 2 of 2"] }
    @MainActor private var celebration: XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Nice work'")).firstMatch
    }
    @MainActor private var done: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Done'")).firstMatch
    }

    @MainActor private func launch(_ extra: String...) {
        app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "YES", "-role", "client", "-workoutMotionFixture", "YES"] + extra
        app.launch()
    }

    @MainActor private func openWorkout() {
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        start.tap()
        XCTAssertTrue(app.buttons["Whole workout"].waitForExistence(timeout: 5))
    }

    @MainActor private func startWorkout() {
        openWorkout()
        advanceWarmup()
    }

    @MainActor private func advanceWarmup() {
        for _ in 0..<10 {
            if firstSet.exists { break }
            app.buttons["Done"].tap()
        }
        XCTAssertTrue(firstSet.waitForExistence(timeout: 5))
    }

    @MainActor private func logBothSets() {
        done.tap()
        XCTAssertTrue(skip.waitForExistence(timeout: 5))
        skip.tap()
        XCTAssertTrue(secondSet.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(app.buttons["Save workout"].waitForExistence(timeout: 5))
    }

    @MainActor private func assertStillInWorkout() {
        XCTAssertFalse(start.waitForExistence(timeout: 1) && start.isHittable, "The cover was dismissed")
        XCTAssertTrue(app.buttons["Whole workout"].isHittable)
    }

    @MainActor private func assertLogged(_ count: Int) {
        app.buttons["Whole workout"].tap()
        let subtitle = app.staticTexts["\(count) of 2 sets logged"]
        XCTAssertTrue(subtitle.waitForExistence(timeout: 5))
        // Close the peek again: it covers the card, so a tap after this one would be swallowed by the sheet.
        app.navigationBars.buttons["Done"].tap()
        XCTAssertTrue(subtitle.waitForNonExistence(timeout: 5))
    }

    @MainActor private func drag(from: CGVector, to: CGVector) {
        app.coordinate(withNormalizedOffset: from).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: to))
    }

    @MainActor private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
