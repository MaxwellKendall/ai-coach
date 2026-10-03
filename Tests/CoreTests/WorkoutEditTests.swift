import Foundation
import Testing
@testable import AICoach

/// FIT-47: the model's edited workout, checked and turned back into plan rows.
struct WorkoutEditTests {
    private let day = Date(timeIntervalSince1970: 1_784_552_400)
    private let library = ["back-squat": "Back Squat", "goblet-squat": "Goblet Squat", "deadlift": "Deadlift",
                           "dumbbell-romanian-deadlift": "Dumbbell Romanian Deadlift", "plank": "Plank (Forearm)"]

    private func row(_ exercise: String, _ targets: [(String, Double)], note: String? = nil, group: Int? = nil) -> PlannedWorkout {
        PlannedWorkout(date: day, session: "Lower", exercise: exercise,
                       targets: targets.map { Measurement(metric: $0.0, value: $0.1, unit: $0.0) }, note: note, group: group)
    }

    private var lower: [PlannedWorkout] {
        [row("back-squat", [("sets", 1), ("reps", 5), ("load_lb", 110)], note: TrainingGenerator.warmupNote),
         row("back-squat", [("sets", 4), ("reps", 5), ("load_lb", 185), ("rpe", 8)]),
         row("goblet-squat", [("sets", 3), ("reps", 10), ("load_lb_hand", 50)]),
         row("deadlift", [("sets", 3), ("reps", 5), ("load_lb", 225)], group: 1),
         row("plank", [("sets", 3), ("duration_s", 45)])]
    }

    private func apply(_ items: [WorkoutEdit.Item]) -> WorkoutEdit.Result? {
        WorkoutEdit.apply(items, to: lower, library: library, date: day, session: "Lower")
    }

    @Test func theModelSeesWorkingSetsByName() {
        let items = WorkoutEdit.items(lower, names: library)
        #expect(items.map(\.name) == ["Back Squat", "Goblet Squat", "Deadlift", "Plank (Forearm)"])
        #expect(items[1].pounds == 50 && items[3].seconds == 45 && items[3].reps == nil)
        #expect(WorkoutEdit.json([items[3]]) == #"[{"name":"Plank (Forearm)","seconds":45,"sets":3}]"#)
    }

    @Test func unchangedExercisesKeepTheirRows() {
        let result = apply(WorkoutEdit.items(lower, names: library))
        #expect(result?.workouts == lower)
        #expect(result?.newExercises == [])
    }

    @Test func aSwapAndANewExercise() throws {
        var items = WorkoutEdit.items(lower, names: library)
        items[2] = .init(name: "Dumbbell Romanian Deadlifts", sets: 3, reps: 8, pounds: 40)
        items.insert(.init(name: "Split Squat", sets: 3, reps: 10, pattern: "squat"), at: 2)
        let result = try #require(apply(items))
        #expect(result.workouts.map(\.exercise) == ["back-squat", "back-squat", "goblet-squat", "split-squat", "dumbbell-romanian-deadlift", "plank"])
        #expect(result.newExercises.map(\.slug) == ["split-squat"])
        #expect(Exercise(slug: "split-squat", attributes: result.newExercises[0].attributes)?.pattern == "squat")
        let rdl = result.workouts[4]
        #expect(rdl.target("sets") == 3 && rdl.target("reps") == 8 && rdl.target("load_lb") == 40 && rdl.date == day && rdl.session == "Lower")
    }

    @Test func shortenedNamesFindTheLibraryAndRepeatsMerge() throws {
        // As the model returned "give me squats and split squat" and "swap deadlifts for RDLs".
        let result = try #require(apply([.init(name: "Squat", sets: 3, reps: 10), .init(name: "Goblet Squat", sets: 3),
                                         .init(name: "Romanian Deadlift", sets: 3, reps: 8),
                                         .init(name: "Curl", sets: 1, reps: 10), .init(name: "Curl", sets: 1, reps: 10)]))
        #expect(result.workouts.map(\.exercise) == ["back-squat", "back-squat", "goblet-squat", "dumbbell-romanian-deadlift", "curl"])
        #expect(result.workouts.last?.target("sets") == 2 && result.newExercises.map(\.slug) == ["curl"])
    }

    @Test func aChangedExerciseKeepsItsOtherTargets() throws {
        var items = WorkoutEdit.items(lower, names: library)
        items[0].sets = 2
        items[1].pounds = 55
        let result = try #require(apply(items))
        let squat = result.workouts[1], goblet = result.workouts[2]
        #expect(squat.target("sets") == 2 && squat.target("rpe") == 8 && squat.adjustedReason == "asked for")
        #expect(goblet.target("load_lb_hand") == 55 && goblet.target("load_lb") == nil) // still per hand
        #expect(result.workouts[3] == lower[3]) // superset untouched
    }

    @Test func numbersLeftOutStayAsPlanned() {
        // As the model returned "give me squats and split squat": every weight gone.
        let items = WorkoutEdit.items(lower, names: library).map { WorkoutEdit.Item(name: $0.name, sets: $0.sets) }
        #expect(apply(items)?.workouts == lower)
        // A hold stays a hold when the model writes its seconds as reps.
        #expect(apply([.init(name: "Plank (Forearm)", sets: 3, reps: 45)])?.workouts == [lower[4]])
    }

    @Test func impossibleNumbersAndEmptyResultsAreRejected() throws {
        let result = try #require(apply([.init(name: "Back Squat", sets: 40, reps: 500, pounds: -5), .init(name: " ", sets: 3)]))
        let squat = try #require(result.workouts.last)
        #expect(squat.target("sets") == 10 && squat.target("reps") == 5 && squat.target("load_lb") == 185) // as planned
        #expect(result.workouts.first?.note == TrainingGenerator.warmupNote) // its warm-up comes along
        #expect(apply([]) == nil)
        // A new exercise with a pattern the planner doesn't know still gets one.
        let odd = try #require(apply([.init(name: "Bicep Curl", sets: 3, reps: 12, pattern: "arms")]))
        #expect(odd.newExercises.first?.attributes.first?.values == ["core"])
    }
}
