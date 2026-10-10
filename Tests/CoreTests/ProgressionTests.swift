import Foundation
import Testing
@testable import AICoach

/// FIT-100: each main lift's next step: the evidence a decider reads, the rule table, and the top set a step makes.
@MainActor
struct ProgressionTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }
    private var monday: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 12))! }
    private let settings = TrainingSettings(age: 36, daysPerWeek: 3, sessionMinutes: 45, trainingDays: [0, 2, 4], workoutTime: 420,
                                            equipment: ["barbell", "rack", "dumbbells", "bench"], maxWeeklySets: 60)
    private let names = ["bench-press": "Bench Press", "back-squat": "Back Squat", "dumbbell-row": "Dumbbell Row"]
    private let rules = Progression.Rules(tier: .of(age: 36))

    private func day(_ daysBefore: Int) -> Date { calendar.date(byAdding: .day, value: -daysBefore, to: monday)! }

    private func sets(_ daysBefore: Int, _ exercise: String = "bench-press", load: Double = 185, reps: [Double], rpe: Double? = 8,
                      perHand: Bool = false) -> [LoggedSet] {
        reps.enumerated().map { index, reps in
            LoggedSet(date: day(daysBefore), exercise: exercise, pattern: nil,
                      measurements: [.init(metric: perHand ? "load_lb_hand" : "load_lb", value: load, unit: "lb"), .init(metric: "reps", value: reps, unit: "reps")]
                        + (index == 0 ? [] : (rpe.map { [Measurement(metric: "rpe", value: $0, unit: "RPE")] } ?? [])))
        }
    }

    private func lift(_ sessions: [[LoggedSet]], planned: Double? = 185, reps: Double? = 5, daysOff: Int? = 6) -> Progression.Lift {
        Progression.Lift(exercise: "bench-press", name: "Bench Press", plannedLoad: planned, plannedReps: reps, sessions: sessions,
                         daysOff: daysOff, now: nil, aim: nil)
    }

    @Test func theRulesAddHoldAndBackOff() {
        // All reps at RPE 8, the age-36 tier's cap for main lifts: add.
        #expect(rules.step(lift([sets(6, reps: [5, 5, 5], rpe: 8)])) == .add)
        // RPE 9, over the cap: hold.
        #expect(rules.step(lift([sets(6, reps: [5, 5, 5], rpe: 9)])) == .hold)
        // A rep short once: hold; twice running: back off.
        #expect(rules.step(lift([sets(6, reps: [5, 5, 4]), sets(13, reps: [5, 5, 5])])) == .hold)
        #expect(rules.step(lift([sets(6, reps: [5, 5, 4]), sets(13, reps: [5, 4, 4])])) == .backOff)
        // Time off: more than 2 weeks holds, more than 4 backs off.
        #expect(rules.step(lift([sets(20, reps: [5, 5, 5])], daysOff: 20)) == .hold)
        #expect(rules.step(lift([sets(35, reps: [5, 5, 5])], daysOff: 35)) == .backOff)
        // Nothing to go on: hold.
        #expect(rules.step(lift([])) == .hold)
        // All reps at the cap and behind the goal's line: add more.
        var behind = lift([sets(6, reps: [5, 5, 5], rpe: 8)])
        behind.now = 200
        behind.aim = 215
        #expect(rules.step(behind) == .addMore)
        behind.now = 212
        #expect(rules.step(behind) == .add)
    }

    @Test func aStepBecomesTheTopSet() {
        let bench = lift([sets(6, reps: [5, 5, 5])])
        #expect(Progression.decision(bench, step: .add)?.load == 190)
        #expect(Progression.decision(bench, step: .hold)?.load == 185)
        #expect(Progression.decision(bench, step: .backOff)?.load == 165)
        #expect(Progression.decision(bench, step: .addMore)?.load == 195)
        #expect(Progression.decision(bench, step: .add)?.reps == 5)
        #expect(Progression.decision(bench, step: .add)?.estimatedMax == ProgramPlan.estimatedMax(load: 190, reps: 5))
        // A phase on triples: the same estimated max at 3 reps, so heavier, not lighter.
        var triples = bench
        triples.reps = 3
        let held = Progression.decision(triples, step: .hold)
        #expect(held?.reps == 3)
        #expect(held?.load == 195)
        // Dumbbells go up 2.5 a hand.
        let row = Progression.Lift(exercise: "dumbbell-row", name: "Dumbbell Row", plannedLoad: nil, plannedReps: nil,
                                   sessions: [sets(6, "dumbbell-row", load: 50, reps: [10, 10], perHand: true)], daysOff: 6, now: nil, aim: nil)
        let decision = Progression.decision(row, step: .add)
        #expect(decision?.load == 52.5)
        #expect(decision.map { Progression.line($0, names: names) } == "Dumbbell Row: add → top set 52.5 each × 10.")
    }

    @Test func theEvidenceIsLastWeekPlannedAgainstDoneAndTheGoal() {
        let planned = [PlannedWorkout(date: day(6), session: "Upper", exercise: "bench-press",
                                      targets: [.init(metric: "sets", value: 3, unit: "sets"), .init(metric: "reps", value: 5, unit: "reps"),
                                                .init(metric: "load_lb", value: 185, unit: "lb")], main: true)]
        let weeks = ProgramPlan.weeks(count: 12, deloadEvery: 6)
        let request = ProgramDesigner.Request(
            monday: monday, settings: settings, catalog: [], names: names,
            history: sets(13, load: 180, reps: [5, 5, 5]) + sets(6, reps: [5, 5, 4], rpe: 9.5), weeksSinceDeload: 1,
            program: weeks[4], programIndex: 4, programWeeks: 12, lastWeek: planned,
            goalLifts: [GoalLift(exercise: "bench-press", measure: "1rm_lb", start: 190, target: 225, deadline: nil)],
            programPlan: weeks, calendar: calendar)
        let lifts = Progression.lifts(request)
        #expect(lifts.map(\.exercise) == ["bench-press"])
        #expect(lifts[0].sessions.count == 2)
        #expect(lifts[0].daysOff == 6)
        let aim = ProgramPlan.expected(from: 190, target: 225, at: 4, weeks: weeks).rounded()
        #expect(Progression.evidence(lifts[0]) == "Bench Press: last time, 6 days ago, planned 185 × 5; did 185 × 5, 185 × 5, 185 × 4 at RPE 9.5. "
                + "The time before: 180 × 5, 180 × 5, 180 × 5 at RPE 8. Goal: estimated max about 208 now, \(Coach.number(aim)) by the end of this week.")
        #expect(rules.step(lifts[0]) == .hold)
    }

    @Test func afterADeloadTheBaseIsTheHardWeekBeforeIt() {
        // Week 7 follows week 6's deload: bench went 185 × 5 in week 5 and 120 × 5 in the deload.
        let weeks = ProgramPlan.weeks(count: 12, deloadEvery: 6)
        let index = weeks.firstIndex { $0.kind == .deload }! + 1
        let deload = [PlannedWorkout(date: day(6), session: "Upper", exercise: "bench-press",
                                     targets: [.init(metric: "sets", value: 2, unit: "sets"), .init(metric: "reps", value: 5, unit: "reps"),
                                               .init(metric: "load_lb", value: 120, unit: "lb")], main: true)]
        let request = ProgramDesigner.Request(
            monday: monday, settings: settings, catalog: [], names: names,
            history: sets(13, reps: [5, 5, 5]) + sets(6, load: 120, reps: [5, 5]), weeksSinceDeload: 0,
            program: weeks[index], programIndex: index, programWeeks: 12, lastWeek: deload, programPlan: weeks, calendar: calendar)
        let lifts = Progression.lifts(request)
        #expect(lifts.first?.plannedLoad == nil)
        #expect(lifts.first?.sessions.first?.first?.value("load_lb") == 185)
        #expect(lifts.first?.daysOff == 6)
        #expect(lifts.first.flatMap { Progression.decision($0, step: .add) }?.load == 190)
    }

    @Test func theWeekIsToldTheDecidedTopSetsAndTheGoalKeepsItsAim() {
        let weeks = ProgramPlan.weeks(count: 12, deloadEvery: 6)
        var request = ProgramDesigner.Request(
            monday: monday, settings: settings, catalog: [], names: names, history: [], weeksSinceDeload: 1,
            program: weeks[4], programIndex: 4, programWeeks: 12,
            goalLifts: [GoalLift(exercise: "bench-press", measure: "1rm_lb", start: 190, target: 225, deadline: nil)],
            programPlan: weeks, calendar: calendar)
        request.progression = [Progression.Decision(exercise: "bench-press", step: .add, load: 190, reps: 5, estimatedMax: 214,
                                                    perHand: false, confidence: 0.9)]
        let prompt = ProgramDesigner.prompt(request, settings: settings, light: false)
        #expect(prompt.contains("Main lifts' top sets this week, decided from how they went; keep to them:\nBench Press: add → top set 190 × 5."))
        #expect(prompt.contains("Bench Press is a goal (225 lb): aim for an estimated max of about"))
        #expect(!prompt.contains("a top set near"))
    }
}
