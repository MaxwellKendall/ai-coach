import Foundation
import Testing
@testable import AICoach

/// FIT-71: each rule broken, then repaired. The seed catalog, so names and equipment are the real ones.
@MainActor
struct PlanGuardTests {
    private static let seeds = try! Seeder.decode([TemplateSeed].self, "exercises", .main)
    private let catalog = seeds.compactMap { Exercise(slug: $0.slug, attributes: $0.attributes) }
    private let names = Dictionary(uniqueKeysWithValues: seeds.map { ($0.slug, $0.name) })
    private let monday = Date(timeIntervalSinceReferenceDate: 812_000_000)
    private var tuesday: Date { monday + 86_400 }

    private func settings(age: Int = 36, equipment: Set<String> = ["barbell", "rack", "dumbbells", "bench", "pull_up_bar"],
                          injured: [String] = [], avoid: Set<String> = [], maxWeeklySets: Int = 60,
                          starts: [StartingSet] = []) -> TrainingSettings {
        TrainingSettings(age: age, daysPerWeek: 3, sessionMinutes: 60, trainingDays: [0, 2, 4], workoutTime: 420,
                         equipment: equipment, injuredAreas: BodyArea.muscles(for: injured), avoidExercises: avoid,
                         maxWeeklySets: maxWeeklySets, starts: starts)
    }

    private func row(_ exercise: String, _ sets: Double, _ reps: Double? = 8, load: Double? = nil, rpe: Double? = nil,
                     main: Bool = false, on date: Date? = nil, session: String = "Full body") -> PlannedWorkout {
        var targets = [Measurement(metric: "sets", value: sets, unit: "sets")]
        if let reps { targets.append(Measurement(metric: "reps", value: reps, unit: "reps")) }
        if let load { targets.append(Measurement(metric: "load_lb", value: load, unit: "lb")) }
        if let rpe { targets.append(Measurement(metric: "rpe", value: rpe, unit: "RPE")) }
        return PlannedWorkout(date: date ?? monday, session: session, exercise: exercise, targets: targets, main: main)
    }

    private func check(_ rows: [PlannedWorkout], _ settings: TrainingSettings, history: [LoggedSet] = [],
                       light: Bool = false) -> (workouts: [PlannedWorkout], repairs: [PlanGuard.Repair]) {
        PlanGuard.check(rows, PlanGuard.Context(settings: settings, catalog: catalog, names: names, history: history,
                                                light: light))
    }

    private func logged(_ exercise: String, _ load: Double, _ reps: Double, rpe: Double? = nil) -> LoggedSet {
        var measurements = [Measurement(metric: "load_lb", value: load, unit: "lb"), Measurement(metric: "reps", value: reps, unit: "reps")]
        if let rpe { measurements.append(Measurement(metric: "rpe", value: rpe, unit: "RPE")) }
        return LoggedSet(date: monday - 7 * 86_400, exercise: exercise, pattern: nil, measurements: measurements)
    }

    // MARK: Rule 1: allowed exercises

    @Test func anExerciseNeedingEquipmentYouLackIsSwappedForTheSameMovement() throws {
        let result = check([row("seated-cable-rows", 3)], settings(equipment: ["dumbbells", "bench"]))
        let swap = try #require(catalog.first { $0.slug == result.workouts.first?.exercise })
        #expect(swap.pattern == "pull" && swap.tags.contains("horizontal_pull"))
        #expect(swap.equipment.isSubset(of: ["dumbbells", "bench"]))
        #expect(result.repairs.map(\.rule) == [.exercise])
        #expect(result.workouts.first?.target("sets") == 3)
    }

    @Test func injuredAreasAndAvoidsAreSwapped() {
        let avoided = check([row("bench-press", 3, main: true)], settings(avoid: ["bench-press"]))
        #expect(avoided.workouts.map(\.exercise) != ["bench-press"])
        #expect(avoided.workouts.first?.main == true)
        let knees = check([row("back-squat", 3)], settings(injured: ["knees"]))
        #expect(knees.workouts.allSatisfy { slug in !(catalog.first { $0.slug == slug.exercise }?.muscles.contains("quads") ?? true) })
        #expect(knees.repairs.allSatisfy { $0.rule == .exercise })
    }

    /// The model may name an exercise: a catalog name resolves quietly; one that isn't found is searched for.
    @Test func namesResolveOrAreSearchedFor() {
        let named = check([row("bench press", 3)], settings())
        #expect(named.workouts.map(\.exercise) == ["bench-press"])
        #expect(named.repairs.isEmpty)
        let made_up = check([row("Hamstring Curl Deluxe", 3)], settings(equipment: Set(Profile.allEquipment)))
        #expect(made_up.workouts.count == 1)
        #expect(made_up.repairs.map(\.rule) == [.exercise])
        let nothing = check([row("Zorbing", 3)], settings())
        #expect(nothing.workouts.isEmpty)
    }

    // MARK: Rule 2: sets

    @Test func setsPerExerciseAreCappedAndSingleSetsRaised() {
        let result = check([row("bench-press", 12, main: true), row("dumbbell-row", 6), row("plank", 1, nil)], settings())
        #expect(result.workouts.map { $0.target("sets") } == [5, 4, 2])
        #expect(result.repairs.map(\.rule) == [.sets, .sets, .sets])
        // A light week may have single sets.
        #expect(check([row("plank", 1, nil)], settings(), light: true).repairs.isEmpty)
    }

    @Test func weeklySetsStayUnderTheCeiling() {
        let rows = (0..<3).flatMap { day in
            [row("bench-press", 5, main: true, on: monday + Double(day) * 2 * 86_400),
             row("dumbbell-row", 4, on: monday + Double(day) * 2 * 86_400),
             row("goblet-squat", 4, on: monday + Double(day) * 2 * 86_400)]
        }
        let result = check(rows, settings(maxWeeklySets: 30))
        #expect(result.workouts.reduce(0) { $0 + ($1.target("sets") ?? 0) } == 30)
        #expect(result.repairs.map(\.rule) == [.weeklySets])
        // Accessories give sets first.
        #expect(result.workouts.filter(\.main).allSatisfy { $0.target("sets") == 5 })
    }

    // MARK: Rule 3: loads

    @Test func aLoadPastTheHistorysRepMaxIsCapped() {
        // 185×5 at RPE 8 is a 7-rep max: e1RM 185×36/30 = 222; 5 reps → 197 + 5.
        let history = [logged("bench-press", 185, 5, rpe: 8)]
        let result = check([row("bench-press", 3, 5, load: 260, main: true)], settings(), history: history)
        #expect(result.workouts.first?.target("load_lb") == 200)
        #expect(result.repairs.map(\.rule) == [.load])
    }

    @Test func aLoadPastTheBaselinesRepMaxIsCapped() {
        let start = StartingSet(exercise: "bench-press", measurements: [.init(metric: "load_lb", value: 155, unit: "lb"),
                                                                         .init(metric: "reps", value: 5, unit: "reps")])
        let result = check([row("bench-press", 3, 8, load: 400, main: true)], settings(starts: [start]))
        // 155×5 is e1RM 174; 8 reps → 140.5 + 5.
        #expect(result.workouts.first?.target("load_lb") == 145)
        #expect(result.repairs.map(\.rule) == [.load])
    }

    @Test func aLoadJumpsAtMostTenPercent() {
        // An easy 135×5 makes a 5-rep max of 159, but the jump from 135 holds it to 148.
        let history = [logged("bench-press", 135, 5, rpe: 6)]
        let result = check([row("bench-press", 3, 5, load: 175, main: true)], settings(), history: history)
        #expect(result.workouts.first?.target("load_lb") == 145)
        #expect(result.repairs.first?.text.contains("10%") == true)
    }

    // MARK: Rule 4: plates

    @Test func barbellLoadsAreInFivePoundSteps() {
        let result = check([row("bench-press", 3, load: 137.5, main: true), row("dumbbell-row", 3, load: 52.5)], settings())
        #expect(result.workouts.map { $0.target("load_lb") } == [140, 52.5])
        #expect(result.repairs.map(\.rule) == [.plates])
    }

    // MARK: Rule 5: main lifts and repeats

    @Test func squatAndDeadliftAreNeverBothMain() {
        let result = check([row("back-squat", 5, 5, main: true), row("deadlift", 5, 5, main: true)], settings())
        #expect(result.workouts.map(\.main) == [true, false])
        #expect(result.workouts.last?.target("sets") == 4)
        #expect(result.repairs.map(\.rule) == [.mainLifts, .sets])
    }

    @Test func anExerciseIsInASessionOnce() {
        let result = check([row("bench-press", 3, main: true), row("dumbbell-row", 3), row("bench-press", 3)], settings())
        #expect(result.workouts.map(\.exercise) == ["bench-press", "dumbbell-row"])
        #expect(result.repairs.map(\.rule) == [.repeats])
        // Another day may repeat it.
        #expect(check([row("bench-press", 3), row("bench-press", 3, on: tuesday)], settings()).repairs.isEmpty)
    }

    // MARK: Rule 6: RPE and light weeks

    @Test func rpeIsCappedByTheAgeTier() {
        let result = check([row("bench-press", 3, rpe: 9.5, main: true), row("dumbbell-row", 3, rpe: 9)], settings(age: 55))
        #expect(result.workouts.map { $0.target("rpe") } == [7, 6])
        #expect(result.repairs.map(\.rule) == [.rpe, .rpe])
    }

    @Test func aLightWeekIsAboutHalfTheSetsAtRPE6() {
        let rows = [row("back-squat", 5, 5, rpe: 8, main: true), row("pull-up", 4, rpe: 7), row("dumbbell-bench-press", 4, rpe: 7),
                    row("dumbbell-romanian-deadlift", 4, rpe: 7)]
        let result = check(rows, settings(), light: true)
        // 18–22 a session at full volume: at most 15 in a light week.
        #expect(result.workouts.reduce(0) { $0 + ($1.target("sets") ?? 0) } == 15)
        #expect(result.workouts.allSatisfy { $0.target("rpe") == 6 })
        #expect(Set(result.repairs.map(\.rule)) == [.rpe, .lightWeek])
    }

    // MARK: A bad model-shaped week

    /// What a model left unchecked might write: bench 12×8 at 400 on a 155 bench, a cable row with no cable, squat
    /// and deadlift both main, RPE 10 at 36, a 137.5 lb press, curls twice. Every rule it breaks is repaired and listed.
    @Test func aBadModelWeekIsFullyRepaired() {
        let start = StartingSet(exercise: "bench-press", measurements: [.init(metric: "load_lb", value: 155, unit: "lb"),
                                                                         .init(metric: "reps", value: 5, unit: "reps")])
        let settings = settings(starts: [start])
        let week = [
            row("bench-press", 12, 8, load: 400, rpe: 10, main: true, session: "Push"),
            row("Seated Cable Rows", 3, 10, session: "Push"),
            row("barbell-curl", 3, 10, load: 67.5, session: "Push"),
            row("barbell-curl", 3, 10, session: "Push"),
            row("back-squat", 5, 5, main: true, on: tuesday, session: "Legs"),
            row("deadlift", 5, 5, main: true, on: tuesday, session: "Legs"),
        ]
        let result = check(week, settings)
        for rule in [PlanGuard.Rule.sets, .load, .rpe, .exercise, .plates, .repeats, .mainLifts] {
            #expect(result.repairs.contains { $0.rule == rule }, "\(rule): \(result.repairs)")
        }
        // Checked again, nothing's left to repair.
        #expect(check(result.workouts, settings).repairs.isEmpty, "\(check(result.workouts, settings).repairs)")
        let bench = result.workouts.first { $0.exercise == "bench-press" }
        #expect(bench?.target("sets") == 5 && bench?.target("load_lb") == 145 && bench?.target("rpe") == 8)
        #expect(!result.workouts.contains { $0.exercise == "seated-cable-rows" })
        #expect(result.workouts.filter { $0.exercise == "deadlift" }.map(\.main) == [false])
    }
}
