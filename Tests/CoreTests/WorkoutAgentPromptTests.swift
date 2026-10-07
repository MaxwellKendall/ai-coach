import Foundation
import Testing
@testable import AICoach

/// The spoken-edit agent's instructions fit the on-device model's 4,096-token context with room for its tools, today's
/// workout and its answer. Listing the 700-exercise catalog (FIT-70) overflowed it and every such edit failed; the
/// model evals weren't re-run, so only the phone caught it. This runs on every build.
@MainActor
struct WorkoutAgentPromptTests {
    @Test func instructionsStayWellInsideTheContext() throws {
        let seeds = try Seeder.decode([TemplateSeed].self, "exercises", .main)
        let catalog = seeds.compactMap { Exercise(slug: $0.slug, attributes: $0.attributes) }
        let names = Dictionary(uniqueKeysWithValues: seeds.map { ($0.slug, $0.name) })
        let settings = TrainingSettings(age: 36, daysPerWeek: 3, sessionMinutes: 45, trainingDays: [0, 2, 4], workoutTime: 420,
                                        equipment: Set(Profile.allEquipment), maxWeeklySets: 60)
        let today = ["deadlift", "bench-press", "goblet-squat", "seated-cable-rows"].map {
            PlannedWorkout(date: .now, session: "Workout", exercise: $0, targets: [Measurement(metric: "sets", value: 3, unit: "sets")])
        }
        let setup = TodayWorkout.Setup(names: names, catalog: catalog, settings: settings, history: [], weeksSinceDeload: 1,
                                       date: .now, session: "Workout")
        let library = WorkoutAgent.library(setup, today: today)
        #expect(library.contains("Seated Cable Rows (pull)"))
        #expect(library.contains("Bench Press (push)"))
        let instructions = WorkoutAgent.instructions(library: library, today: "Deadlift 3×5, Bench Press 3×5, Goblet Squat 3×10, Seated Cable Rows 3×10",
                                                     tools: SaidChecks.all(true))
        // ~4 characters a token: under ~1,000 tokens leaves the rest for tool schemas, calls and the answer.
        #expect(instructions.count < 4_000, "\(instructions.count) characters")
    }
}
