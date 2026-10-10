import Foundation
import Testing
@testable import AICoach

/// FIT-92: the program scores, on weeks built by hand.
struct ProgramScoreTests {
    private static let monday = Date(timeIntervalSince1970: 1_784_000_000)

    private static func row(_ day: Int, _ session: String, _ exercise: String, sets: Double = 3, reps: Double? = 5,
                            pounds: Double? = nil, seconds: Double? = nil, main: Bool = false) -> PlannedWorkout {
        var targets = [Measurement(metric: "sets", value: sets, unit: "sets")]
        if let reps { targets.append(Measurement(metric: "reps", value: reps, unit: "reps")) }
        if let pounds { targets.append(Measurement(metric: "load_lb", value: pounds, unit: "lb")) }
        if let seconds { targets.append(Measurement(metric: "duration_s", value: seconds, unit: "s")) }
        return PlannedWorkout(date: monday.addingTimeInterval(Double(day) * 86_400), session: session, exercise: exercise,
                              targets: targets, main: main)
    }

    private static func week(_ rows: [PlannedWorkout]) -> TrainingWeek { TrainingWeek(workouts: rows, deload: false, warnings: []) }

    /// One hard week with bench as the main lift at `pounds` × 5.
    private static func bench(_ pounds: Double, sets: Double = 4) -> TrainingWeek {
        week([row(0, "Upper", "bench-press", sets: sets, pounds: pounds, main: true), row(0, "Upper", "pull-up")])
    }

    @Test func aSessionUnderAnotherNameWithTheSameExercisesIsACopy() {
        let copied = Self.week([Self.row(0, "Upper A", "bench-press"), Self.row(0, "Upper A", "pull-up"),
                                Self.row(2, "Lower A", "back-squat"),
                                Self.row(4, "Upper B", "pull-up"), Self.row(4, "Upper B", "bench-press")])
        #expect(ProgramScore.copiedSessions(copied) == ["Upper A = Upper B"])
        // A, B, A over three days is the split.
        let split = Self.week([Self.row(0, "A", "bench-press"), Self.row(2, "B", "back-squat"), Self.row(4, "A", "bench-press")])
        #expect(ProgramScore.copiedSessions(split).isEmpty)
    }

    @Test func oddItemsAreEmptyHoldsAndWeightedLiftsWithNoLoad() throws {
        let inputs = try ProgramDesignerEvals.inputs()
        let catalog = Dictionary(inputs.catalog.map { ($0.slug, $0) }, uniquingKeysWith: { a, _ in a })
        let week = Self.week([Self.row(0, "A", "plank-forearm", reps: nil, seconds: 0), Self.row(0, "A", "bench-press"),
                              Self.row(0, "A", "push-up"), Self.row(0, "A", "back-squat", pounds: 185)])
        let odd = ProgramScore.oddItems(week, catalog: catalog, names: [:])
        #expect(odd == ["plank-forearm 0 s", "bench-press with no load"])
    }

    @Test func progressionCountsRisesHoldsDropsAndJumpsOverLightWeeks() {
        // 185, 190, light, 190, 175, 215: up, held (across the light week), down, a jump of over 10%.
        let weeks = [Self.bench(185), Self.bench(190), Self.bench(120, sets: 2), Self.bench(190), Self.bench(175), Self.bench(215)]
        let progression = ProgramScore.progression(weeks, light: [false, false, true, false, false, false], names: ["bench-press": "Bench Press"])
        #expect(progression.up == 2)
        #expect(progression.held == 1)
        #expect(progression.down == 1)
        #expect(progression.jumps == ["Bench Press weeks 5→6 +23%"])
    }

    @Test func trackIsTheBestEstimateOfTheLastThreeHardWeeksAgainstTheTarget() {
        let weeks = [Self.bench(185), Self.bench(190), Self.bench(195), Self.bench(200), Self.bench(150, sets: 2)]
        let track = ProgramScore.track(weeks, light: [false, false, false, false, true], target: .init(exercise: "bench-press", pounds: 225))
        #expect(track.start == ProgramPlan.estimatedMax(load: 185, reps: 5))
        #expect(track.end == ProgramPlan.estimatedMax(load: 200, reps: 5))
        // 200 × 5 is an estimated 225: on target.
        #expect(abs(track.share! - 1) < 0.001)
    }

    @Test func aDeloadCountsWhenItHasFewerSetsThanTheHardWeeksAroundIt() {
        let weeks = [Self.bench(185, sets: 4), Self.bench(150, sets: 2), Self.bench(190, sets: 4), Self.bench(150, sets: 5), Self.bench(190, sets: 4)]
        let deloads = ProgramScore.deloads(weeks, light: [false, true, false, true, false])
        #expect(deloads.lighter == 1)
        #expect(deloads.of == 2)
    }

    @Test func phaseChangeIsTheShareOfExercisesThatDiffer() {
        let base = Self.week([Self.row(0, "A", "bench-press"), Self.row(0, "A", "pull-up")])
        let build = Self.week([Self.row(0, "A", "bench-press"), Self.row(0, "A", "dumbbell-row")])
        let changes = ProgramScore.phaseChanges([base, build, build], phases: [.base, .build, .peak], light: [false, false, false])
        #expect(changes.map(\.0) == ["base→build", "build→peak"])
        #expect(abs(changes[0].1 - 2.0 / 3) < 0.001)
        #expect(changes[1].1 == 0)
    }
}

/// FIT-97: the probe logs like a person, the same way every run.
struct ProbeLogTests {
    private static let monday = Date(timeIntervalSince1970: 1_784_000_000)

    private func week() -> TrainingWeek {
        let rows = [0, 2, 4].flatMap { day in
            [PlannedWorkout(date: Self.monday.addingTimeInterval(Double(day) * 86_400), session: "S\(day)", exercise: "bench-press",
                            targets: [.init(metric: "sets", value: 3, unit: "sets"), .init(metric: "reps", value: 5, unit: "reps"),
                                      .init(metric: "load_lb", value: 185, unit: "lb"), .init(metric: "rpe", value: 8, unit: "RPE")], main: true),
             PlannedWorkout(date: Self.monday.addingTimeInterval(Double(day) * 86_400), session: "S\(day)", exercise: "pull-up",
                            targets: [.init(metric: "sets", value: 2, unit: "sets"), .init(metric: "reps", value: 8, unit: "reps")])]
        }
        return TrainingWeek(workouts: rows, deload: false, warnings: [])
    }

    @Test func aboutOneSessionInFourIsSkipped() {
        let sessions = (0..<12).flatMap { index in (0..<3).map { ProbeLog.skips(week: index, session: $0) } }
        #expect(sessions.filter { $0 }.count == 9)
        // Week 2's second session: 2 + 1 = 3.
        let logged = ProbeLog.log(week(), index: 2, patterns: [:])
        #expect(Set(logged.map(\.date)).count == 2)
    }

    @Test func everyThirdWeekTheMainLiftsLastSetIsARepShortAtRPE9AndAHalf() {
        let easy = ProbeLog.log(week(), index: 0, patterns: [:])
        #expect(easy.filter { $0.exercise == "bench-press" }.allSatisfy { $0.value("reps") == 5 && $0.value("rpe") == 8 })
        let hard = ProbeLog.log(week(), index: 8, patterns: [:]).filter { $0.exercise == "bench-press" }
        #expect(hard.filter { $0.value("reps") == 4 && $0.value("rpe") == 9.5 }.count == 3)
        #expect(hard.filter { $0.value("reps") == 5 }.count == 6)
        // Accessories as planned.
        #expect(ProbeLog.log(week(), index: 8, patterns: [:]).filter { $0.exercise == "pull-up" }.allSatisfy { $0.value("reps") == 8 })
    }
}

/// FIT-98: the pass bar and the brief checks.
struct PassBarTests {
    private func run(byModel: Int = 31, repairs: Double = 2, copies: Int = 0, odd: Int = 0, down: Int = 1,
                     shares: [Double] = [0.95], deloads: (Int, Int) = (2, 2)) -> ProgramScore.Run {
        ProgramScore.Run(weeks: 31, byModel: byModel, repairsPerWeek: repairs, copies: copies, odd: odd,
                         progression: .init(up: 8, held: 1, down: down), goalShares: shares, deloads: (deloads.0, deloads.1))
    }

    @Test func aRunThatMeetsEveryLinePasses() {
        #expect(ProgramScore.weekFailures(run()).isEmpty)
    }

    @Test func eachLineMissedIsNamed() {
        let failures = ProgramScore.weekFailures(run(byModel: 28, repairs: 6.4, copies: 2, odd: 20, down: 5, shares: [0.65, 0.95], deloads: (1, 2)))
        #expect(failures == ["model designed 90% of weeks", "2 copied sessions", "6.5 odd items per 10 weeks",
                             "5 of 14 main-lift changes were drops", "1 deloads not lighter", "6.4 repairs a week",
                             "a goal planned to end at 65%"])
    }

    @Test func aBriefMustPlanEachPhaseWithTheGoalLiftsAndEquipmentTheyHave() throws {
        let inputs = try ProgramDesignerEvals.inputs()
        let catalog = Dictionary(inputs.catalog.map { ($0.slug, $0) }, uniquingKeysWith: { a, _ in a })
        let weeks = ProgramPlan.weeks(count: 12, deloadEvery: 6)
        func phase(_ name: String, _ lifts: [String], reps: Int) -> ProgramBrief.Phase {
            .init(phase: name, focus: name, mainLifts: lifts, mainReps: reps, accessoryReps: 10)
        }
        let good = ProgramBrief(phases: [phase("base", ["Bench Press", "Back Squat"], reps: 8), phase("build", ["Bench Press"], reps: 5),
                                         phase("peak", ["Bench Press"], reps: 3)])
        let equipment: Set<String> = ["barbell", "rack", "bench"]
        #expect(ProgramScore.briefProblems(good, weeks: weeks, goalLifts: ["bench-press"], catalog: catalog, names: inputs.names, equipment: equipment).isEmpty)
        let bad = ProgramBrief(phases: [phase("base", ["Back Squat"], reps: 3), phase("peak", ["Bench Press", "Dumbbell Bench Press"], reps: 5)])
        #expect(ProgramScore.briefProblems(bad, weeks: weeks, goalLifts: ["bench-press"], catalog: catalog, names: inputs.names, equipment: equipment)
                == ["Bench Press not a main lift in base", "no build phase", "Dumbbell Bench Press needs equipment they don't have",
                    "peak reps (5) above base reps (3)"])
        #expect(ProgramScore.briefProblems(nil, weeks: weeks, goalLifts: [], catalog: catalog, names: inputs.names, equipment: equipment) == ["no brief"])
    }
}
