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

/// FIT-48 "changes" strategy: only what changes, applied by code to today's workout.
@Generable
struct WorkoutChangesDraft {
    @Guide(description: "Under six words saying what changes, e.g. Split squats added")
    var summary: String
    @Guide(description: "Each change the user asked for, and nothing else")
    var changes: [Change]

    @Generable
    struct Change {
        @Guide(.anyOf(["add", "remove", "replace", "update"]))
        var action: String
        @Guide(description: "For remove, replace and update: the exercise in today's workout, by its name there. For add: the new exercise.")
        var exercise: String
        @Guide(description: "For replace only: the exercise that takes its place")
        var with: String?
        @Guide(description: "For add, or the exercise taking its place: the movement it trains")
        var pattern: String?
        @Guide(description: "Sets, only if the user gave a number or asked for more or fewer")
        var sets: Int?
        @Guide(description: "Reps per set, only if the user said")
        var reps: Int?
        @Guide(description: "Seconds per set, only for a hold done for time, only if the user said")
        var seconds: Int?
        @Guide(description: "Weight in pounds, only if the user said a weight")
        var pounds: Double?
    }
}

enum WorkoutEditor {
    enum Strategy: String, Sendable { case rewrite, changes }
    struct Outcome {
        /// nil when nothing usable came back.
        var result: WorkoutEdit.Result?
        var summary: String
        /// What the model wrote, before validation (for the evals).
        var raw: [WorkoutEdit.Item]
    }

    /// The whole edit: the app and the evals (FIT-48) both run this. `library` is slug → name, `patterns`
    /// slug → movement pattern; `today` is empty on a rest day.
    static func run(_ said: String, today: [PlannedWorkout], library: [String: String], patterns: [String: String],
                    date: Date, session: String, strategy: Strategy = .rewrite) async throws -> Outcome {
        let listed = library.map { "\($0.value) (\(patterns[$0.key] ?? "other"))" }.sorted()
        let items = WorkoutEdit.items(today, names: library)
        let edited = switch strategy {
        case .rewrite: try await edit(items, library: listed, said: said)
        case .changes: try await changes(items, library: listed, said: said)
        }
        let summary = edited.summary.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(["."]))
        return Outcome(result: WorkoutEdit.apply(edited.items, to: today, library: library, date: date, session: session),
                       summary: summary, raw: edited.items)
    }

    private static func edit(_ items: [WorkoutEdit.Item], library: [String], said: String) async throws -> (items: [WorkoutEdit.Item], summary: String) {
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

    private static func changes(_ items: [WorkoutEdit.Item], library: [String], said: String) async throws -> (items: [WorkoutEdit.Item], summary: String) {
        let session = LanguageModelSession(instructions: """
            You are editing the user's workout for today. List only the changes they ask for; everything else stays as it is.
            add: a new exercise. remove: take one out. replace: one exercise for another. update: new sets, reps, seconds or weight.
            Use names from their library when it's the same exercise: \(library.joined(separator: ", ")).
            Examples, for a workout of Deadlift, Bench Press and Plank:
            "swap deadlifts for RDLs": replace Deadlift with Dumbbell Romanian Deadlift.
            "just pull-ups and rows": add Pull-up, add Dumbbell Row, remove Deadlift, remove Bench Press, remove Plank.
            "only two sets of bench": update Bench Press, sets 2.
            "add curls": add Bicep Curl.
            Today's workout: \(WorkoutEdit.json(items))
            """)
        let draft = try await session.respond(to: said, generating: WorkoutChangesDraft.self).content
        let changes = draft.changes.compactMap { change in
            WorkoutEdit.Change.Action(rawValue: change.action).map {
                WorkoutEdit.Change(action: $0, exercise: change.exercise, with: change.with, sets: change.sets, reps: change.reps,
                                   seconds: change.seconds, pounds: change.pounds, pattern: change.pattern)
            }
        }
        return (WorkoutEdit.applying(changes, to: items), draft.summary)
    }
}
