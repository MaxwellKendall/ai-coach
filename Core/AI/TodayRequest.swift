import Foundation
import FoundationModels

/// What was said to Today's mic (FIT-29, FIT-30). The model only sorts and copies out what was said;
/// the plan rules decide what changes, and the user checks it before anything is saved.
@Generable
struct TodayRequestKind {
    @Guide(.anyOf(["change", "exercises", "did_workout", "log"]))
    var kind: String
}

/// FIT-46: which exercises they want today and which they don't. Code checks each name against what was said.
@Generable
struct ExerciseRequestDraft {
    @Guide(description: "Exercises they want to do today. Use the library's name when it's the same exercise, else the name as they said it.")
    var add: [String]
    @Guide(description: "Exercises they don't want today, or want swapped out")
    var remove: [String]
}

@Generable
struct TodayWorkoutDraft {
    @Guide(description: "Only sets the user said were different from the plan. Empty when they just say they did it.")
    var differences: [Difference]

    @Generable
    struct Difference {
        @Guide(description: "The exercise as they said it")
        var exercise: String
        @Guide(description: "Which set they named: a number, or last. Omit when they mean every set.")
        var set: String?
        @Guide(description: "Reps, only if they said how many reps")
        var reps: Double?
        @Guide(description: "Weight in pounds, only if they said a weight")
        var pounds: Double?
    }
}

/// Everything the model produced, before code checks it against what was said.
struct TodayRequestDraft {
    var kind: String
    var minutes: Int?
    var lowEnergy: Bool?
    var hurts: String?
    var moveTo: String?
    var differences: [TodayWorkoutDraft.Difference] = []
}

/// The parse as plain values, so the rules that use it are testable without the model.
struct SpokenRequest: Equatable, Sendable {
    enum Change: Equatable, Sendable {
        case time(minutes: Int), energy, injury(area: String), move(weekday: Int)
    }

    struct Difference: Equatable, Sendable {
        var exercise: String
        /// 1-based; nil means every set, and `.max` the last.
        var set: Int?
        var reps: Double?
        var pounds: Double?
    }

    enum Kind: Equatable, Sendable {
        case change(Change)
        /// Names as the model returned them; `SessionEdit.resolve` matches them to the library.
        case exercises(add: [String], remove: [String], only: Bool)
        case didWorkout([Difference])
        case log
    }

    var kind: Kind
}

extension SpokenRequest {
    /// The small model sometimes fills fields nobody mentioned, or misses ones that were. Minutes, body parts
    /// and days are short, fixed patterns, so code reads those from the words; a number the model returns is
    /// kept only if it was said; and a difference is kept only if its exercise was named.
    /// In a workout, `current` is the exercise on screen: differences that don't name one are about it.
    static func checked(_ draft: TodayRequestDraft, against text: String, current: String? = nil) -> TodayRequestDraft {
        let said = text.lowercased()
        let words = said.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let numbers = SpokenNumbers.values(in: said)
        var draft = draft
        draft.minutes = SpokenNumbers.minutes(in: said)
        draft.hurts = BodyArea.mentioned(in: words)
        draft.lowEnergy = ["tired", "exhausted", "wrecked", "drained", "fatigued", "sore", "slept bad", "slept poor",
                           "didn't sleep", "no sleep", "low energy", "no energy", "beat", "wiped"].contains { said.contains($0) }
        draft.moveTo = draft.kind == "change" && (said.contains("move") || said.contains("instead") || said.contains("switch"))
            ? weekdays.first { said.contains($0) } : nil
        draft.differences = draft.differences.compactMap { difference in
            var difference = difference
            let named = difference.exercise.lowercased().split(separator: " ").contains { word in
                words.contains(String(word)) || words.contains { $0.hasPrefix(word.prefix(5)) }
            }
            if !named {
                guard let current else { return nil }
                difference.exercise = current
            }
            if let reps = difference.reps, reps <= 0 || !numbers.contains(reps) { difference.reps = nil }
            if let pounds = difference.pounds, !numbers.contains(pounds) { difference.pounds = nil }
            if let set = difference.set?.lowercased(), !(Int(set).map { (1...10).contains($0) && numbers.contains(Double($0)) } ?? false) {
                difference.set = words.contains("last") ? "last" : nil
            }
            return difference.reps == nil && difference.pounds == nil ? nil : difference
        }
        return draft
    }

    static let weekdays = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]

    /// nil when a change was asked for but nothing in it is something the rules can act on.
    init?(_ draft: TodayRequestDraft) {
        switch draft.kind {
        case "change":
            if let minutes = draft.minutes, minutes > 0 { kind = .change(.time(minutes: minutes)) }
            else if let area = draft.hurts?.trimmingCharacters(in: .whitespaces), !area.isEmpty { kind = .change(.injury(area: area)) }
            else if let day = draft.moveTo.flatMap(Self.weekdays.firstIndex) { kind = .change(.move(weekday: day)) }
            else if draft.lowEnergy == true { kind = .change(.energy) }
            else { return nil }
        case "did_workout":
            kind = .didWorkout(draft.differences.map { difference in
                let set = difference.set?.lowercased().trimmingCharacters(in: .whitespaces)
                return Difference(exercise: difference.exercise,
                                  set: set == "last" ? .max : set.flatMap { Int($0) },
                                  reps: difference.reps, pounds: difference.pounds)
            })
        default:
            kind = .log
        }
    }
}

enum TodayRequestParser {
    /// Two small steps, because the on-device model mixes fields up in one big schema: sort what was said,
    /// then copy out only that kind's facts. Code then drops anything the words don't support.
    /// `library` is the exercise names, so the model can say "Dumbbell Romanian Deadlift" for "RDLs".
    static func parse(_ text: String, library: [String] = []) async throws -> SpokenRequest? {
        let sorter = LanguageModelSession(instructions: """
            Sort what the user said to their fitness app.
            change: they can't do today's workout as planned. "I only have thirty minutes", "my knee hurts",
            "slept badly", "move it to Saturday".
            exercises: they want different exercises today. "Give me squats and split squats", "swap deadlifts for RDLs",
            "no bench today", "just pull-ups and rows".
            did_workout: they did their workout. "Did it", "done, last bench set was only four".
            log: food, sleep, body weight or grocery spending. "Had a chicken bowl", "weighed 182".
            """)
        // The model's safety check can refuse ordinary sentences like "my shoulder hurts". Then code sorts it:
        // anything the change rules can read is a change.
        let kind: String
        do {
            kind = try await sorter.respond(to: text, generating: TodayRequestKind.self).content.kind
        } catch LanguageModelSession.GenerationError.refusal {
            let read = SpokenRequest.checked(TodayRequestDraft(kind: "change"), against: text)
            kind = read.minutes != nil || read.hurts != nil || read.moveTo != nil || read.lowEnergy == true ? "change" : "exercises"
        }
        if kind == "exercises" { return try await exercises(text, library: library) }
        var draft = TodayRequestDraft(kind: kind)
        // A change's minutes, body part, day and tiredness are read by code (`checked`); sets need the model.
        if kind == "did_workout" { draft.differences = try await differences(text, doing: nil) }
        // A change none of those rules can read may still name exercises ("give me squats today").
        if let request = SpokenRequest(SpokenRequest.checked(draft, against: text)) { return request }
        return kind == "change" ? try await exercises(text, library: library) : nil
    }

    /// FIT-46. "Just" or "only" is read by code: the model sets flags nobody said.
    private static func exercises(_ text: String, library: [String]) async throws -> SpokenRequest? {
        let session = LanguageModelSession(instructions: """
            The user wants different exercises in today's workout. Copy out the exercises they want and the ones they don't.
            Their exercise library: \(library.joined(separator: ", ")).
            Example: "swap deadlifts for RDLs" adds Dumbbell Romanian Deadlift and removes Deadlift.
            """)
        let draft: ExerciseRequestDraft
        do {
            draft = try await session.respond(to: text, generating: ExerciseRequestDraft.self).content
        } catch LanguageModelSession.GenerationError.refusal {
            draft = ExerciseRequestDraft(add: library, remove: []) // resolve keeps only the ones that were said
        }
        guard !draft.add.isEmpty || !draft.remove.isEmpty else { return nil }
        let words = text.lowercased().split { !$0.isLetter }
        return SpokenRequest(kind: .exercises(add: draft.add, remove: draft.remove,
                                              only: words.contains("just") || words.contains("only")))
    }

    /// Mid-workout (FIT-31): how the sets of the exercise on screen went. Empty means as planned.
    static func parseSets(_ text: String, exercise: String) async throws -> [SpokenRequest.Difference] {
        let differences = try await differences(text, doing: exercise)
        let checked = SpokenRequest.checked(TodayRequestDraft(kind: "did_workout", differences: differences), against: text, current: exercise)
        guard case .didWorkout(let result)? = SpokenRequest(checked)?.kind else { return [] }
        return result
    }

    /// Numbers in the example can't leak: `checked` drops any number that wasn't said.
    private static func differences(_ text: String, doing exercise: String?) async throws -> [TodayWorkoutDraft.Difference] {
        let session = LanguageModelSession(instructions: """
            The user \(exercise.map { "is doing \($0) and says how their sets went" } ?? "did their workout").
            Copy out only sets they said were different from the plan. Never invent sets or numbers.
            Example: "last bench set was only four" is exercise bench, set last, reps 4.
            Weights are often said in parts: "two thirty five" means 235 pounds.
            """)
        return try await session.respond(to: text, generating: TodayWorkoutDraft.self).content.differences
    }
}
