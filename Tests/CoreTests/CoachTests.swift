import Foundation
import Testing
@testable import AICoach

struct CoachTests {
    private func set(_ reps: Double, _ load: Double? = nil, key: String = "load_lb") -> SessionPlan.PlannedSet {
        SessionPlan.PlannedSet(targets: [Measurement(metric: "reps", value: reps, unit: "reps")]
                               + (load.map { [Measurement(metric: key, value: $0, unit: "lb")] } ?? []))
    }

    @Test func doseReadsLikeThePrototype() {
        let bench = SessionPlan.Block(movements: [.init(exercise: "bench", sets: Array(repeating: set(5, 140), count: 3))])
        let pair = SessionPlan.Block(movements: [.init(exercise: "row", sets: Array(repeating: set(10, 50, key: "load_lb_hand"), count: 3)),
                                                 .init(exercise: "db-bench", sets: Array(repeating: set(10, 50, key: "load_lb_hand"), count: 3))])
        let core = SessionPlan.Block(movements: [.init(exercise: "dead-bug", sets: [set(10), set(10)])])
        #expect(bench.dose == "3 × 5 · 140")
        #expect(pair.dose == "3 × 10+10 · 50")
        #expect(core.dose == "2 × 10")
    }

    @Test func planLineExplainsTheDay() {
        #expect(Coach.plan(deload: true, reasons: []).hasPrefix("Light week"))
        #expect(Coach.plan(deload: true, reasons: ["30 min available"]).hasPrefix("Short on time"))
        #expect(Coach.plan(deload: false, reasons: ["shoulder injury: bench → push-up"]) == "Working around the shoulder.")
    }

    @Test func restLineNamesTheNextSession() {
        let calendar = Calendar(identifier: .gregorian)
        let thu = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1))!
        let fri = calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 7))!
        let mon = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 7))!
        #expect(Coach.rest(next: ("Session B", fri), from: thu, calendar: calendar) == "Session B is tomorrow.")
        #expect(Coach.rest(next: ("Session A", mon), from: thu, calendar: calendar) == "Session A is on Monday.")
        #expect(Coach.rest(next: nil, from: thu, calendar: calendar).hasPrefix("Nothing planned"))
    }

    @Test func doneLineFollowsTheProgressionRule() {
        let short = Coach.Lift(name: "Bench press", load: 140, next: 140, short: [(3, 4, 5)])
        #expect(Coach.done([short]) == "Bench press came up one rep short on set 3, so it stays at 140 next time.")
        let up = Coach.Lift(name: "Squat", load: 185, next: 190)
        #expect(Coach.done([up]) == "Squat moved well, so it goes up 5 lb next time.")
        #expect(Coach.done([up], missedSets: 2).hasPrefix("2 sets not done"))
        #expect(Coach.done([Coach.Lift(name: "Squat", load: 185, next: 185)]).hasPrefix("Every set hit"))
    }

    @Test func feelRoundTripsThroughEffort() {
        for feel in Feel.allCases { #expect(Feel(effort: feel.effort) == feel) }
        #expect(Feel(effort: 7.5) == .good)
        #expect(Feel(effort: nil) == nil)
    }
}
