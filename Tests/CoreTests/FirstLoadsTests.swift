import Foundation
import Testing
@testable import AICoach

/// FIT-73: the first week's loads on onboarding's check step, and the answers the first week is designed from.
struct FirstLoadsTests {
    private let day = Date(timeIntervalSinceReferenceDate: 812_000_000)

    private func row(_ exercise: String, _ targets: [(String, Double)], note: String? = nil) -> PlannedWorkout {
        PlannedWorkout(date: day, session: "Full", exercise: exercise,
                       targets: targets.map { Measurement(metric: $0.0, value: $0.1, unit: $0.0) }, note: note)
    }

    private var week: [PlannedWorkout] {
        [row("bench-press", [("sets", 1), ("reps", 5), ("load_lb", 80)], note: TrainingGenerator.warmupNote),
         row("bench-press", [("sets", 4), ("reps", 5), ("load_lb", 135)]),
         row("dumbbell-row", [("sets", 3), ("reps", 10), ("load_lb_hand", 40)]),
         row("pull-up", [("sets", 3), ("reps", 8)]),
         row("bench-press", [("sets", 4), ("reps", 5), ("load_lb", 135)])]
    }

    @Test func oneItemPerWeightedExercise() {
        let items = FirstLoads.items(week)
        #expect(items.map(\.exercise) == ["bench-press", "dumbbell-row"])
        #expect(items.first == FirstLoads.Item(exercise: "bench-press", metric: "load_lb", value: 135, dose: "4 × 5"))
        #expect(items.last?.metric == "load_lb_hand")
    }

    @Test func aChangedLoadReachesEverySetAndItsWarmup() {
        let week = FirstLoads.applying(["bench-press": 155], to: week)
        #expect(week.filter { $0.exercise == "bench-press" && $0.note == nil }.allSatisfy { $0.target("load_lb") == 155 })
        #expect(week.first?.target("load_lb") == 95)
        #expect(week.first { $0.exercise == "dumbbell-row" }?.target("load_lb_hand") == 40)
    }

    @Test func answersMakeTheSettingsAndGoals() throws {
        var answers = OnboardingAnswers()
        #expect(answers.trainingSettings() == nil)
        answers.age = 36
        answers.weight = 200
        answers.goals = ["bench"]
        answers.targets["bench"] = 225
        answers.hurts = ["knees"]
        let settings = try #require(answers.trainingSettings())
        #expect(settings.bodyWeight == 200 && settings.daysPerWeek == 3 && settings.injuredAreas.contains("quads"))
        let end = Calendar.current.date(from: DateComponents(year: 2027, month: 1, day: 25))!
        #expect(answers.goalLines(by: end) == ["Bench 225 by Jan 25"])
    }
}
