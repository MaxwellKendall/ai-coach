import Foundation
import Testing
@testable import AICoach

/// FIT-49: the changes the workout agent's tools make, all by code.
struct TodayWorkoutTests {
    private let day = Date(timeIntervalSince1970: 1_784_552_400)

    private func exercise(_ slug: String, _ pattern: String, equipment: [String] = [], tags: [String] = []) -> Exercise {
        Exercise(slug: slug, attributes: [TemplateAttribute(key: "movement_pattern", values: [pattern]),
                                          TemplateAttribute(key: "equipment", values: equipment),
                                          TemplateAttribute(key: "tags", values: tags)])!
    }

    private var catalog: [Exercise] {
        [exercise("back-squat", "squat", equipment: ["barbell"], tags: ["goal_lift"]),
         exercise("goblet-squat", "squat", equipment: ["dumbbells"]),
         exercise("deadlift", "hinge", equipment: ["barbell"], tags: ["goal_lift"]),
         exercise("dumbbell-romanian-deadlift", "hinge", equipment: ["dumbbells"]),
         exercise("bench-press", "push", equipment: ["barbell"], tags: ["goal_lift"]),
         exercise("push-up", "push"),
         exercise("pull-up", "pull"),
         exercise("dumbbell-row", "pull", equipment: ["dumbbells"]),
         exercise("plank", "core", tags: ["isometric"]),
         exercise("dead-bug", "core")]
    }

    private let names = ["back-squat": "Back Squat", "goblet-squat": "Goblet Squat", "deadlift": "Deadlift",
                         "dumbbell-romanian-deadlift": "Dumbbell Romanian Deadlift", "bench-press": "Bench Press",
                         "push-up": "Push-up", "pull-up": "Pull-up", "dumbbell-row": "Dumbbell Row (Single-Arm)",
                         "plank": "Plank (Forearm)", "dead-bug": "Dead Bug"]

    private var setup: TodayWorkout.Setup {
        let settings = TrainingSettings(age: 36, daysPerWeek: 3, sessionMinutes: 45, trainingDays: [0, 2, 4], workoutTime: 420,
                                        equipment: ["barbell", "dumbbells"], maxWeeklySets: 60)
        let history = [LoggedSet(date: day - 86_400 * 3, exercise: "dumbbell-romanian-deadlift", pattern: "hinge",
                                 measurements: [Measurement(metric: "reps", value: 10, unit: "reps"),
                                                Measurement(metric: "load_lb_hand", value: 40, unit: "lb")])]
        return TodayWorkout.Setup(names: names, catalog: catalog, settings: settings, history: history, weeksSinceDeload: 1,
                                  date: day, session: "Workout")
    }

    private func row(_ exercise: String, _ targets: [(String, Double)], note: String? = nil) -> PlannedWorkout {
        PlannedWorkout(date: day, session: "Workout", exercise: exercise,
                       targets: targets.map { Measurement(metric: $0.0, value: $0.1, unit: $0.0) }, note: note)
    }

    private var today: [PlannedWorkout] {
        [row("deadlift", [("sets", 1), ("reps", 5), ("load_lb", 135)], note: TrainingGenerator.warmupNote),
         row("deadlift", [("sets", 3), ("reps", 5), ("load_lb", 200), ("rpe", 8)]),
         row("bench-press", [("sets", 3), ("reps", 5), ("load_lb", 140), ("rpe", 8)]),
         row("plank", [("sets", 3), ("duration_s", 45)])]
    }

    @Test func aSwapIsDosedFromItsOwnHistoryAndKeepsTheSets() {
        var workout = TodayWorkout(today, setup: setup)
        #expect(workout.swap("Deadlift", for: "Dumbbell Romanian Deadlift") == nil)
        #expect(workout.names == ["Dumbbell Romanian Deadlift", "Bench Press", "Plank (Forearm)"])
        let rdl = workout.rows.first { $0.exercise == "dumbbell-romanian-deadlift" }
        #expect(rdl?.target("sets") == 3 && rdl?.target("load_lb_hand") == 40)
        #expect(Array(workout.rows.suffix(2)) == Array(today.suffix(2)))
        #expect(workout.summary == "Dumbbell Romanian Deadlift for Deadlift")
    }

    @Test func removeAndChangeOnlyTouchWhatWasNamed() {
        var workout = TodayWorkout(today, setup: setup)
        #expect(workout.remove(["bench"]) == nil)
        #expect(workout.change("Plank (Forearm)", reps: 60) == nil)
        #expect(workout.rows.map(\.exercise) == ["deadlift", "deadlift", "plank"])
        #expect(workout.rows[2].target("duration_s") == 60 && workout.rows[2].target("reps") == nil)
        #expect(workout.change("Deadlift", more: 1, pounds: 225) == nil)
        #expect(workout.rows[1].target("sets") == 4 && workout.rows[1].target("load_lb") == 225 && workout.rows[1].target("rpe") == 8)
        #expect(workout.rows[0] == today[0])
        #expect(workout.change("Lunges", sets: 2) != nil)
    }

    @Test func everyExerciseAndEffort() {
        var workout = TodayWorkout(today, setup: setup)
        #expect(workout.change(nil, sets: 4) == nil)
        #expect(workout.rows.filter { $0.note == nil }.allSatisfy { $0.target("sets") == 4 })
        #expect(workout.effort(harder: false) == nil)
        #expect(workout.rows[1].target("sets") == 3 && workout.rows[1].target("load_lb") == 180)
        #expect(workout.rows[0].target("sets") == 1)
    }

    @Test func addingANewExerciseSavesIt() {
        var workout = TodayWorkout([], setup: setup)
        #expect(workout.add("bicep curl", pattern: "pull") == nil)
        #expect(workout.add("Deadlift", sets: 3, reps: 5, pounds: 225) == nil)
        #expect(workout.newExercises.map(\.slug) == ["bicep-curl"])
        #expect(workout.rows.map(\.exercise) == ["bicep-curl", "deadlift"])
        #expect(workout.rows[1].target("load_lb") == 225 && workout.rows[1].target("reps") == 5)
    }

    @Test func onlyTheseKeepsTheirNumbersAndAddsTheRest() {
        var workout = TodayWorkout(today, setup: setup)
        #expect(workout.keepOnly(["Bench Press", "Pull-up"]) == nil)
        #expect(workout.rows.map(\.exercise) == ["bench-press", "pull-up"])
        #expect(workout.rows[0] == today[2])
    }

    @Test func aNewWorkoutIsDifferentAndFollowsTheAsk() {
        var workout = TodayWorkout(today, setup: setup)
        #expect(workout.regenerate(.same) == nil)
        let fresh = Set(workout.rows.map(\.exercise))
        #expect(fresh.isDisjoint(with: ["deadlift", "bench-press", "plank"]))
        #expect(workout.regenerate(.lower, equipment: .dumbbells) == nil)
        #expect(workout.rows.allSatisfy { ["goblet-squat", "dumbbell-romanian-deadlift", "plank", "dead-bug", "back-squat"].contains($0.exercise) })
        #expect(!workout.rows.contains { $0.exercise == "back-squat" })
        #expect(workout.regenerate(.upper, minutes: 15) == nil)
        let patterns = Dictionary(uniqueKeysWithValues: catalog.map { ($0.slug, $0.pattern) })
        #expect(workout.rows.allSatisfy { ["push", "pull", "core"].contains(patterns[$0.exercise]!) })
    }
}
