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

    // FIT-183: a planned run reads as one, holds stay in seconds.
    @Test func runsAndHoldsReadInMinutesAndKilometres() {
        func timed(_ metrics: [String: Double]) -> SessionPlan.PlannedSet {
            SessionPlan.PlannedSet(targets: metrics.sorted { $0.key < $1.key }.map { Measurement(metric: $0.key, value: $0.value, unit: "") })
        }
        let run = SessionPlan.Block(movements: [.init(exercise: "trail-running-walking", sets: [timed(["duration_s": 1500])])])
        let long = SessionPlan.Block(movements: [.init(exercise: "trail-running-walking", sets: [timed(["distance_m": 8000, "duration_s": 2700])])])
        let plank = SessionPlan.Block(movements: [.init(exercise: "plank", sets: Array(repeating: timed(["duration_s": 45]), count: 3))])
        let carry = SessionPlan.Block(movements: [.init(exercise: "carry", sets: Array(repeating: timed(["distance_m": 40]), count: 2))])
        #expect(run.dose == "25 min")
        #expect(long.dose == "5 mi · 45 min")
        #expect(plank.dose == "3 × 45 s")
        #expect(carry.dose == "2 × 40 m")
        #expect(Coach.distance(5250) == "3.3 mi")
        #expect(Coach.distance(400) == "400 m")
        #expect(Coach.run(kind: "easy") == "Easy enough to talk the whole way.")
        #expect(Coach.run(kind: "tempo: 3 × 8 min") == "Comfortably hard: a pace you could hold for about an hour.")
        #expect(Coach.run(kind: "") == "Easy enough to talk the whole way.")
    }

    @Test func planLineExplainsTheDay() {
        #expect(Coach.plan(deload: true, reasons: []).hasPrefix("Light week"))
        #expect(Coach.plan(deload: true, reasons: ["30 min available"]).hasPrefix("Short on time"))
        #expect(Coach.plan(deload: false, reasons: ["shoulder injury: bench → push-up"]) == "Working around the shoulder.")
    }

    /// FIT-202: a coach's session shows what the coach wrote, not the app's tip.
    @Test func aCoachsSessionSpeaksForTheCoach() {
        #expect(Coach.coached(reasons: ["First week."], coach: "Sam") == "First week.")
        #expect(Coach.coached(reasons: ["edited", "From Sam"], coach: "Sam") == "From Sam")
        #expect(Coach.coached(reasons: [], coach: "Sam") == "From Sam")
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
