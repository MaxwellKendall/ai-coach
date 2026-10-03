import Foundation
import FoundationModels
import Synchronization

/// FIT-49: spoken edits to today's workout as tool calls. The model picks tools and their arguments (exercise names
/// limited to today's and the library where it can be); `TodayWorkout` makes every change by code.
enum WorkoutAgent {
    struct Outcome {
        var workouts: [PlannedWorkout]
        var newExercises: [TemplateSeed]
        /// What changed, written by code for the toast.
        var summary: String
        /// The tool calls, for the evals: `swap_exercise {…}`.
        var calls: [String]
        var changed: Bool
    }

    static func run(_ said: String, today: [PlannedWorkout], setup: TodayWorkout.Setup) async throws -> Outcome {
        // The on-device model now and then fails to decode a tool call; a second try from the start usually works.
        do {
            return try await attempt(said, today: today, setup: setup)
        } catch let error as LanguageModelSession.GenerationError {
            if case .guardrailViolation = error { throw error }
            return try await attempt(said, today: today, setup: setup)
        }
    }

    private static func attempt(_ said: String, today: [PlannedWorkout], setup: TodayWorkout.Setup) async throws -> Outcome {
        let state = State(TodayWorkout(today, setup: setup))
        let library = setup.names.keys.sorted().map { slug in
            "\(setup.names[slug]!) (\(setup.catalog.first { $0.slug == slug }?.pattern ?? "other"))"
        }
        let session = LanguageModelSession(tools: tools(state, today: state.workout.withLock { $0.names }, said: said), instructions: """
            You change the user's workout for today by calling tools, one call per change they ask for. Then say what you did in a few words.
            Change only what they ask for. Exercises they don't mention stay exactly as they are.
            Their exercise library, with the movement each trains: \(library.joined(separator: ", ")).
            Use the library name when it's the same exercise; anything else keeps its usual name.
            Examples:
            "swap deadlifts for RDLs" or "RDLs instead of deadlifts": swap_exercise Deadlift with Dumbbell Romanian Deadlift.
            "no bench today": remove_exercises Bench Press.
            "just pull-ups and rows" or "I want to do pull-ups and rows": only_these Pull-up and Dumbbell Row (Single-Arm).
            "add curls": add_exercise Bicep Curl, pattern pull.
            "deadlift 3 sets of 5 at 225": add_exercise Deadlift, sets 3, reps 5, pounds 225.
            "make everything 4 sets": change_exercise every exercise, sets 4. "bench 165": change_exercise Bench Press, pounds 165.
            "plank for a minute": change_exercise Plank, seconds 60.
            "make it a leg day": new_workout lower body. "mix it up" or "regenerate": new_workout same kind.
            "nothing for legs": new_workout upper body. "give me a workout": new_workout full body.
            "dumbbells only": new_workout same kind, dumbbells only.
            Only call new_workout when they ask for a whole workout without naming exercises.
            "make it harder": harder_or_easier harder.
            Today's workout: \(state.workout.withLock { $0.text })
            """)
        _ = try await session.respond(to: said)
        if state.calls.withLock({ $0.isEmpty }) {
            // The model sometimes answers in words without calling anything.
            _ = try await session.respond(to: "Make that change now by calling a tool.")
        }
        return state.workout.withLock { workout in
            Outcome(workouts: workout.rows, newExercises: workout.newExercises.filter { seed in workout.rows.contains { $0.exercise == seed.slug } },
                    summary: workout.summary, calls: state.calls.withLock { $0 }, changed: !workout.done.isEmpty)
        }
    }

    final class State: Sendable {
        let workout: Mutex<TodayWorkout>
        let calls = Mutex<[String]>([])
        init(_ workout: TodayWorkout) { self.workout = Mutex(workout) }
    }

    struct AgentTool: Tool {
        let name: String
        let description: String
        let parameters: GenerationSchema
        let state: State
        let act: @Sendable (GeneratedContent, inout TodayWorkout) throws -> String?

        func call(arguments: GeneratedContent) async throws -> String {
            state.calls.withLock { $0.append("\(name) \(arguments.jsonString)") }
            return state.workout.withLock { workout in
                do {
                    if let problem = try act(arguments, &workout) { return problem }
                    return "Done. Today's workout is now: \(workout.text)"
                } catch {
                    return "Those arguments didn't work: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: Tools

    private static func tools(_ state: State, today: [String], said: String) -> [any Tool] {
        let patterns = WorkoutEdit.patterns
        var tools: [any Tool] = []
        func tool(_ name: String, _ description: String, _ properties: [DynamicGenerationSchema.Property],
                  _ act: @escaping @Sendable (GeneratedContent, inout TodayWorkout) throws -> String?) {
            let root = DynamicGenerationSchema(name: name, properties: properties)
            guard let schema = try? GenerationSchema(root: root, dependencies: []) else { return }
            tools.append(AgentTool(name: name, description: description, parameters: schema, state: state, act: act))
        }
        func choice(_ name: String, _ description: String, _ choices: [String], optional: Bool = false) -> DynamicGenerationSchema.Property {
            .init(name: name, description: description, schema: DynamicGenerationSchema(name: name, anyOf: choices), isOptional: optional)
        }
        func text(_ name: String, _ description: String) -> DynamicGenerationSchema.Property {
            .init(name: name, description: description, schema: DynamicGenerationSchema(type: String.self))
        }
        func number(_ name: String, _ description: String, _ range: ClosedRange<Int>) -> DynamicGenerationSchema.Property {
            .init(name: name, description: description, schema: DynamicGenerationSchema(type: Int.self, guides: [.range(range)]),
                  isOptional: true)
        }
        let pattern = choice("pattern", "For an exercise not in the library: the movement it trains", patterns, optional: true)
        let numbers = [number("sets", "Sets, only if they said", 1...10), number("reps", "Reps per set, only if they said", 1...50),
                       number("seconds", "Seconds per set for a hold like a plank, only if they said", 5...600),
                       number("pounds", "Weight in pounds, only if they said a weight", 5...1500)]
        // The model fills in numbers nobody said ("swap bench for dumbbell bench": reps 3, 140 lb), so a number is
        // kept only when it was said; seconds may be said as minutes, and one more set as "a set".
        let heard = SpokenNumbers.values(in: said), minutes = SpokenNumbers.minutes(in: said)
        let oneMore = ["a set", "another set", "one more set", "an extra set", "extra set"].contains { said.lowercased().contains($0) }
        @Sendable func int(_ content: GeneratedContent, _ property: String) -> Int? {
            guard let value = try? content.value(Int?.self, forProperty: property) else { return nil }
            switch property {
            case "minutes": return minutes
            case "seconds" where minutes.map { $0 * 60 == value } ?? false: return value
            case "more_sets" where value == 1 && oneMore: return value
            default: return heard.contains(Double(value)) ? value : nil
            }
        }

        if !today.isEmpty {
            tool("remove_exercises", "Take exercises out of today's workout",
                 [.init(name: "exercises", schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(name: "today", anyOf: today),
                                                                           minimumElements: 1))]) { arguments, workout in
                workout.remove(try arguments.value([String].self, forProperty: "exercises"))
            }
            tool("swap_exercise", "Replace one of today's exercises with a different one",
                 [choice("exercise", "The exercise in today's workout to replace", today),
                  text("replacement", "The exercise to do instead, by its library name when it's in the library"), pattern]) { arguments, workout in
                workout.swap(try arguments.value(String.self, forProperty: "exercise"),
                             for: try arguments.value(String.self, forProperty: "replacement"),
                             pattern: try? arguments.value(String?.self, forProperty: "pattern"))
            }
            tool("change_exercise", "Change the sets, reps, seconds or weight of one of today's exercises, or of every exercise",
                 [choice("exercise", "The exercise in today's workout, or every exercise", today + ["every exercise"])] + numbers
                    + [number("more_sets", "Sets to add to what's planned, for \"add a set\"", 1...5)]) { arguments, workout in
                let exercise = try arguments.value(String.self, forProperty: "exercise")
                let sets = int(arguments, "sets")
                return workout.change(exercise == "every exercise" ? nil : exercise, sets: sets,
                                      more: int(arguments, "more_sets") ?? (sets == nil && oneMore ? 1 : nil), reps: int(arguments, "reps"),
                                      seconds: int(arguments, "seconds"), pounds: int(arguments, "pounds").map(Double.init))
            }
            tool("harder_or_easier", "Make the whole workout harder or easier",
                 [choice("direction", "Harder or easier", ["harder", "easier"])]) { arguments, workout in
                workout.effort(harder: try arguments.value(String.self, forProperty: "direction") == "harder")
            }
        }
        tool("add_exercise", "Add an exercise to today's workout",
             [text("exercise", "The exercise to add, by its library name when it's in the library"), pattern] + numbers) { arguments, workout in
            workout.add(try arguments.value(String.self, forProperty: "exercise"),
                        pattern: try? arguments.value(String?.self, forProperty: "pattern"), sets: int(arguments, "sets"),
                        reps: int(arguments, "reps"), seconds: int(arguments, "seconds"),
                        pounds: int(arguments, "pounds").map(Double.init))
        }
        tool("only_these", "Today's workout becomes only the exercises they name",
             [.init(name: "exercises", schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self), minimumElements: 1))]) { arguments, workout in
            workout.keepOnly(try arguments.value([String].self, forProperty: "exercises"))
        }
        tool("new_workout", "Plan a whole new workout for today, only when they name no exercises: a different one, a kind of day, or limited equipment or time",
             [choice("focus", "What it trains; same kind keeps today's kind of day", TodayWorkout.Focus.allCases.map(\.rawValue)),
              choice("equipment", "Equipment it may use", TodayWorkout.Equipment.allCases.map(\.rawValue), optional: true),
              number("minutes", "How long it should take, only if they said", 10...120)]) { arguments, workout in
            let focus = TodayWorkout.Focus(rawValue: try arguments.value(String.self, forProperty: "focus")) ?? .same
            let equipment = (try? arguments.value(String?.self, forProperty: "equipment")).flatMap { $0.flatMap(TodayWorkout.Equipment.init) }
            return workout.regenerate(focus, equipment: equipment ?? .all, minutes: int(arguments, "minutes"))
        }
        return tools
    }
}
