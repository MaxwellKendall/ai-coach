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

    /// One change made, as it's made (FIT-50): the step for the progress pill and the workout so far.
    struct Change: Sendable {
        var step: String
        var workouts: [PlannedWorkout]
        var newExercises: [TemplateSeed]
    }

    typealias Progress = @MainActor @Sendable (Change) -> Void

    /// What the model is told: only the examples for the tools it's given (FIT-51: shorter is faster).
    static func instructions(library: [String], today: String, tools: [String]) -> String {
        let examples: [(tool: String, lines: [String])] = [
            ("swap_exercise", ["\"swap deadlifts for RDLs\" or \"RDLs instead of deadlifts\": swap_exercise(exercise: \"Deadlift\", replacement: \"Dumbbell Romanian Deadlift\").",
                               "\"dumbbell bench instead of barbell\": swap_exercise(exercise: \"Bench Press\", replacement: \"Dumbbell Bench Press\")."]),
            ("remove_exercises", ["\"no bench today\": remove_exercises(exercises: [\"Bench Press\"])."]),
            ("only_these", ["\"just pull-ups and rows\" or \"I want to do pull-ups and rows\": only_these(exercises: [\"Pull-up\", \"Dumbbell Row (Single-Arm)\"]).",
                            "\"give me squats and split squat\": only_these(exercises: [\"Back Squat\", \"Split Squat\"]). Naming exercises is never new_workout."]),
            ("add_exercise", ["\"add curls\": add_exercise(exercise: \"Bicep Curl\", pattern: pull).",
                              "\"deadlift 3 sets of 5 at 225\": add_exercise(exercise: \"Deadlift\", sets: 3, reps: 5, pounds: 225)."]),
            ("change_exercise", ["\"make everything 4 sets\": change_exercise(exercise: \"every exercise\", sets: 4). \"bench 165\": change_exercise(exercise: \"Bench Press\", pounds: 165).",
                                 "\"plank for a minute\": change_exercise(exercise: \"Plank\", seconds: 60)."]),
            ("new_workout", ["\"make it a leg day\": new_workout(focus: \"lower body\"). \"mix it up\" or \"regenerate\": new_workout(focus: \"same kind\").",
                             "\"nothing for legs\": new_workout(focus: \"upper body\"). \"give me a workout\": new_workout(focus: \"full body\").",
                             "\"dumbbells only\": new_workout(focus: \"same kind\", equipment: \"dumbbells only\").",
                             "Only call new_workout when they ask for a whole workout without naming exercises."]),
            ("harder_or_easier", ["\"make it harder\": harder_or_easier(direction: \"harder\")."]),
        ]
        var lines = ["You change the user's workout for today by calling tools, one call per change they ask for, even when they ask for several. When every change is made, reply with just: Done.",
                     "Change only what they ask for. Exercises they don't mention stay exactly as they are."]
        if !Set(tools).isDisjoint(with: ["swap_exercise", "add_exercise", "only_these"]) {
            lines.append("Their exercise library, with the movement each trains: \(library.joined(separator: ", ")).")
            lines.append("Use the library name when it's the same exercise; anything else keeps its usual name. An exercise name never includes a tool name.")
        }
        lines.append("Examples:")
        if tools.contains("add_exercise") && tools.contains("remove_exercises") {
            lines.append("\"drop the dead bugs and add planks\": two calls: remove_exercises(exercises: [\"Dead Bug\"]), then add_exercise(exercise: \"Plank\", pattern: core).")
        }
        lines += examples.filter { tools.contains($0.tool) }.flatMap(\.lines)
        lines.append("Today's workout: \(today)")
        return lines.joined(separator: "\n")
    }

    /// The edit. The model is given only the tools the words point at; if that makes no change, it gets all of them.
    @MainActor static func run(_ said: String, today: [PlannedWorkout], setup: TodayWorkout.Setup,
                               progress: Progress? = nil) async throws -> Outcome {
        let hasToday = today.contains { $0.note != TrainingGenerator.warmupNote }
        var tools = SaidChecks.tools(for: said, today: hasToday)
        var tries = 0
        while true {
            tries += 1
            do {
                let outcome = try await attempt(said, today: today, setup: setup, tools: tools, progress: progress)
                if outcome.changed || tools.count == SaidChecks.all(hasToday).count { return outcome }
                if let progress { progress(Change(step: "Trying again", workouts: today, newExercises: [])) }
                tools = SaidChecks.all(hasToday)
            } catch let error as LanguageModelSession.GenerationError {
                // The on-device model now and then fails to decode a tool call; trying again from the start usually works.
                if case .guardrailViolation = error { throw error }
                if tries == 3 { throw error }
                if let progress { progress(Change(step: "Trying again", workouts: today, newExercises: [])) }
                // The same request again can fail the same way; the full set is a different one.
                tools = SaidChecks.all(hasToday)
            }
        }
    }

    private static func attempt(_ said: String, today: [PlannedWorkout], setup: TodayWorkout.Setup, tools names: [String],
                                progress: Progress?) async throws -> Outcome {
        let state = State(TodayWorkout(today, setup: setup), progress: progress)
        state.said.withLock { $0 = said }
        let library = setup.names.keys.sorted().map { slug in
            "\(setup.names[slug]!) (\(setup.catalog.first { $0.slug == slug }?.pattern ?? "other"))"
        }
        let session = LanguageModelSession(
            tools: tools(state).filter { names.contains($0.name) },
            instructions: instructions(library: library, today: state.workout.withLock { $0.text }, tools: names))
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
        /// What the user said, once they have.
        let said = Mutex<String>("")
        let progress: Progress?
        init(_ workout: TodayWorkout, progress: Progress?) {
            self.workout = Mutex(workout)
            self.progress = progress
        }
    }

    struct AgentTool: Tool {
        let name: String
        let description: String
        let parameters: GenerationSchema
        let state: State
        let act: @Sendable (GeneratedContent, inout TodayWorkout) throws -> String?

        func call(arguments: GeneratedContent) async throws -> String {
            // A model that keeps calling the same tool never ends; ten calls is more than any request needs.
            if state.calls.withLock({ $0.count >= 10 }) { return "That's enough changes. Reply with just: Done." }
            state.calls.withLock { $0.append("\(name) \(arguments.jsonString)") }
            let (output, change) = state.workout.withLock { workout -> (String, Change?) in
                do {
                    if let problem = try act(arguments, &workout) { return (problem, nil) }
                    let change = Change(step: workout.done.last ?? "", workouts: workout.rows,
                                        newExercises: workout.newExercises)
                    return ("Done: \(workout.done.last ?? "changed").", change)
                } catch {
                    return ("Those arguments didn't work: \(error.localizedDescription)", nil)
                }
            }
            if let change, let progress = state.progress { await progress(change) }
            return output
        }
    }

    // MARK: Tools

    static func tools(_ state: State) -> [any Tool] {
        let today = state.workout.withLock { $0.names }
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
        @Sendable func said() -> String { state.said.withLock { $0 } }
        @Sendable func oneMore() -> Bool {
            ["a set", "another set", "one more set", "an extra set", "extra set"].contains { said().lowercased().contains($0) }
        }
        @Sendable func int(_ content: GeneratedContent, _ property: String) -> Int? {
            guard let value = try? content.value(Int?.self, forProperty: property) else { return nil }
            let minutes = SpokenNumbers.minutes(in: said())
            switch property {
            case "minutes": return minutes
            case "seconds" where minutes.map { $0 * 60 == value } ?? false: return value
            case "more_sets" where value == 1 && oneMore(): return value
            default: return SpokenNumbers.values(in: said()).contains(Double(value)) ? value : nil
            }
        }

        if !today.isEmpty {
            tool("remove_exercises", "Take exercises out of today's workout",
                 [.init(name: "exercises", schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(name: "today", anyOf: today),
                                                                           minimumElements: 1))]) { arguments, workout in
                if SaidChecks.meansJustThese(said()) { return "They said just these exercises, so call only_these with the ones they want to do." }
                let leaving = Set(try arguments.value([String].self, forProperty: "exercises"))
                if Set(workout.names).isSubset(of: leaving) {
                    return "That would take out everything. If they want a different kind of workout, call new_workout."
                }
                return workout.remove(try arguments.value([String].self, forProperty: "exercises"))
            }
            tool("swap_exercise", "Replace one of today's exercises with a different one",
                 [choice("exercise", "The exercise in today's workout to replace", today),
                  text("replacement", "The exercise to do instead, by its library name when it's in the library"), pattern]) { arguments, workout in
                let replacement = try arguments.value(String.self, forProperty: "replacement")
                if replacement.contains("_") { return "Give just the exercise's name, like Dumbbell Bench Press." }
                return workout.swap(try arguments.value(String.self, forProperty: "exercise"),
                             for: replacement,
                             pattern: try? arguments.value(String?.self, forProperty: "pattern"))
            }
            tool("change_exercise", "Change the sets, reps, seconds or weight of one of today's exercises, or of every exercise",
                 [choice("exercise", "The exercise in today's workout, or every exercise", today + ["every exercise"])] + numbers
                    + [number("more_sets", "Sets to add to what's planned, for \"add a set\"", 1...5)]) { arguments, workout in
                let exercise = try arguments.value(String.self, forProperty: "exercise")
                if exercise == "every exercise", !SaidChecks.meansEvery(said()) {
                    return "They didn't say every exercise. Change only the one they named, or call add_exercise for a new one."
                }
                let sets = int(arguments, "sets")
                return workout.change(exercise == "every exercise" ? nil : exercise, sets: sets,
                                      more: int(arguments, "more_sets") ?? (sets == nil && oneMore() ? 1 : nil), reps: int(arguments, "reps"),
                                      seconds: int(arguments, "seconds"), pounds: int(arguments, "pounds").map(Double.init))
            }
            tool("harder_or_easier", "Make the whole workout harder or easier",
                 [choice("direction", "Harder or easier", ["harder", "easier"])]) { arguments, workout in
                workout.effort(harder: try arguments.value(String.self, forProperty: "direction") == "harder")
            }
        }
        tool("add_exercise", "Add an exercise to today's workout",
             [text("exercise", "The exercise to add, by its library name when it's in the library"), pattern] + numbers) { arguments, workout in
            let name = try arguments.value(String.self, forProperty: "exercise")
            if name.contains("_") { return "Give just the exercise's name, like Bicep Curl." }
            // "Add a set to deadlifts" is a change to one that's already there, however the model called it.
            if oneMore(), int(arguments, "sets") == nil, workout.change(name, more: 1) == nil { return nil }
            return workout.add(name,
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
            let named = SaidChecks.named(in: said(), library: workout.setup.names.values)
            if !named.isEmpty {
                return "They named \(WeeklyReview.list(named)), so don't plan a new workout: call only_these, add_exercise or swap_exercise."
            }
            if !SaidChecks.asksForAWorkout(said()) {
                return "They didn't ask for a whole new workout, only for exercises. Call only_these, add_exercise or swap_exercise."
            }
            var focus = TodayWorkout.Focus(rawValue: try arguments.value(String.self, forProperty: "focus")) ?? .same
            // "Nothing for legs" asks for the opposite of a leg day.
            if SaidChecks.rulesOutLegs(said()), [.lower, .same, .full].contains(focus) { focus = .upper }
            let equipment = (try? arguments.value(String?.self, forProperty: "equipment")).flatMap { $0.flatMap(TodayWorkout.Equipment.init) }
            return workout.regenerate(focus, equipment: equipment ?? .all, minutes: int(arguments, "minutes"))
        }
        return tools
    }
}
