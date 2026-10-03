import Foundation
import FoundationModels

/// FIT-47: the whole edited workout, so the model never has to describe a change, only write the result.
@Generable
struct EditedWorkoutDraft {
    /// First, so the model decides the change before writing the list.
    @Guide(description: "Under six words saying what changes, e.g. Split squats added")
    var summary: String
    @Guide(description: "Every exercise in the edited workout, in order, including the ones that didn't change")
    var exercises: [Exercise]

    @Generable
    struct Exercise {
        @Guide(description: "The library's name when it's the same exercise, else its usual name in title case")
        var name: String
        @Guide(.anyOf(WorkoutEdit.patterns))
        var pattern: String
        @Guide(.range(1...10))
        var sets: Int
        @Guide(description: "Reps per set. Omit for a hold done for time.")
        var reps: Int?
        @Guide(description: "Seconds per set, only for a hold done for time")
        var seconds: Int?
        @Guide(description: "Weight in pounds. Omit for bodyweight or when the user should pick it.")
        var pounds: Double?
    }
}

enum WorkoutEditor {
    static func edit(_ items: [WorkoutEdit.Item], library: [String], said: String) async throws -> (items: [WorkoutEdit.Item], summary: String) {
        let session = LanguageModelSession(instructions: """
            You are editing the user's workout for today. Return the whole workout after making only the change they ask for.
            Keep every exercise they didn't ask to change exactly as it is, with its weight, and add nothing they didn't ask for.
            Prefer exercises from their library, written with their full library name, listed with the movement each trains: \(library.joined(separator: ", ")).
            A new exercise gets sets, reps and weight like the others; leave out the weight if you can't tell what they lift.
            Holds like a plank use seconds, not reps.
            Examples, for a workout of Deadlift, Bench Press and Plank:
            "swap deadlifts for RDLs": Dumbbell Romanian Deadlift, Bench Press, Plank.
            "just pull-ups and rows": Pull-up, Dumbbell Row. Nothing else.
            "add curls": Deadlift, Bench Press, Plank, Bicep Curl.
            "make it a leg day": the squat and hinge exercises from the library; upper body ones go.
            Today's workout: \(WorkoutEdit.json(items))
            """)
        let draft = try await session.respond(to: said, generating: EditedWorkoutDraft.self).content
        return (draft.exercises.map {
            WorkoutEdit.Item(name: $0.name, sets: $0.sets, reps: $0.reps, seconds: $0.seconds, pounds: $0.pounds, pattern: $0.pattern)
        }, draft.summary)
    }
}
