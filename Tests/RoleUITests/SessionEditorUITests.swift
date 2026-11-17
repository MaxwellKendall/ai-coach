import XCTest

/// TKL-753: one session editor. Today opens a lift in place into Program's block card: every set a row, a number tapped
/// for the bottom stepper, Swap / + Set / ⋯ under it. Every change saves as it's made. Today's list has no copy of its
/// own (it reads the saved plan), so a lift folded and opened again shows what was saved.
final class SessionEditorUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testTodayEditsALiftWithProgramsCard() {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting", "YES", "-role", "solo", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["Check off as done"].firstMatch.waitForExistence(timeout: 30), "Today has no session")

        let lifts = app.buttons.matching(identifier: "session.lift")
        XCTAssertGreaterThanOrEqual(lifts.count, 3, "Today needs three lifts for this test")
        let liftsBefore = lifts.count

        // Open the first lift: its sets show, each a row of its own.
        lifts.element(boundBy: 0).tap()
        let firstLoad = cell(app, set: "1", metric: "load")
        XCTAssertTrue(firstLoad.waitForExistence(timeout: 5), "The open lift shows no set rows")
        let secondBefore = cell(app, set: "2", metric: "load").label
        let firstBefore = number(firstLoad.label)

        // Change set 1's load with the bottom stepper: +5 twice. Set 2 stays as it was.
        firstLoad.tap()
        let plus = app.buttons["stepper.plus"]
        XCTAssertTrue(plus.waitForExistence(timeout: 5), "No stepper rose from the bottom")
        plus.tap()
        plus.tap()
        app.buttons["stepper.done"].tap()
        XCTAssertEqual(number(cell(app, set: "1", metric: "load").label), firstBefore + 10, "Set 1's load didn't change")
        XCTAssertEqual(cell(app, set: "2", metric: "load").label, secondBefore, "Set 2 changed with set 1")

        // + Set adds a working set.
        let sets = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'set.0.' AND identifier ENDSWITH '.reps'"))
        let setsBefore = sets.count
        app.buttons["session.addSet"].tap()
        XCTAssertEqual(sets.count, setsBefore + 1, "+ Set didn't add a set")

        // Saved: fold the lift and open it again.
        lifts.element(boundBy: 0).tap()
        XCTAssertFalse(cell(app, set: "1", metric: "load").waitForExistence(timeout: 1), "The lift didn't fold")
        lifts.element(boundBy: 0).tap()
        XCTAssertTrue(cell(app, set: "1", metric: "load").waitForExistence(timeout: 5))
        XCTAssertEqual(number(cell(app, set: "1", metric: "load").label), firstBefore + 10, "The load change wasn't saved")
        XCTAssertEqual(sets.count, setsBefore + 1, "The added set wasn't saved")

        // ⋯ › Superset with the next lift: two lifts become one block.
        app.buttons["session.more"].tap()
        let superset = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Superset with'")).firstMatch
        XCTAssertTrue(superset.waitForExistence(timeout: 5), "⋯ has no Superset")
        superset.tap()
        XCTAssertTrue(waitForCount(lifts, liftsBefore - 1), "Superset didn't join two lifts")
        XCTAssertTrue(lifts.element(boundBy: 0).label.contains(" + "), "The superset isn't named for both lifts")

        // ⋯ › Remove: the lift goes.
        let last = lifts.element(boundBy: lifts.count - 1)
        let name = last.label
        last.tap()
        app.buttons["session.more"].tap()
        let remove = app.buttons["Remove \(name)"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "⋯ has no Remove \(name)")
        remove.tap()
        XCTAssertTrue(waitForCount(lifts, liftsBefore - 2), "Remove didn't remove the lift")
        XCTAssertFalse(app.buttons.matching(identifier: "session.lift").matching(NSPredicate(format: "label == %@", name)).firstMatch.exists)

        // Each change offered an Undo.
        XCTAssertTrue(app.buttons["Undo"].waitForExistence(timeout: 3), "No Undo after a change")
    }

    /// A number in the open lift's first movement: its set ("1", "2", "W") and metric ("reps", "load").
    @MainActor
    private func cell(_ app: XCUIApplication, set: String, metric: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "set.0.\(set).\(metric)")).firstMatch
    }

    private func number(_ label: String) -> Double {
        Double(label.split(separator: " ").first.map(String.init) ?? "") ?? -1
    }

    @MainActor
    private func waitForCount(_ query: XCUIElementQuery, _ count: Int) -> Bool {
        let done = NSPredicate { _, _ in query.count == count }
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: done, object: nil)], timeout: 5) == .completed
    }
}
