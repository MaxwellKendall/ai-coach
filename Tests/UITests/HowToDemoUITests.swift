import XCTest

/// TKL-793: how-to demos one tap away. From Today, one tap on a lift's demo tile opens its how-to with the clip
/// playing; a swipe pages to the session's next exercise; the set card's demo opens full screen and ✕ returns.
/// Screenshots go to build/screens/howto-*-<appearance>.png (`TEST_RUNNER_APPEARANCE=dark` names the dark run; set
/// the simulator's appearance with `xcrun simctl ui <device> appearance dark` first). Needs the network for the clips.
final class HowToDemoUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private let clip = NSPredicate(format: "label == 'Video: one rep of the movement'")
    private var appearance: String { ProcessInfo.processInfo.environment["APPEARANCE"] ?? "light" }

    @MainActor func testDemoOneTapFromTodayAndPagesToTheNextLift() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting", "YES", "-role", "client", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        let tiles = app.buttons.matching(identifier: "session.demo")
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 30), "Today's lifts have no demo tiles")
        XCTAssertGreaterThan(tiles.count, 1, "Paging needs a session with two lifts")
        let first = tiles.element(boundBy: 0)
        let firstName = first.label.replacingOccurrences(of: "How to do ", with: "")
        let secondName = tiles.element(boundBy: 1).label.replacingOccurrences(of: "How to do ", with: "")
        sleep(3) // the tiles' clips load and loop
        save("howto-today")

        // One tap: the how-to, its clip leading.
        first.tap()
        XCTAssertTrue(app.navigationBars[firstName].waitForExistence(timeout: 10), "The how-to didn't open on \(firstName)")
        // The sheet's own page (Today's tiles under it carry the same clip label).
        let page = app.descendants(matching: .any).matching(identifier: "howto.page").firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 10), "No how-to page")
        let sheetClip = page.descendants(matching: .any).matching(clip).firstMatch
        XCTAssertTrue(sheetClip.waitForExistence(timeout: 20), "The how-to shows no demo clip")
        sleep(3)
        save("howto-sheet")

        // Slow, then a swipe to the next lift.
        let slow = app.buttons["howto.slow"].firstMatch
        if slow.waitForExistence(timeout: 3) { slow.tap() }
        page.swipeLeft()
        XCTAssertTrue(app.navigationBars[secondName].waitForExistence(timeout: 10), "Swiping didn't page to \(secondName)")
        sleep(2)
        save("howto-next")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars[secondName].waitForNonExistence(timeout: 10), "The how-to didn't close")

        // The workout player: past the warm-up cards to a set with a demo, then full screen.
        let start = app.buttons.matching(NSPredicate(format: "label == 'Start the lifts' OR label == 'Start'")).firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 10), "No Start button")
        start.tap()
        let demo = app.buttons["workout.demo"].firstMatch
        for _ in 0..<10 where !demo.waitForExistence(timeout: 3) {
            if app.buttons["Done"].firstMatch.exists { app.buttons["Done"].firstMatch.tap() }
        }
        XCTAssertTrue(demo.exists, "The set card shows no demo")
        demo.tap()
        let close = app.buttons["demo.close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10), "The demo didn't open full screen")
        sleep(3)
        save("howto-fullscreen")
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 10), "✕ didn't return to the set")
        XCTAssertTrue(demo.waitForExistence(timeout: 5), "Not back on the set card")
        save("howto-workout")
    }

    /// Program › a session: each lift's card leads with its demo tile, which opens the how-to.
    @MainActor func testWorkoutDetailLeadsWithTheDemo() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting", "YES", "-role", "client", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let program = app.buttons["Program"].firstMatch
        XCTAssertTrue(program.waitForExistence(timeout: 30), "No Program tab")
        program.tap()
        // The first session that opens to change it: a done or missed day opens something else, so go back and try the next.
        let days = app.buttons.matching(identifier: "program.day")
        XCTAssertTrue(days.firstMatch.waitForExistence(timeout: 10), "No sessions on Program")
        let tile = app.buttons.matching(identifier: "session.demo").firstMatch
        for index in 0..<min(days.count, 6) {
            days.element(boundBy: index).tap()
            if tile.waitForExistence(timeout: 4) { break }
            if app.navigationBars.buttons.firstMatch.exists { app.navigationBars.buttons.firstMatch.tap() }
            if !program.isHittable { program.tap() }
            program.tap()
        }
        XCTAssertTrue(tile.exists, "No session's cards have demo tiles")
        sleep(3)
        save("howto-detail")
        let name = tile.label.replacingOccurrences(of: "How to do ", with: "")
        tile.tap()
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 10), "The tile didn't open \(name)'s how-to")
    }

    /// Offline before a clip was cached (`-exerciseDemos` pointed at a closed port, `-demoCache` a new empty folder): the
    /// how-to shows the photos and says it's offline.
    @MainActor func testOfflineShowsThePhotosAndSaysSo() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting", "YES", "-role", "client", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                                "-exerciseDemos", "http://127.0.0.1:9/", "-demoCache", "offline-\(UUID().uuidString)"]
        app.launch()
        let tile = app.buttons.matching(identifier: "session.demo").firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 30), "No demo tiles on Today")
        tile.tap()
        let note = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH \"You're offline\"")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 20), "The how-to doesn't say it's offline")
        sleep(2)
        save("howto-offline")
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
