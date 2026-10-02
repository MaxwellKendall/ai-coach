import Foundation
import Testing
@testable import AICoach

struct ProfileTests {
    private let gym: Set<String> = ["barbell", "rack", "bench", "dumbbells", "pull_up_bar"]

    /// fitness-planner profile.json active_goals for a 36-year-old at 200 lb (Tier 30–39).
    @Test func suggestionsMatchTheTierTable() {
        let goals = GoalSuggestions.suggestions(age: 36, weightLb: 200, targetWeightLb: 180, equipment: gym)
        let targets = Dictionary(uniqueKeysWithValues: goals.map { ($0.metric, $0.target) })
        #expect(targets == ["back-squat.1rm_lb": 250, "bench-press.1rm_lb": 200, "deadlift.1rm_lb": 350,
                            "pull-up.reps": 10, "5k.duration_min": 25, "protein_g": 160, "weight_lb": 180])
    }

    @Test func olderTierRoundsToTheNearest5() {
        let goals = GoalSuggestions.suggestions(age: 45, weightLb: 183, targetWeightLb: nil, equipment: gym)
        let targets = Dictionary(uniqueKeysWithValues: goals.map { ($0.metric, $0.target) })
        #expect(targets["back-squat.1rm_lb"] == 185)   // 1.0 × 183
        #expect(targets["bench-press.1rm_lb"] == 155)  // 0.85 × 183 = 155.6
        #expect(targets["pull-up.reps"] == 8)
        #expect(targets["protein_g"] == 146)
        #expect(targets["weight_lb"] == nil)           // no target weight, no goal
    }

    @Test func withoutABarbellThePushGoalIsPushUps() {
        let metrics = GoalSuggestions.suggestions(age: 36, weightLb: 200, targetWeightLb: nil, equipment: ["dumbbells"])
            .map(\.metric)
        #expect(metrics == ["push-up.reps", "5k.duration_min", "protein_g"])
    }

    @Test func existingGoalsAreNotSuggestedAgain() {
        let metrics = GoalSuggestions.suggestions(age: 36, weightLb: 200, targetWeightLb: nil, equipment: gym,
                                                  existing: ["back-squat.1rm_lb", "protein_g"]).map(\.metric)
        #expect(!metrics.contains("back-squat.1rm_lb") && !metrics.contains("protein_g"))
    }

    @Test func profileBecomesGeneratorSettings() {
        let profile = Profile(age: 36, weightLb: 200, trainingDays: [4, 0, 2], injuredAreas: ["lower_back"])
        let settings = profile.trainingSettings
        #expect(settings.daysPerWeek == 3)
        #expect(settings.trainingDays == [0, 2, 4])
        #expect(settings.workoutTime == 420)
        #expect(settings.equipment == Set(Profile.allEquipment))
        #expect(settings.injuredAreas == ["lower_back"])
        #expect(settings.deloadEveryWeeks == nil)
    }

    @Test func commaListsAreTrimmedAndLowercased() {
        #expect(Profile.list(" lower_back, Shoulders ,, ") == ["lower_back", "shoulders"])
    }

    @Test func customGoalLabels() {
        #expect(Goal.label("grocery_spend") == "Grocery spend")
        #expect(Goal.label("back-squat.1rm_lb") == "Back Squat 1RM")
    }
}
