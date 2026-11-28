import XCTest

/// TKL-1087: Progress › History shows the notes written about a workout: the first line in the list, the lifter's note
/// in full and the coach's session note on the day, and a long note cut short with Show all.
/// Screenshots go to build/screens/history-*-<appearance>.png (`APPEARANCE=dark` names the dark run; set the
/// simulator's appearance with `xcrun simctl ui <device> appearance dark` first). Scheme `ReviewDemo`.
final class HistoryNotesUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private var appearance: String { ProcessInfo.processInfo.environment["APPEARANCE"] ?? "light" }
    private let mine = "Felt fast today. Bench moved well."
    private let coach = "Pause the first rep of every bench set."
    private let long = "Squats felt heavy from the first warm-up set and the knee was a bit sore on the way down, so I kept "
        + "the depth just above parallel. Bench was better than last week. Rows were fine.\nSlept badly the night before, "
        + "and ate late, which probably didn't help.\nNext time: warm up longer, more ramp sets, and film the top set."

    @MainActor func testHistoryShowsTheLiftersAndTheCoachsNotes() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting", "YES", "-role", "solo", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                                "-units", try units()]
        app.launch()

        let progress = app.tabBars.buttons["Progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 30), "No Progress tab")
        progress.tap()
        let history = app.buttons["History"].firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 10), "No History tab on Progress")
        history.tap()

        // The list: a day with a note shows its first line; a day without one doesn't.
        let line = app.staticTexts[mine]
        XCTAssertTrue(line.waitForExistence(timeout: 10), "The list doesn't show the day's note")
        let firstLine = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Squats felt heavy'")).firstMatch
        line.swipeUp()
        XCTAssertTrue(firstLine.waitForExistence(timeout: 5), "The list doesn't show the long note's first line")
        save("history-list")

        // A day with both notes: the coach's, attributed, and the lifter's own, apart.
        line.tap()
        XCTAssertTrue(app.staticTexts["Your note"].waitForExistence(timeout: 10) || app.staticTexts["YOUR NOTE"].exists, "No Your note section")
        XCTAssertTrue(app.staticTexts[coach].exists, "The day doesn't show the coach's session note")
        XCTAssertTrue(app.staticTexts["Your coach"].exists, "The coach's note isn't attributed")
        XCTAssertTrue(app.staticTexts["“\(mine)”"].exists, "The day doesn't show the lifter's note")
        save("history-day-notes")
        app.navigationBars.buttons.firstMatch.tap()

        // A long note is cut short, with the sets still on screen, and opens in full.
        firstLine.tap()
        let all = app.buttons["Show all"]
        XCTAssertTrue(all.waitForExistence(timeout: 10), "A long note has no Show all")
        save("history-day-long")
        all.tap()
        XCTAssertTrue(app.buttons["Show less"].waitForExistence(timeout: 5))
        save("history-day-long-open")
        app.navigationBars.buttons.firstMatch.tap()

        // A day without a note: only Add a note, no empty note.
        let plain = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Oct 9'")).firstMatch
        if !plain.isHittable { app.swipeUp() }
        XCTAssertTrue(plain.waitForExistence(timeout: 5), "No Oct 9 in the list")
        plain.tap()
        XCTAssertTrue(app.buttons["Add a note"].waitForExistence(timeout: 10), "A day without a note offers no Add a note")
        save("history-day-none")
    }

    /// progress-units.json with notes: Oct 14 the lifter's and the coach's, Oct 12 a long one, Oct 9 none.
    private func units() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appending(path: "Fixtures/progress-units.json"))
        var units = try XCTUnwrap((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["units"] as? [String: Any])
        func note(_ day: String, _ text: String) {
            units["log#\(day)"] = (units["log#\(day)"] as! [[String: Any]]).map { row in
                var row = row
                if row["kind"] as? String == "workout" && row["template"] == nil { row["note"] = text }
                return row
            }
        }
        note("2026-10-14", mine)
        note("2026-10-12", long)
        note("2026-10-09", "")
        units["plan#2026-10-14"] = (units["plan#2026-10-14"] as! [[String: Any]]).map { row in
            var row = row
            row["sessionNote"] = coach
            return row
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "history-notes-units.json")
        try JSONSerialization.data(withJSONObject: units).write(to: url)
        return url.path
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
