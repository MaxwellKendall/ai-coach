import Foundation
import FoundationModels
import Testing
@testable import AICoach

/// FIT-38: onboarding by voice, scored on the real on-device model through `OnboardingSpeech.hear`, the path the mic on
/// each onboarding card takes. Added 2026-10-12 after the goals card failed every phrase on the author's iPhone (the model
/// refused its instructions as sensitive); a refusal here is a failure. Run with
/// `xcodebuild -scheme AICoachEvals … test -only-testing:AICoachEvals/OnboardingSpeechEvals`; writes onboarding-results.md.
struct OnboardingSpeechEvals {
    struct Case: Sendable {
        var step: OnboardingStep
        var said: String
        /// Goals that must be picked, in any order.
        var goals: [String] = []
        /// Targets that must be set.
        var targets: [String: Double] = [:]
        var age: Int? = nil
        var weight: Double? = nil
    }

    static let cases: [Case] = [
        Case(step: .goals, said: "I want to lose about 15 pounds and bench 225 by March", goals: ["weight", "bench"], targets: ["bench": 225]),
        Case(step: .goals, said: "Get stronger and do 10 pull-ups", goals: ["pullups"], targets: ["pullups": 10]),
        Case(step: .goals, said: "Squat 315", goals: ["squat"], targets: ["squat": 315]),
        Case(step: .goals, said: "Get down to 180 and deadlift 400", goals: ["weight", "deadlift"], targets: ["weight": 180, "deadlift": 400]),
        Case(step: .goals, said: "I'd like to drop some weight and get better at push-ups", goals: ["weight", "pushups"]),
        Case(step: .goals, said: "Bench press two hundred by the end of the year", goals: ["bench"]),
        Case(step: .goals, said: "Lean out for summer", goals: ["weight"]),
        Case(step: .goals, said: "Hit a 500 pound deadlift and a 405 squat", goals: ["deadlift", "squat"], targets: ["deadlift": 500, "squat": 405]),
        Case(step: .exercises, said: "No barbell, I like push-ups and dumbbells"),
        Case(step: .exercises, said: "I have a full gym but I hate burpees"),
        Case(step: .starts, said: "I'm 36, I weigh 200 pounds and I squat 155 for 5", age: 36, weight: 200),
        Case(step: .starts, said: "I can bench 185 for 3 and do 6 pull ups"),
        Case(step: .starts, said: "I'm 52 and about 230 pounds", age: 52, weight: 230),
    ]

    @MainActor @Test func onboardingSpeech() async throws {
        let catalog = Planner.catalog([])
        var passed = 0
        var lines = ["# Onboarding by voice: on-device model", "", "| Card | Said | Result |", "|---|---|---|"]
        for c in Self.cases {
            var answers = OnboardingAnswers()
            answers.goals = []
            var problems: [String] = []
            do {
                try await OnboardingSpeech.hear(c.said, on: c.step, into: &answers, catalog: catalog, names: [:])
                for goal in c.goals where !answers.goals.contains(goal) { problems.append("missed \(goal)") }
                for (goal, target) in c.targets where answers.targets[goal] != target {
                    problems.append("\(goal) \(answers.targets[goal].map { "\(Int($0))" } ?? "none"), not \(Int(target))")
                }
                if let age = c.age, answers.age != age { problems.append("age \(answers.age.map(String.init) ?? "none")") }
                if let weight = c.weight, answers.weight != weight { problems.append("weight \(answers.weight.map { "\(Int($0))" } ?? "none")") }
            } catch {
                problems.append("failed: \(String(describing: error).prefix(80))")
            }
            if problems.isEmpty { passed += 1 }
            lines.append("| \(c.step) | \(c.said) | \(problems.isEmpty ? "✅" : "❌ " + problems.joined(separator: "; ")) |")
        }
        lines.insert("**\(passed) of \(Self.cases.count) pass**", at: 2)
        lines.insert("", at: 3)
        let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "onboarding-results.md")
        try lines.joined(separator: "\n").appending("\n").write(to: out, atomically: true, encoding: .utf8)
        print(lines.joined(separator: "\n"))
    }
}
