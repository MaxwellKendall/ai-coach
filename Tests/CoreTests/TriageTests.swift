import Foundation
import Testing
@testable import AICoach

/// FIT-298: the dashboard's triage cases (web/src/triage.test.ts), so the phone flags the same clients. "Today" is
/// Friday Oct 16.
struct TriageTests {
    private let today = "2026-10-16"
    private let names = ["back-squat": "Back Squat"]

    private func json(_ rows: [[String: Any]]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: rows), as: UTF8.self)
    }
    private func plan(_ day: String) -> (String, String) {
        ("plan#\(day)", json([["id": "p-\(day)", "kind": "workout", "template": "back-squat", "targets": [], "note": "", "main": true, "pinned": false]]))
    }
    private func log(_ day: String, measurements: [[String: Any]] = []) -> (String, String) {
        ("log#\(day)", json([["id": "l-\(day)", "kind": "workout", "plannedRef": "p-\(day)", "template": "back-squat",
                              "measurements": measurements, "note": ""]]))
    }
    private func units(_ pairs: (String, String)...) -> [String: String] { Dictionary(pairs, uniquingKeysWith: { a, _ in a }) }
    private func week(_ units: [String: String], _ comments: [Triage.Comment] = []) -> Triage.Week {
        Triage.week(units, comments: comments, names: names, coach: "sam", today: today)
    }

    private var onTrack: [String: String] { units(plan("2026-10-12"), plan("2026-10-14"), plan("2026-10-17"), log("2026-10-12"), log("2026-10-14")) }
    private var missing: [String: String] { units(plan("2026-10-12"), plan("2026-10-14"), plan("2026-10-16"), log("2026-10-09")) }
    private var noted: [String: String] {
        units(plan("2026-10-14"), ("log#2026-10-14", json([
            ["id": "l-1", "kind": "workout", "plannedRef": "p-2026-10-14", "template": "back-squat", "measurements": [], "note": "Lower"],
            ["id": "l-2", "kind": "workout", "measurements": [], "note": "Knee felt tight on the last set"],
        ])))
    }

    @Test func countsThisWeekAndTheLastSession() {
        #expect(week(onTrack) == Triage.Week(done: 2, planned: 3, lastSession: "2026-10-14", flags: []))
    }

    @Test func flagsMissedSessions() {
        #expect(week(missing).flags == [.init(kind: .missed, text: "Missed 2 sessions this past week")])
    }

    @Test func flagsANoteUntilTheCoachReplies() {
        #expect(week(noted).flags == [.init(kind: .pain, text: "Wednesday: “Knee felt tight on the last set”", day: "2026-10-14")])
        let reply = Triage.Comment(day: "2026-10-14", at: "", by: "sam", byName: "Sam", text: "Ice it.")
        #expect(week(noted, [reply]).flags.isEmpty)
        var theirs = reply
        theirs.by = "ann"
        #expect(week(noted, [theirs]).flags.count == 1)
    }

    @Test func flagsRPE9OnAMainLift() {
        let hard = units(plan("2026-10-14"), log("2026-10-14", measurements: [["metric": "rpe", "value": 9.5, "unit": "rpe"]]))
        #expect(week(hard).flags == [.init(kind: .hard, text: "RPE 9+ on Back Squat")])
    }

    @Test func flagsAStalledMainLift() {
        let sq = { (day: String, load: Double) in
            log(day, measurements: [["metric": "load_lb", "value": load, "unit": "lb"], ["metric": "reps", "value": 5, "unit": "reps"]])
        }
        let stalled = units(plan("2026-10-14"), sq("2026-09-14", 245), sq("2026-09-30", 240), sq("2026-10-07", 240), sq("2026-10-14", 240))
        #expect(week(stalled).flags.contains(.init(kind: .plateau, text: "No new best on Back Squat in 3 weeks")))
    }

    @Test func flagsTwoQuietWeeks() {
        #expect(week(units(plan("2026-10-14"), log("2026-09-20"))).flags.contains(.init(kind: .quiet, text: "Nothing logged in over two weeks")))
    }

    @Test func flagsACheckInNote() {
        let checkedIn = units(("log#2026-10-15", json([
            ["id": "A", "kind": "bodyweight", "measurements": [["metric": "weight_lb", "value": 183.5, "unit": "lb"]], "note": ""],
            ["id": "B", "kind": "sleep", "measurements": [["metric": "sleep_h", "value": 6, "unit": "h"]], "note": "Knee is a bit sore"],
        ])))
        #expect(week(checkedIn).flags == [.init(kind: .pain, text: "Thursday: “Knee is a bit sore”", day: "2026-10-15")])
    }

    @Test func painFirstThenMissedThenOnTrack() {
        let clients = [onTrack, missing, noted].enumerated().map { ($0.offset, week($0.element)) }
        #expect(Triage.byNeed(clients, \.1).map(\.0) == [2, 1, 0])
    }

    @Test func knowsTheWordsThatMeanSomethingHurts() {
        #expect(Triage.hurts("Lower back a bit sore"))
        #expect(!Triage.hurts("Felt great"))
    }

    // FIT-278: web/src/triage.test.ts's "a goal that lands short of its date".
    private func at(_ day: String) -> Double { (try! Date("\(day)T12:00:00Z", strategy: .iso8601)).timeIntervalSince1970 }
    private func client(_ load: Double, deadline: String? = "2026-12-01", metric: String = "back-squat.1rm_lb", start: String = "2026-09-01",
                        targetDate: String? = nil) -> [String: String] {
        var goal: [String: Any] = ["kind": "strength", "unit": "lb", "status": "active", "metric": metric, "target": 250, "baseline": 200]
        if let deadline { goal["deadline"] = at(deadline) }
        var profile: [String: Any] = ["programStart": at(start)]
        if let targetDate { profile["targetDate"] = at(targetDate) }
        let body = { (o: [String: Any]) in String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self) }
        return units(plan("2026-10-12"), log("2026-10-12", measurements: [["metric": "load_lb", "value": load, "unit": "lb"], ["metric": "reps", "value": 5, "unit": "reps"]]),
                     ("goal#g1", body(goal)), ("profile", body(profile)))
    }

    @Test func flagsAGoalThatLandsShortOfItsDate() {
        #expect(week(client(185)).flags == [Triage.Flag(kind: .behind, text: "Back Squat: 34 lb short of 250 by Dec 1")])
        #expect(Triage.Flag.Kind.allCases.firstIndex(of: .behind)! > Triage.Flag.Kind.allCases.firstIndex(of: .plateau)!)
        #expect(week(client(185, deadline: nil, targetDate: "2026-11-20")).flags.first?.text.hasSuffix(" by Nov 20") == true)
    }

    @Test func leavesGoalsOnCourseOrTooNewAlone() {
        #expect(week(client(225)).flags.isEmpty)
        #expect(week(client(185, start: "2026-10-10")).flags.isEmpty)
        #expect(week(client(185, deadline: nil)).flags.isEmpty)
        #expect(week(client(185, metric: "run_5000m.time_s")).flags.isEmpty)
    }

    // MARK: FIT-344, as infra/test/weeklyCheckIn.test.ts

    private func weekly(_ day: String, _ energy: Double, _ stress: Double, _ soreness: Double, _ adherence: Double, note: String = "") -> (String, String) {
        let ratings = [("energy_1to5", energy), ("stress_1to5", stress), ("soreness_1to5", soreness), ("adherence_1to5", adherence)]
        return ("log#\(day)", json([["id": "c-\(day)", "kind": "checkin", "at": 0, "measurements": ratings.map { ["metric": $0.0, "value": $0.1, "unit": "/5"] },
                                     "note": note]]))
    }

    @Test func lowRatingsInTheLastWeeksCheckInAreFlagged() {
        #expect(week(units(weekly("2026-10-11", 2, 4, 3, 5))).flags == [Triage.Flag(kind: .checkin, text: "Check-in: low energy, high stress")])
        #expect(week(units(weekly("2026-10-11", 4, 2, 2, 5))).flags.isEmpty)
        #expect(week(units(weekly("2026-10-08", 1, 5, 5, 1))).flags.isEmpty)
        #expect(WeeklyCheckIn.concerns(["energy_1to5": 2, "stress_1to5": 4, "soreness_1to5": 4, "adherence_1to5": 2])
                == ["low energy", "high stress", "very sore", "off the plan"])
    }

    @Test func aMissedCheckInIsFlaggedOnceTheCoachHasChosenADay() {
        let wednesday = ("checkin", #"{"day":2}"#)
        #expect(week(units(wednesday)).flags == [Triage.Flag(kind: .checkin, text: "Missed Wednesday’s check-in")])
        #expect(week(units(wednesday, weekly("2026-10-15", 4, 2, 2, 5))).flags.isEmpty)
        #expect(week(units(("checkin", #"{"day":4}"#), weekly("2026-10-09", 4, 2, 2, 5))).flags.isEmpty)
        #expect(week(units()).flags.isEmpty)
    }

    @Test func whatTheyWroteIsANotePainFirst() {
        let flags = week(units(weekly("2026-10-11", 4, 2, 2, 5, note: "What went well: every session\nWhat was hard: my knee hurts on stairs"))).flags
        #expect(flags == [Triage.Flag(kind: .pain, text: "Sunday: “What went well: every session What was hard: my knee hurts on stairs”", day: "2026-10-11")])
    }
}
