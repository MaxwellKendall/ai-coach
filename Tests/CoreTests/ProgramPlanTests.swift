import Foundation
import Testing
@testable import AICoach

private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}

private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
}

struct ProgramPlanTests {
    /// The prototype's program: Monday Sep 14 2026 to Sunday Jan 3 2027 is 16 weeks; "the end of February" is 25.
    @Test func weekCountFromTargetDate() {
        #expect(ProgramPlan.weekCount(start: date(2026, 9, 14), target: date(2027, 1, 3), calendar: calendar) == 16)
        #expect(ProgramPlan.weekCount(start: date(2026, 9, 16), target: date(2027, 1, 3), calendar: calendar) == 16)
        #expect(ProgramPlan.weekCount(start: date(2026, 9, 14), target: date(2027, 3, 1), calendar: calendar) == 25)
        #expect(ProgramPlan.weekCount(start: date(2026, 9, 14), target: date(2026, 9, 1), calendar: calendar) == 1)
        #expect(ProgramPlan.week(of: date(2026, 9, 13), start: date(2026, 9, 14), calendar: calendar) == -1)
    }

    @Test func phasesDeloadsAndTest() {
        let weeks = ProgramPlan.weeks(count: 16, deloadEvery: 6)
        // round(16 × 0.35) = 6 base weeks, round(16 × 0.75) = 12.
        #expect(weeks.map(\.phase) == Array(repeating: .base, count: 6) + Array(repeating: .build, count: 6)
            + Array(repeating: .peak, count: 4))
        #expect(weeks.indices.filter { weeks[$0].kind == .deload } == [5, 11])
        #expect(weeks.last?.kind == .test)
        #expect(weeks.filter(\.light).count == 3)
    }

    /// Travel weeks 9–10 (indices 8, 9): the deload moves into the trip and the next one is 6 weeks after it.
    @Test func tripTakesTheDeload() {
        let weeks = ProgramPlan.weeks(count: 24, deloadEvery: 6, travel: [8, 9])
        #expect(weeks.indices.filter { weeks[$0].kind == .deload } == [5, 9, 15, 21])
        #expect(weeks[8].travel && weeks[9].travel && !weeks[10].travel)
        // Too soon after a deload: the trip keeps its phase.
        let early = ProgramPlan.weeks(count: 24, deloadEvery: 6, travel: [6])
        #expect(early.indices.filter { early[$0].kind == .deload } == [5, 11, 17])
    }

    @Test func goalProjectionIsFlatThroughLightWeeks() {
        let weeks = ProgramPlan.weeks(count: 16, deloadEvery: 6)
        // 14 counting weeks (16 minus deloads 5 and 11); the test week counts.
        #expect(ProgramPlan.expected(from: 200, target: 180, at: 15, weeks: weeks) == 180)
        #expect(ProgramPlan.expected(from: 5, target: 12, at: 4, weeks: weeks) == 7.5)
        #expect(ProgramPlan.expected(from: 5, target: 12, at: 5, weeks: weeks) == 7.5)
        #expect(ProgramPlan.expected(from: 5, target: 12, at: -1, weeks: weeks) == 5)
    }

    @Test func phaseSetsWithinTheVolumeTable() {
        #expect(ProgramPlan.sessionSets(14...18, phase: .base) == 14...14)
        #expect(ProgramPlan.sessionSets(14...18, phase: .build) == 18...18)
        #expect(ProgramPlan.sessionSets(14...18, phase: .peak) == 16...16)
        let deload = ProgramWeek(phase: .build, kind: .deload)
        #expect(ProgramPlan.weeklySets(ProgramWeek(phase: .build, kind: .build), daysPerWeek: 3, sessionMinutes: 45) == 54)
        #expect(ProgramPlan.weeklySets(deload, daysPerWeek: 3, sessionMinutes: 45) == 30)
    }

    @Test func firstSetsFromAStartingPoint() {
        func start(_ values: [(String, Double)]) -> StartingSet {
            StartingSet(exercise: "x", measurements: values.map { Measurement(metric: $0.0, value: $0.1, unit: "") })
        }
        // 150 × 5 → Brzycki 168.75; 5 reps → 150 × 0.9 = 135; 10 reps → 126.6 × 0.9 → 115.
        #expect(ProgramPlan.firstTargets(start([("load_lb", 150), ("reps", 5)]), reps: 5).load == 135)
        #expect(ProgramPlan.firstTargets(start([("load_lb", 150), ("reps", 5)]), reps: 10).load == 115)
        #expect(ProgramPlan.firstTargets(start([("reps", 20)]), reps: 5).reps == 14)
        #expect(ProgramPlan.firstTargets(start([("reps", 2)]), reps: 5).reps == 3)
        #expect(ProgramPlan.firstTargets(start([("duration_s", 60)]), reps: 5).seconds == 45)
        #expect(ProgramPlan.estimatedMax(load: 205, reps: 5).rounded() == 231)
    }

    @Test func generatorFollowsTheProgramWeek() {
        let settings = TrainingSettings(
            age: 36, daysPerWeek: 3, sessionMinutes: 45, trainingDays: [0, 2, 4], workoutTime: 7 * 60,
            equipment: ["barbell", "rack", "dumbbells", "pull_up_bar", "bench"], maxWeeklySets: 80,
            starts: [StartingSet(exercise: "back-squat", measurements: [
                Measurement(metric: "load_lb", value: 150, unit: "lb"), Measurement(metric: "reps", value: 5, unit: "reps")])])
        func exercise(_ slug: String, _ pattern: String, _ equipment: [String], goal: Bool = false) -> Exercise {
            Exercise(slug: slug, attributes: [
                TemplateAttribute(key: "movement_pattern", values: [pattern]),
                TemplateAttribute(key: "equipment", values: equipment),
                TemplateAttribute(key: "tags", values: goal ? ["goal_lift"] : []),
            ])!
        }
        let catalog = [exercise("back-squat", "squat", ["barbell", "rack"], goal: true),
                       exercise("goblet-squat", "squat", ["dumbbells"]), exercise("pull-up", "pull", ["pull_up_bar"], goal: true),
                       exercise("dumbbell-row", "pull", ["dumbbells"]), exercise("plank", "core", []),
                       exercise("farmer-carry", "carry", ["dumbbells"]), exercise("deadlift", "hinge", ["barbell"], goal: true),
                       exercise("push-up", "push", []), exercise("dumbbell-bench-press", "push", ["dumbbells"])]
        func week(_ program: ProgramWeek) -> TrainingWeek {
            TrainingGenerator.week(startingOn: date(2026, 9, 14), settings: settings, catalog: catalog, history: [],
                                   weeksSinceDeload: 0, program: program, calendar: calendar)
        }
        let base = week(ProgramWeek(phase: .base, kind: .base))
        let build = week(ProgramWeek(phase: .build, kind: .build))
        #expect(base.totalSets < build.totalSets)
        #expect(!base.deload)
        // No history: the squat starts from what was said, a little under it.
        let squat = base.workouts.first { $0.exercise == "back-squat" && $0.note != TrainingGenerator.warmupNote }
        #expect(squat?.target("load_lb") == 135)

        let deload = week(ProgramWeek(phase: .build, kind: .deload))
        #expect(deload.deload)
        #expect(deload.workouts.first { $0.exercise == "back-squat" && $0.note != TrainingGenerator.warmupNote }?.target("load_lb") == 115)

        let travel = week(ProgramWeek(phase: .build, kind: .build, travel: true))
        #expect(!travel.workouts.contains { ["back-squat", "deadlift", "pull-up"].contains($0.exercise) })
        #expect(travel.warnings.contains { $0.hasPrefix("Travel week") })
        #expect(week(ProgramWeek(phase: .peak, kind: .test)).warnings.first?.hasPrefix("Test week") == true)
    }
}
