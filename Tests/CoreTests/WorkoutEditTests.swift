import Foundation
import Testing
@testable import AICoach

/// FIT-47: today's workout as the agent's tools read it.
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

    @Test func workingSetsByName() {
        let items = WorkoutEdit.items(lower, names: library)
        #expect(items.map(\.name) == ["Back Squat", "Goblet Squat", "Deadlift", "Plank (Forearm)"])
        #expect(items[1].pounds == 50 && items[3].seconds == 45 && items[3].reps == nil)
    }
}

/// FIT-49: names the agent's tools are given.
struct WorkoutEditFindTests {
    private let library = ["deadlift": "Deadlift", "dumbbell-romanian-deadlift": "Dumbbell Romanian Deadlift",
                           "bench-press": "Bench Press", "dumbbell-bench-press": "Dumbbell Bench Press", "back-squat": "Back Squat"]

    @Test func acronymsAndShortNamesFindTheLibrary() {
        #expect(WorkoutEdit.find("RDLs", in: library) == "dumbbell-romanian-deadlift")
        #expect(WorkoutEdit.find("RDL", in: library) == "dumbbell-romanian-deadlift")
        #expect(WorkoutEdit.find("Bench", in: library) == "bench-press")
        #expect(WorkoutEdit.find("back squats", in: library) == "back-squat")
        #expect(WorkoutEdit.find("Bicep Curl", in: library) == nil)
        #expect(WorkoutEdit.find("dip", in: library) == nil)
    }
}
