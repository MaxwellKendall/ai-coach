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
