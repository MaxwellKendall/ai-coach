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
        openMore(for: last, in: app)
        let remove = app.buttons["Remove \(name)"]
        XCTAssertTrue(waitUntil { remove.exists }, "⋯ has no Remove \(name)")
        remove.tap()
        XCTAssertTrue(waitForCount(lifts, liftsBefore - 2), "Remove didn't remove the lift")
        XCTAssertFalse(app.buttons.matching(identifier: "session.lift").matching(NSPredicate(format: "label == %@", name)).firstMatch.exists)

        // Undo takes back the removal (and the superset too if its 6 s Undo toast is still up: TKL-759):
        // either way, the removed lift is back on Today.
        let undo = app.buttons["Undo"]
        XCTAssertTrue(waitUntil(timeout: 3) { undo.exists }, "No Undo after a change")
        undo.tap()
        let restored = app.buttons.matching(identifier: "session.lift").matching(NSPredicate(format: "label == %@", name)).firstMatch
        XCTAssertTrue(waitUntil { restored.exists && (lifts.count == liftsBefore - 1 || lifts.count == liftsBefore) }, "Undo didn't bring the lift back")
    }

    /// Every lift removed, then Undo: the whole session comes back (the review's empty-session case).
    @MainActor
    func testUndoBringsBackASessionWithEveryLiftRemoved() {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting", "YES", "-role", "solo", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["Check off as done"].firstMatch.waitForExistence(timeout: 30), "Today has no session")
        let lifts = app.buttons.matching(identifier: "session.lift")
        let names = lifts.allElementsBoundByIndex.map(\.label)
        XCTAssertFalse(names.isEmpty)
        for (removed, name) in names.enumerated() {
            let lift = lifts.matching(NSPredicate(format: "label == %@", name)).firstMatch
            XCTAssertTrue(waitUntil { lift.exists }, "\(name) isn't on Today")
            openMore(for: lift, in: app)
            let remove = app.buttons["Remove \(name)"]
            XCTAssertTrue(waitUntil { remove.exists }, "⋯ has no Remove \(name)")
            remove.tap()
            XCTAssertTrue(waitForCount(lifts, names.count - removed - 1), "Remove didn't remove \(name)")
        }
        let undo = app.buttons["Undo"]
        XCTAssertTrue(waitUntil(timeout: 3) { undo.exists }, "No Undo after removing the last lift")
        undo.tap()
        XCTAssertTrue(waitForCount(lifts, names.count), "Undo didn't bring the session back")
        XCTAssertEqual(lifts.allElementsBoundByIndex.map(\.label), names, "The session came back changed")
    }

    /// The arrow at a lift's right edge opens its sets, and folds them again (TestFlight 14: it did nothing).
    @MainActor
    func testTheArrowOpensAndFoldsALift() {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting", "YES", "-role", "solo", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["Check off as done"].firstMatch.waitForExistence(timeout: 30), "Today has no session")
        let arrow = app.buttons.matching(identifier: "session.arrow").firstMatch
        XCTAssertTrue(arrow.waitForExistence(timeout: 5), "A lift has no arrow to tap")
        arrow.tap()
        XCTAssertTrue(cell(app, set: "1", metric: "load").waitForExistence(timeout: 5), "Tapping the arrow didn't open the lift's sets")
        arrow.tap()
        XCTAssertFalse(cell(app, set: "1", metric: "load").waitForExistence(timeout: 2), "Tapping the arrow again didn't fold the lift")
    }

    /// A number in the open lift's first movement: its set ("1", "2", "W") and metric ("reps", "load").
    @MainActor
    private func cell(_ app: XCUIApplication, set: String, metric: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "set.0.\(set).\(metric)")).firstMatch
    }

    private func number(_ label: String) -> Double {
        Double(label.split(separator: " ").first.map(String.init) ?? "") ?? -1
    }

    /// TKL-1017: SessionList unfolds BlockEditor with withMotion(.settle) inside a .clipped() VStack (TKL-782).
    /// Wait for the unfold to settle before tapping ⋯, or the tap lands on the next lift row moving out from under it.
    @MainActor
    private func openMore(for lift: XCUIElement, in app: XCUIApplication) {
        lift.tap()
        let more = app.buttons["session.more"]
        // Don't require isHittable: on a lower lift, session.more sits below Start until tap() scrolls it into view.
        XCTAssertTrue(waitUntil { more.exists }, "The open lift has no ⋯")
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        more.tap()
    }

    /// Polls promptly (without XCTest's ~1 s initial waitForExistence delay) so multi-lift edits stay inside the 6 s Undo toast.
    @MainActor
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        if condition() { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            if condition() { return true }
        }
        return condition()
    }

    @MainActor
    private func waitForCount(_ query: XCUIElementQuery, _ count: Int) -> Bool {
        waitUntil(timeout: 5) { query.count == count }
    }
}
