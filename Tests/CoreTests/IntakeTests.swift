import Foundation
import SwiftData
import Testing
@testable import AICoach

/// FIT-219: the intake's answers land in the profile and goals that sync, and no program is made.
@MainActor
struct IntakeTests {
    private let now = Date(timeIntervalSince1970: 1_792_000_000)

    private func set(_ exercise: String, _ load: Double) -> StartingSet {
        StartingSet(exercise: exercise, measurements: [.init(metric: "load_lb", value: load, unit: "lb"), .init(metric: "reps", value: 5, unit: "reps")])
    }

    @Test func theAnswersSyncAsTheProfileAndGoals() throws {
        let context = ModelContext(try AppSchema.container(inMemory: true))
        let profile = Profile(age: 0, weightLb: 0)
        context.insert(profile)
        var answers = OnboardingAnswers()
        answers.goals = ["squat"]
        answers.targets = ["squat": 315]
        answers.weeks = 12
        answers.equipment = ["barbell", "rack", "dumbbells"]
        answers.avoid = ["barbell-lunge"]
        answers.hurts = ["knees"]
        answers.age = 34
        answers.weight = 190
        answers.days = [1, 3, 5]
        answers.minutes = 60
        answers.starts = ["back-squat": set("back-squat", 245),
                          "bench-press": set("bench-press", 185)]
        answers.unconfirmed = ["start.bench-press"]

        Intake.save(answers, to: profile, goals: [], in: context, now: now)

        let body = try SyncUnits.decode(SyncUnits.ProfileBody.self, try #require(SyncUnits.all(in: context)["profile"]))
        #expect(body.age == 34 && body.weightLb == 190)
        #expect(body.trainingDays == [1, 3, 5] && body.sessionMinutes == 60)
        #expect(body.equipment == ["barbell", "rack", "dumbbells"])
        #expect(body.avoidExercises == ["barbell-lunge"] && body.injuredAreas == ["knees"])
        // Only the set they gave; the suggested one isn't theirs.
        #expect(body.starts.map(\.exercise) == ["back-squat"])
        #expect(body.programStart == nil && body.targetDate == nil)

        let goal = try #require(try context.fetch(FetchDescriptor<Goal>()).first)
        let goalBody = try SyncUnits.decode(SyncUnits.GoalBody.self, try #require(SyncUnits.all(in: context)["goal#\(goal.id.uuidString)"]))
        #expect(goalBody.target == 315)
        #expect(goalBody.deadline == Calendar.current.date(byAdding: .day, value: 83, to: Week.start(of: now)))
    }

    @Test func skippingKeepsTheProfileAsItWas() throws {
        let context = ModelContext(try AppSchema.container(inMemory: true))
        let profile = Profile(age: 41, weightLb: 172)
        context.insert(profile)
        Intake.save(OnboardingAnswers(profile, goals: []), to: profile, goals: [], in: context, now: now)
        #expect(profile.age == 41 && profile.weightLb == 172)
        #expect(try context.fetch(FetchDescriptor<Goal>()).isEmpty)
    }
}
