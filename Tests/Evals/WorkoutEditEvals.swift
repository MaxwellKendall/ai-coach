import Foundation
import FoundationModels
import Testing
@testable import AICoach

/// FIT-48: spoken workout edits scored on the real on-device model, through the same path as the mic on Today
/// (TodayRequestParser → WorkoutAgent.run). Run with `scripts/eval.sh`; not part of the normal test run.
struct WorkoutEditEvals {
    /// Exercises as slugs. "a|b" accepts either; a new exercise's slug is its name ("split-squat").
    struct Case: Sendable {
        var said: String
        var day: Day
        /// Each must be in the edited workout.
        var has: [String] = []
        /// None of these may be.
        var lacks: [String] = []
        /// Nothing but `has`.
        var only = false
        /// A kind of day ("make it a leg day"): exercises may come and go beyond `has` and `lacks`.
        var open = false
        /// Expected numbers for an exercise; nil fields aren't checked.
        var targets: [String: Target] = [:]
        // Open-ended requests ("regenerate today's workout") have no one right answer, so they're scored on properties.
        /// At least half of today's exercises are gone.
        var differs = false
        /// How many exercises it should have.
        var size: ClosedRange<Int>? = nil
        /// Each group: at least one exercise trains one of these movements.
        var patterns: [[String]] = []
        /// No exercise trains these.
        var lacksPatterns: [String] = []
        /// Library exercises may only need this equipment (none is bodyweight); new exercises fail.
        var equipment: Set<String>? = nil
        var effort: Effort? = nil
    }

    enum Effort: Sendable { case harder, easier }

    struct Target: Sendable {
        var sets: Int? = nil, reps: Int? = nil, seconds: Int? = nil, pounds: Double? = nil
    }

    enum Day: String, Sendable { case full, upper, rest }

    static let cases: [Case] = [
        // A full-body day: Deadlift (with warm-up), Bench Press, Goblet Squat, Dead Bug.
        Case(said: "Give me squats and split squat for today", day: .full, has: ["back-squat|goblet-squat", "split-squat|bulgarian-split-squat"]),
        Case(said: "Swap deadlifts for RDLs", day: .full, has: ["dumbbell-romanian-deadlift"], lacks: ["deadlift"]),
        Case(said: "RDLs instead of deadlifts today", day: .full, has: ["dumbbell-romanian-deadlift"], lacks: ["deadlift"]),
        Case(said: "No bench today", day: .full, lacks: ["bench-press"]),
        Case(said: "Skip the bench press", day: .full, lacks: ["bench-press"]),
        Case(said: "Just pull-ups and rows today", day: .full, has: ["pull-up", "dumbbell-row"], only: true),
        Case(said: "Replace bench with push-ups", day: .full, has: ["push-up"], lacks: ["bench-press"]),
        Case(said: "Do dumbbell bench instead of barbell", day: .full, has: ["dumbbell-bench-press"], lacks: ["bench-press"]),
        Case(said: "Um can we do back squats instead of goblet squats", day: .full, has: ["back-squat"], lacks: ["goblet-squat"]),
        Case(said: "Swap the goblet squat for lunges", day: .full, has: ["lunge|walking-lunge|dumbbell-lunge|reverse-lunge"], lacks: ["goblet-squat"]),
        Case(said: "Drop the dead bugs and add planks", day: .full, has: ["plank"], lacks: ["dead-bug"]),
        Case(said: "Add some curls at the end", day: .full, has: ["curl|bicep-curl|biceps-curl|dumbbell-curl|dumbbell-bicep-curl"]),
        Case(said: "Add farmer carries", day: .full, has: ["farmer-carry"]),
        Case(said: "Make everything 4 sets", day: .full, targets: ["deadlift": .init(sets: 4), "bench-press": .init(sets: 4),
                                                                    "goblet-squat": .init(sets: 4), "dead-bug": .init(sets: 4)]),
        Case(said: "Add a set to deadlifts", day: .full, targets: ["deadlift": .init(sets: 4)]),
        Case(said: "Only two sets of bench", day: .full, targets: ["bench-press": .init(sets: 2)]),
        Case(said: "Bump the deadlift to 225", day: .full, targets: ["deadlift": .init(pounds: 225)]),
        Case(said: "I want to do 8 reps on goblet squats", day: .full, targets: ["goblet-squat": .init(reps: 8)]),
        Case(said: "Make it a leg day", day: .full, has: ["back-squat|goblet-squat|split-squat"], lacks: ["bench-press"], open: true),
        Case(said: "Upper body only today", day: .full, has: ["bench-press|push-up|pull-up|dumbbell-row|dumbbell-bench-press"],
             lacks: ["deadlift", "goblet-squat"], open: true),
        // An upper day: Bench Press, Pull-up, Dumbbell Row, Plank (45 s).
        Case(said: "No pull-ups today", day: .upper, lacks: ["pull-up"]),
        Case(said: "Swap the rows for push-ups", day: .upper, has: ["push-up"], lacks: ["dumbbell-row"]),
        Case(said: "Just bench and plank", day: .upper, has: ["bench-press", "plank"], only: true),
        Case(said: "Make the plank a minute", day: .upper, targets: ["plank": .init(seconds: 60)]),
        Case(said: "Add face pulls", day: .upper, has: ["face-pull|cable-face-pull|band-face-pull"]),
        Case(said: "Add dips at the end", day: .upper, has: ["dip|tricep-dip|chest-dip|bench-dip"]),
        Case(said: "Bench 165 today", day: .upper, targets: ["bench-press": .init(pounds: 165)]),
        // A rest day: nothing planned.
        Case(said: "Give me squats and split squat for today", day: .rest, has: ["back-squat|goblet-squat", "split-squat|bulgarian-split-squat"]),
        Case(said: "I want to do pull-ups and push-ups", day: .rest, has: ["pull-up", "push-up"]),
        Case(said: "Deadlift 3 sets of 5 at 225", day: .rest, has: ["deadlift"], targets: ["deadlift": .init(sets: 3, reps: 5, pounds: 225)]),
        Case(said: "Give me a quick core workout", day: .rest, has: ["plank|dead-bug"], open: true),
        // Open-ended: the whole workout regenerated.
        Case(said: "Regenerate today's workout", day: .full, open: true, differs: true, size: 3...7),
        Case(said: "Give me a completely different workout today", day: .full, open: true, differs: true, size: 3...7),
        Case(said: "Mix it up, I'm bored of this one", day: .full, open: true, differs: true, size: 3...7),
        Case(said: "Regenerate this workout", day: .upper, open: true, differs: true, size: 3...7),
        Case(said: "Give me a harder workout", day: .full, open: true, size: 3...8, effort: .harder),
        Case(said: "Make it easier today", day: .full, open: true, size: 2...6, effort: .easier),
        Case(said: "Dumbbells only today", day: .full, open: true, size: 3...7, equipment: ["dumbbells"]),
        Case(said: "Nothing for legs today", day: .full, open: true, size: 2...7, lacksPatterns: ["squat"]),
        Case(said: "Give me a full body workout instead", day: .upper, open: true, size: 3...7,
             patterns: [["squat", "hinge"], ["push"], ["pull"]]),
        Case(said: "Give me a workout", day: .rest, open: true, size: 3...7, patterns: [["squat", "hinge"], ["push", "pull"]]),
        Case(said: "Plan me a pull day", day: .rest, open: true, size: 2...7, patterns: [["pull"]], lacksPatterns: ["push"]),
        Case(said: "Give me a 30 minute dumbbell workout", day: .rest, open: true, size: 3...6, equipment: ["dumbbells"]),
    ]

    // MARK: Fixtures

    private static let date = Date(timeIntervalSince1970: 1_791_000_000)

    private static func row(_ exercise: String, _ targets: [(String, Double)], note: String? = nil) -> PlannedWorkout {
        PlannedWorkout(date: date, session: "Workout", exercise: exercise,
                       targets: targets.map { Measurement(metric: $0.0, value: $0.1, unit: $0.0) }, note: note)
    }

    static func today(_ day: Day) -> [PlannedWorkout] {
        switch day {
        case .full:
            [row("deadlift", [("sets", 1), ("reps", 5), ("load_lb", 135)], note: TrainingGenerator.warmupNote),
             row("deadlift", [("sets", 3), ("reps", 5), ("load_lb", 200), ("rpe", 8)]),
             row("bench-press", [("sets", 3), ("reps", 5), ("load_lb", 140), ("rpe", 8)]),
             row("goblet-squat", [("sets", 3), ("reps", 10), ("load_lb_hand", 55)]),
             row("dead-bug", [("sets", 3), ("reps", 10)])]
        case .upper:
            [row("bench-press", [("sets", 4), ("reps", 5), ("load_lb", 155), ("rpe", 8)]),
             row("pull-up", [("sets", 3), ("reps", 8)]),
             row("dumbbell-row", [("sets", 3), ("reps", 10), ("load_lb_hand", 50)]),
             row("plank", [("sets", 3), ("duration_s", 45)])]
        case .rest: []
        }
    }

    /// The bundled exercise library, as the app seeds it.
    static func library() throws -> (names: [String: String], patterns: [String: String], catalog: [String: Exercise]) {
        let url = try #require(Bundle.main.url(forResource: "exercises", withExtension: "json"))
        let seeds = try JSONDecoder().decode([TemplateSeed].self, from: Data(contentsOf: url))
        let names = Dictionary(seeds.map { ($0.slug, $0.name) }, uniquingKeysWith: { first, _ in first })
        let patterns = Dictionary(seeds.compactMap { seed in Exercise(slug: seed.slug, attributes: seed.attributes).map { (seed.slug, $0.pattern) } },
                                  uniquingKeysWith: { first, _ in first })
        let catalog = Dictionary(seeds.compactMap { seed in Exercise(slug: seed.slug, attributes: seed.attributes).map { (seed.slug, $0) } },
                                 uniquingKeysWith: { first, _ in first })
        return (names, patterns, catalog)
    }

    // MARK: Scoring

    /// Why an edited workout fails its case; empty when it passes.
    static func failures(_ edited: [PlannedWorkout], for test: Case, catalog: [String: Exercise] = [:],
                         new: [TemplateSeed] = []) -> [String] {
        let before = today(test.day).filter { $0.note != TrainingGenerator.warmupNote }
        let after = edited.filter { $0.note != TrainingGenerator.warmupNote }
        let slugs = Set(after.map { singular($0.exercise) })
        let wanted = test.has.map { Set($0.split(separator: "|").map { singular(String($0)) }) }
        let named = wanted.reduce(into: Set(test.lacks + test.targets.keys)) { $0.formUnion($1) }
        var failures: [String] = []
        for group in wanted where group.isDisjoint(with: slugs) { failures.append("missing \(group.sorted().joined(separator: "|"))") }
        for slug in test.lacks where slugs.contains(slug) { failures.append("still has \(slug)") }
        let allowed = test.only ? named : named.union(before.map(\.exercise))
        if !test.open {
            for slug in slugs.sorted() where !allowed.contains(slug) { failures.append("added \(slug), not asked for") }
        }
        if !test.open && !test.only {
            for row in before where !named.contains(row.exercise) {
                guard let kept = after.first(where: { $0.exercise == row.exercise }) else {
                    failures.append("dropped \(row.exercise), not asked for")
                    continue
                }
                if kept.targets != row.targets { failures.append("changed \(row.exercise): \(dose(row)) → \(dose(kept))") }
            }
        }
        for (slug, target) in test.targets.sorted(by: { $0.key < $1.key }) {
            guard let row = after.first(where: { $0.exercise == slug }) else {
                failures.append("missing \(slug)")
                continue
            }
            func check(_ metric: String, _ expected: Double?) {
                if let expected, row.target(metric) != expected { failures.append("\(slug) \(metric) \(row.target(metric).map(Coach.number) ?? "none"), wanted \(Coach.number(expected))") }
            }
            check("sets", target.sets.map(Double.init))
            check("reps", target.reps.map(Double.init))
            check("duration_s", target.seconds.map(Double.init))
            if let pounds = target.pounds, (row.target("load_lb") ?? row.target("load_lb_hand")) != pounds {
                failures.append("\(slug) weight \(Proposal.dose(row)), wanted \(Coach.number(pounds))")
            }
        }
        // Open-ended properties.
        let exercises = order(after.map(\.exercise))
        if exercises.count != after.count { failures.append("an exercise is listed twice") }
        if let size = test.size, !size.contains(exercises.count) { failures.append("\(exercises.count) exercises, wanted \(size.lowerBound)–\(size.upperBound)") }
        if test.differs {
            let kept = before.filter { exercises.contains($0.exercise) }.count
            if kept * 2 > before.count { failures.append("kept \(kept) of \(before.count) exercises") }
        }
        func pattern(_ slug: String) -> String? {
            catalog[slug]?.pattern ?? new.first { $0.slug == slug }.flatMap { Exercise(slug: $0.slug, attributes: $0.attributes)?.pattern }
        }
        let trained = Set(exercises.compactMap(pattern))
        for group in test.patterns where trained.isDisjoint(with: group) { failures.append("nothing for \(group.joined(separator: "/"))") }
        for slug in exercises where test.lacksPatterns.contains(pattern(slug) ?? "") { failures.append("has \(slug) (\(pattern(slug)!))") }
        if let equipment = test.equipment {
            for slug in exercises {
                guard let exercise = catalog[slug] else { failures.append("\(slug) isn't in the library, so its equipment is unknown"); continue }
                if !exercise.equipment.isSubset(of: equipment) { failures.append("\(slug) needs \(exercise.equipment.subtracting(equipment).sorted().joined(separator: ", "))") }
            }
        }
        if let effort = test.effort {
            func work(_ rows: [PlannedWorkout]) -> Double {
                rows.reduce(0) { $0 + ($1.target("sets") ?? 1) * ($1.target("reps") ?? ($1.target("duration_s") ?? 30) / 3)
                                    * max($1.target("load_lb") ?? ($1.target("load_lb_hand") ?? 0) * 2, 40) }
            }
            let was = work(before), now = work(after)
            if effort == .harder && now <= was * 1.05 { failures.append("not harder (work \(Int(was)) → \(Int(now)))") }
            if effort == .easier && now >= was * 0.95 { failures.append("not easier (work \(Int(was)) → \(Int(now)))") }
        }
        return failures
    }

    private static func order(_ slugs: [String]) -> [String] { slugs.reduce(into: []) { if !$0.contains($1) { $0.append($1) } } }

    private static func dose(_ row: PlannedWorkout) -> String { Proposal.dose(row) }

    private static func singular(_ slug: String) -> String {
        slug.split(separator: "-").map { $0.count > 3 && $0.hasSuffix("s") && !$0.hasSuffix("ss") ? String($0.dropLast()) : String($0) }
            .joined(separator: "-")
    }

    // MARK: Run

    struct Run: Sendable {
        var failures: [String]
        var output: String
        var seconds: Double
    }

    /// The author's settings (fitness-planner config.yaml) and bundled history, so new exercises are dosed for real.
    static let settings = TrainingSettings(
        age: 36, daysPerWeek: 3, sessionMinutes: 45, trainingDays: [0, 2, 4], workoutTime: 7 * 60,
        equipment: ["barbell", "rack", "dumbbells", "pull_up_bar", "bench"], maxWeeklySets: 60,
        style: .powerbuilding, warmups: true, deloadEveryWeeks: 6)

    static func history(_ patterns: [String: String]) throws -> [LoggedSet] {
        try Seeder.decode([LogSeed].self, "history", .main).filter { $0.kind == .workout }.map {
            LoggedSet(date: $0.timestamp, exercise: $0.template ?? "", pattern: patterns[$0.template ?? ""], measurements: $0.measurements)
        }
    }

    static func run(_ test: Case, names: [String: String], patterns: [String: String], catalog: [String: Exercise],
                    history: [LoggedSet]) async -> Run {
        let start = Date.now
        func done(_ failures: [String], _ output: String) -> Run { Run(failures: failures, output: output, seconds: Date.now.timeIntervalSince(start)) }
        do {
            let request = try await TodayRequestParser.parse(test.said)
            guard request?.kind == .edit else { return done(["routed to \(request.map { "\($0.kind)" } ?? "nothing")"], "") }
            let today = today(test.day)
            let setup = TodayWorkout.Setup(names: names, catalog: catalog.values.sorted { $0.slug < $1.slug }, settings: settings,
                                           history: history, weeksSinceDeload: 1, date: today.first?.date ?? date, session: "Workout")
            let outcome = try await WorkoutAgent.run(test.said, today: today, setup: setup)
            let output = "\(outcome.summary) ⇐ \(outcome.calls.joined(separator: " · "))"
            guard outcome.changed else { return done(["nothing changed"], output) }
            return done(failures(outcome.workouts, for: test, catalog: catalog, new: outcome.newExercises), output)
        } catch {
            return done(["error: \(error)"], "")
        }
    }

    @Test func spokenEdits() async throws {
        try #require(SystemLanguageModel.default.isAvailable, "Apple Intelligence is off on this Mac")
        let environment = ProcessInfo.processInfo.environment
        let runs = Int(environment["EVAL_RUNS"] ?? "") ?? 3
        let filter = environment["EVAL_FILTER"].map { $0.lowercased() } ?? ""
        let selected = Self.cases.filter { filter.isEmpty || $0.said.lowercased().contains(filter) }
        let library = try Self.library()
        let history = try Self.history(library.patterns)
        var report: [String] = [], passed = 0, total = 0, seconds = 0.0
        for test in selected {
            var results: [Run] = []
            for _ in 0..<runs { results.append(await Self.run(test, names: library.names, patterns: library.patterns, catalog: library.catalog, history: history)) }
            let good = results.filter(\.failures.isEmpty).count
            passed += good
            total += results.count
            seconds += results.reduce(0) { $0 + $1.seconds }
            report.append("| \(good == runs ? "✅" : good == 0 ? "❌" : "🟡") \(good)/\(runs) | \(test.day.rawValue) | \(test.said) |")
            for (index, run) in results.enumerated() where !run.failures.isEmpty {
                report.append("|  | run \(index + 1) | \(run.failures.joined(separator: "; ")) — `\(run.output.replacingOccurrences(of: "|", with: "/"))` |")
            }
        }
        let header = ["# Spoken workout edit evals", "",
                      "**\(passed)/\(total) runs pass (\(total == 0 ? 0 : passed * 100 / total)%)** · \(selected.count) cases × \(runs) runs · "
                          + "\(String(format: "%.1f", total == 0 ? 0 : seconds / Double(total))) s per run", "",
                      "| Pass | Day | Said / why it failed |", "|---|---|---|"]
        for line in header + report { print("EVAL§ " + line) }
        // A score, not a gate: the run always passes so the report is always written.
    }
}
