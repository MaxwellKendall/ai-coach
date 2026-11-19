import XCTest

/// TKL-801: the live workout in the Dynamic Island and on the Lock Screen, and its buttons working with the app in
/// the background. From a real workout it goes home, opens the island, taps Done set, −10s and Skip there, and checks
/// in the app that each changed the workout. Screenshots of each state go to build/screens/live-*-<appearance>.png
/// (`TEST_RUNNER_APPEARANCE=dark` names the dark run; set the simulator's appearance with
/// `xcrun simctl ui <device> appearance dark` first). Scheme ReviewDemo.
final class LiveActivityUITests: XCTestCase {
    @MainActor private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }
    private var appearance: String { ProcessInfo.processInfo.environment["APPEARANCE"] ?? "light" }

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor func testIslandAndLockScreenButtonsChangeTheWorkout() throws {
        // A run that stopped part way may have left the simulator locked.
        XCUIDevice.shared.press(.home)
        if springboard.staticTexts["Swipe up to open"].waitForExistence(timeout: 2) { unlock() }
        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting", "YES", "-role", "client", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let start = app.buttons.matching(NSPredicate(format: "label == 'Start the lifts' OR label == 'Start'")).firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 30), "No Start button")
        start.tap()
        // Past the warm-up to the first set: its Done starts a rest.
        let doneRest = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Done · rest'")).firstMatch
        for _ in 0..<12 where !doneRest.waitForExistence(timeout: 2) {
            app.buttons["Done"].firstMatch.tap()
        }
        XCTAssertTrue(doneRest.exists, "Never reached a set with a rest after it")

        // Lifting.
        home()
        save("live-lifting-compact")
        lock()
        save("live-lifting-lockscreen")
        unlock()
        expand()
        save("live-lifting-expanded")

        // Done set from the island logs it and starts its rest, with the app in the background.
        tapInIsland("Done set")
        expand()
        save("live-resting-expanded")
        home()
        save("live-resting-compact")
        lock()
        save("live-resting-lockscreen")
        unlock()
        app.activate()
        XCTAssertTrue(app.staticTexts["Rest"].waitForExistence(timeout: 10), "Done set didn't start the rest in the app")

        // −10s from the island shortens it; Skip ends it and the next set is on screen.
        let before = restLeft(app)
        home()
        expand()
        tapInIsland("10 seconds less")
        app.activate()
        let after = restLeft(app)
        XCTAssertLessThanOrEqual(after, before - 8, "−10s didn't shorten the rest (\(before) → \(after))")
        home()
        expand()
        tapInIsland("Skip rest")
        app.activate()
        XCTAssertTrue(doneRest.waitForExistence(timeout: 10), "Skip didn't go on to the next set")

        // A rest that runs out: the island says so.
        doneRest.tap()
        home()
        expand()
        for _ in 0..<40 where springboard.buttons["10 seconds less"].exists {
            springboard.buttons["10 seconds less"].tap()
            if restText().map({ $0 <= 10 }) ?? false { break }
        }
        sleep(14)
        save("live-restover-island")
        home()
        save("live-restover-compact")
        lock()
        save("live-restover-lockscreen")
        unlock()

        // The finish card: the last set from the list, done.
        app.activate()
        app.buttons["Whole workout"].tap()
        let sets = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Set '"))
        XCTAssertTrue(sets.firstMatch.waitForExistence(timeout: 5), "The list shows no sets")
        sets.element(boundBy: sets.count - 1).tap()
        app.buttons.matching(NSPredicate(format: "label == 'Done' OR label == 'Next'")).firstMatch.tap()
        home()
        save("live-done-compact")
        expand()
        save("live-done-expanded")
        lock()
        save("live-done-lockscreen")
        unlock()
    }

    // MARK: Driving the island

    @MainActor private func home() {
        XCUIDevice.shared.press(.home)
        sleep(2)
    }

    /// A long press on the Dynamic Island opens it.
    @MainActor private func expand() {
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.035)).press(forDuration: 1.2)
        sleep(2)
    }

    @MainActor private func tapInIsland(_ label: String) {
        let button = springboard.buttons[label].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "The island has no \(label) button")
        button.tap()
        sleep(3)
    }

    @MainActor private func lock() {
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        sleep(1)
        XCUIDevice.shared.press(.home) // wakes the screen, still locked
        sleep(2)
    }

    /// Allows Live Activities the first time the system asks (on the Lock Screen card), then swipes up from the
    /// bottom edge to unlock (the simulator has no passcode).
    @MainActor private func unlock() {
        let allow = springboard.buttons["Allow"].firstMatch
        if allow.waitForExistence(timeout: 1) { allow.tap(); sleep(1) }
        let bottom = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.995))
        bottom.press(forDuration: 0.05, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
        sleep(2)
        XCTAssertFalse(springboard.staticTexts["Swipe up to open"].exists, "Still locked")
    }

    /// Seconds left on the rest card in the app.
    @MainActor private func restLeft(_ app: XCUIApplication) -> Int {
        let clock = app.staticTexts.matching(NSPredicate(format: "label MATCHES '^[0-9]+:[0-9]{2}$'")).firstMatch
        XCTAssertTrue(clock.waitForExistence(timeout: 5), "No rest countdown in the app")
        return seconds(clock.label) ?? 0
    }

    /// Seconds left on the island's countdown, if it shows one.
    @MainActor private func restText() -> Int? {
        let clock = springboard.staticTexts.matching(NSPredicate(format: "label MATCHES '^[0-9]+:[0-9]{2}$'")).firstMatch
        return clock.exists ? seconds(clock.label) : nil
    }

    private func seconds(_ text: String) -> Int? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        return parts.count == 2 ? parts[0] * 60 + parts[1] : nil
    }

    @MainActor private func save(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "\(name)-\(appearance).png"
        attachment.lifetime = .keepAlways
        add(attachment)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appending(path: "build/screens")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: folder.appending(path: "\(name)-\(appearance).png"))
    }
}
