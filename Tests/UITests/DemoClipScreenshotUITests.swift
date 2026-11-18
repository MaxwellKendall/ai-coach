import XCTest

/// TKL-790 (TKL-447's last two items): the batch-1 form demos play from the site in the app. A client with Sam's
/// Back Squat today opens its how-to sheet, then starts the workout; each screen shows the demo clip and is saved as a
/// screenshot under build/screens/. Debug builds read the clips from dev.barbrabell.com, so this needs the network.
final class DemoClipScreenshotUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private let clip = NSPredicate(format: "label == 'Video: one rep of the movement'")

    @MainActor func testBackSquatDemoInHowToAndWorkout() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting", "YES", "-role", "client", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        // Today: open Back Squat's row, then More › How to Do It.
        let squat = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Back Squat'")).firstMatch
        if !squat.waitForExistence(timeout: 30) { save("today-missing.png") }
        XCTAssertTrue(squat.exists, "No Back Squat on Today")
        squat.tap()
        let more = app.buttons["session.more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10), "Back Squat's row has no More menu")
        more.tap()
        let howTo = app.buttons["How to Do It"]
        XCTAssertTrue(howTo.waitForExistence(timeout: 5), "No How to Do It")
        howTo.tap()
        let sheetClip = app.descendants(matching: .any).matching(clip).firstMatch
        XCTAssertTrue(sheetClip.waitForExistence(timeout: 20), "The how-to sheet shows no demo clip")
        // Full height, scrolled to the clip, so the whole demo is in the picture.
        app.navigationBars.firstMatch.swipeUp()
        for _ in 0..<3 where !sheetClip.isHittable { app.swipeUp() }
        sleep(4) // the clip downloads into the cache and starts looping
        save("howto-back-squat.png")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(sheetClip.waitForNonExistence(timeout: 10), "The how-to sheet didn't close")

        // Start the lifts: the set card shows the demo, small.
        let start = app.buttons.matching(NSPredicate(format: "label == 'Start the lifts' OR label == 'Start'")).firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 10), "No Start button")
        start.tap()
        // Past the warm-up card to Back Squat's first set.
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10), "The workout didn't open")
        done.tap()
        // Then past the warm-up ramp (no clip on those cards) to the first working set.
        let clipShown = app.descendants(matching: .any).matching(clip).firstMatch
        for _ in 0..<8 where !clipShown.waitForExistence(timeout: 3) {
            if app.buttons["Done"].firstMatch.exists { app.buttons["Done"].firstMatch.tap() }
        }
        let cardClip = app.descendants(matching: .any).matching(clip).firstMatch
        if !cardClip.waitForExistence(timeout: 20) { save("workout-missing.png") }
        XCTAssertTrue(cardClip.exists, "The workout's set card shows no demo clip")
        sleep(4)
        save("workout-back-squat.png")
    }

    @MainActor private func save(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appending(path: "build/screens")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: folder.appending(path: name))
    }
}
