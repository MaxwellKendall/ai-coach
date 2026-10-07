import Foundation
import FoundationModels
import Testing
@testable import AICoach

/// FIT-72: weeks designed by the real on-device model, over a grid of profiles and a 12-week program probe. Scored,
/// not gated: repairs PlanGuard made per week, distinct lineups, rep ranges by phase, goal fit and latency. Run with
/// `scripts/program-eval.sh`, which writes Tests/Evals/program-results.md.
struct ProgramDesignerEvals {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    struct Profile: Sendable {
        var name: String
        var settings: TrainingSettings
        var goals: [String]
        var program: ProgramWeek?
        var history: Bool
        /// Fat loss wants more reps and conditioning; strength wants heavy low-rep main lifts.
        var goal: Goal
    }

    enum Goal: String, Sendable { case strength, fatLoss = "fat loss", general }

    private static let gym: Set<String> = ["barbell", "rack", "dumbbells", "pull_up_bar", "bench"]

    private static func settings(age: Int, days: [Int], minutes: Int, equipment: Set<String>, style: TrainingStyle,
                                 injured: [String] = [], starts: [StartingSet] = []) -> TrainingSettings {
        var settings = TrainingSettings(age: age, daysPerWeek: days.count, sessionMinutes: minutes, trainingDays: days,
                                        workoutTime: 7 * 60, equipment: equipment, maxWeeklySets: 60, style: style, warmups: true,
                                        starts: starts)
        settings.injuredAreas = BodyArea.muscles(for: injured)
        return settings
    }

    private static func start(_ exercise: String, _ load: Double?, _ reps: Double) -> StartingSet {
        StartingSet(exercise: exercise, measurements: [load.map { Measurement(metric: "load_lb", value: $0, unit: "lb") },
                                                       Measurement(metric: "reps", value: reps, unit: "reps")].compactMap { $0 })
    }

    static let profiles: [Profile] = [
        Profile(name: "The author: 3 days, gym, build week",
                settings: settings(age: 36, days: [0, 2, 4], minutes: 45, equipment: gym, style: .powerbuilding),
                goals: ["Bench Press 225 lb by Dec 1", "Back Squat 275 lb by Dec 1"], program: ProgramWeek(phase: .build, kind: .build),
                history: true, goal: .strength),
        Profile(name: "The author, travelling",
                settings: settings(age: 36, days: [0, 2, 4], minutes: 45, equipment: gym, style: .powerbuilding),
                goals: ["Bench Press 225 lb by Dec 1"], program: ProgramWeek(phase: .base, kind: .base, travel: true),
                history: true, goal: .strength),
        Profile(name: "The author, deload",
                settings: settings(age: 36, days: [0, 2, 4], minutes: 45, equipment: gym, style: .powerbuilding),
                goals: ["Bench Press 225 lb by Dec 1"], program: ProgramWeek(phase: .build, kind: .deload),
                history: true, goal: .strength),
        Profile(name: "New, fat loss: 3 days, dumbbells at home",
                settings: settings(age: 29, days: [0, 2, 4], minutes: 45, equipment: ["dumbbells", "bench"], style: .functional,
                                   starts: [start("push-up", nil, 15), start("goblet-squat", 40, 10)]),
                goals: ["Body weight 180 lb by March 1 (now 205)"], program: ProgramWeek(phase: .base, kind: .base),
                history: false, goal: .fatLoss),
        Profile(name: "New, strength: 4 days, gym, peak",
                settings: settings(age: 45, days: [0, 1, 3, 4], minutes: 60, equipment: gym, style: .powerlifting,
                                   starts: [start("back-squat", 245, 5), start("bench-press", 185, 5), start("deadlift", 315, 5)]),
                goals: ["Deadlift 405 lb by Feb 1"], program: ProgramWeek(phase: .peak, kind: .peak), history: false,
                goal: .strength),
        Profile(name: "New, muscle: 5 days, full gym",
                settings: settings(age: 25, days: [0, 1, 2, 3, 4], minutes: 60, equipment: Set(AICoach.Profile.allEquipment),
                                   style: .hypertrophy, starts: [start("bench-press", 135, 8), start("back-squat", 155, 8)]),
                goals: [], program: nil, history: false, goal: .general),
        Profile(name: "New, 58, bad knees: 2 days, bands and bodyweight",
                settings: settings(age: 58, days: [1, 4], minutes: 30, equipment: ["bands", "pull_up_bar"], style: .functional,
                                   injured: ["knees"]),
                goals: ["Walk 5 miles by June"], program: ProgramWeek(phase: .base, kind: .base), history: false, goal: .general),
    ]

    // MARK: Inputs

    struct Inputs: Sendable {
        var catalog: [Exercise]
        var names: [String: String]
        var history: [LoggedSet]
    }

    static func inputs() throws -> Inputs {
        let seeds = try Seeder.decode([TemplateSeed].self, "exercises", .main)
        let catalog = seeds.compactMap { Exercise(slug: $0.slug, attributes: $0.attributes) }
        let patterns = Dictionary(uniqueKeysWithValues: catalog.map { ($0.slug, $0.pattern) })
        let history = try Seeder.decode([LogSeed].self, "history", .main).filter { $0.kind == .workout }.map {
            LoggedSet(date: $0.timestamp, exercise: $0.template ?? "", pattern: patterns[$0.template ?? ""], measurements: $0.measurements)
        }
        return Inputs(catalog: catalog, names: Dictionary(seeds.map { ($0.slug, $0.name) }, uniquingKeysWith: { a, _ in a }),
                      history: history)
    }

    /// The week after the imported history ends.
    private static let monday = Week.monday(of: calendar.date(from: DateComponents(year: 2026, month: 7, day: 20))!, calendar: calendar)

    // MARK: Reading a week

    private static func working(_ week: TrainingWeek) -> [PlannedWorkout] {
        week.workouts.filter { $0.note != TrainingGenerator.warmupNote }
    }

    private static func render(_ week: TrainingWeek, names: [String: String]) -> [String] {
        Dictionary(grouping: working(week), by: \.date).sorted { $0.key < $1.key }.map { _, rows in
            let day = ProgramDesigner.weekdays[(calendar.component(.weekday, from: rows[0].date) + 5) % 7]
            return "\(day) \(rows[0].session): " + rows.map { "\($0.main ? "**" : "")\(names[$0.exercise] ?? $0.exercise)\($0.main ? "**" : "") \(Proposal.dose($0))" }
                .joined(separator: ", ")
        }
    }

    /// Each session's exercises, as a set: two weeks with the same lineups did the same exercises.
    private static func lineup(_ week: TrainingWeek) -> String {
        Dictionary(grouping: working(week), by: \.date).sorted { $0.key < $1.key }
            .map { $0.value.map(\.exercise).sorted().joined(separator: "+") }.joined(separator: " | ")
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private static func reps(_ week: TrainingWeek, main: Bool) -> [Double] {
        working(week).filter { $0.main == main }.compactMap { $0.target("reps") }
    }

    private static func conditioning(_ week: TrainingWeek, catalog: [String: Exercise]) -> Int {
        working(week).filter { ["conditioning", "carry"].contains(catalog[$0.exercise]?.pattern ?? "") || $0.group != nil }.count
    }

    private static func summary(_ result: ProgramDesigner.Result) -> String {
        let rules = Dictionary(result.repairs.map { ($0.rule.rawValue, 1) }, uniquingKeysWith: +).sorted { $0.key < $1.key }
            .map { "\($0.value) \($0.key)" }.joined(separator: ", ")
        return "\(result.source == .model ? "model" : "⚠️ fallback (\(result.fallbackReason ?? ""))") · \(String(format: "%.1f", result.seconds)) s · "
            + "\(working(result.week).reduce(0) { $0 + Int($1.target("sets") ?? 0) }) sets · "
            + "\(result.repairs.count) repairs\(rules.isEmpty ? "" : " (\(rules))") · \(result.calls.count) tool calls"
    }

    // MARK: Runs

    @Test func designedWeeks() async throws {
        try #require(SystemLanguageModel.default.isAvailable, "Apple Intelligence is off on this Mac")
        let environment = ProcessInfo.processInfo.environment
        let weeks = Int(environment["EVAL_WEEKS"] ?? "") ?? 12
        let filter = environment["EVAL_FILTER"].map { $0.lowercased() } ?? ""
        let inputs = try Self.inputs()
        let bySlug = Dictionary(inputs.catalog.map { ($0.slug, $0) }, uniquingKeysWith: { a, _ in a })
        var report: [String] = []
        var all: [ProgramDesigner.Result] = []

        // The grid: one week each.
        var grid: [String] = [], fit: [String] = []
        for profile in Self.profiles where filter.isEmpty || profile.name.lowercased().contains(filter) {
            let result = await ProgramDesigner.week(ProgramDesigner.Request(
                monday: Self.monday, settings: profile.settings, catalog: inputs.catalog, names: inputs.names,
                history: profile.history ? inputs.history : [], weeksSinceDeload: 1, program: profile.program,
                goals: profile.goals, calendar: Self.calendar))
            all.append(result)
            grid.append("### \(profile.name)\n\n\(Self.summary(result))\n")
            grid += Self.render(result.week, names: inputs.names).map { "- \($0)" }
            if !result.repairs.isEmpty { grid.append("\nRepairs: " + result.repairs.map(\.text).joined(separator: " · ")) }
            if !result.why.isEmpty { grid.append("\nWhy: " + result.why.prefix(6).joined(separator: " · ")) }
            grid.append("")
            let main = Self.median(Self.reps(result.week, main: true)), accessory = Self.median(Self.reps(result.week, main: false))
            fit.append("| \(profile.name) | \(profile.goal.rawValue) | \(main.map(Coach.number) ?? "–") | \(accessory.map(Coach.number) ?? "–") | "
                       + "\(Self.conditioning(result.week, catalog: bySlug)) |")
        }

        // The probe: the author's program, each week planned from the last one, logged as planned.
        var probe: [String] = [], lineups: [String] = [], phases: [String: (main: [Double], accessory: [Double])] = [:]
        let author = Self.profiles[0]
        if weeks > 0, filter.isEmpty || "probe".contains(filter) {
            let program = ProgramPlan.weeks(count: weeks, deloadEvery: 6)
            var history = inputs.history, last: [PlannedWorkout] = []
            for (index, week) in program.enumerated() {
                let monday = ProgramPlan.monday(index, start: Self.monday, calendar: Self.calendar)
                let result = await ProgramDesigner.week(ProgramDesigner.Request(
                    monday: monday, settings: author.settings, catalog: inputs.catalog, names: inputs.names, history: history,
                    weeksSinceDeload: 1, program: week, programIndex: index, programWeeks: weeks, goals: author.goals,
                    lastWeek: last, calendar: Self.calendar))
                all.append(result)
                lineups.append(Self.lineup(result.week))
                let phase = week.light ? "light" : week.phase.rawValue
                phases[phase, default: ([], [])].main += Self.reps(result.week, main: true)
                phases[phase, default: ([], [])].accessory += Self.reps(result.week, main: false)
                probe.append("**Week \(index + 1), \(ProgramPlan.title(week))** · \(Self.summary(result))")
                probe += Self.render(result.week, names: inputs.names).map { "- \($0)" }
                probe.append("")
                // Done as planned.
                for row in Self.working(result.week) {
                    for _ in 0..<Int(row.target("sets") ?? 0) {
                        history.append(LoggedSet(date: row.date, exercise: row.exercise, pattern: bySlug[row.exercise]?.pattern,
                                                 measurements: row.targets.filter { $0.metric != "sets" }))
                    }
                }
                last = result.week.workouts
            }
        }

        let model = all.filter { $0.source == .model }
        let seconds = model.map(\.seconds)
        report.append("# Program designer evals")
        report.append("")
        report.append("**\(model.count)/\(all.count) weeks designed by the model** · "
                      + "\(String(format: "%.1f", model.isEmpty ? 0 : Double(model.reduce(0) { $0 + $1.repairs.count }) / Double(model.count))) repairs per week · "
                      + "\(String(format: "%.0f", seconds.isEmpty ? 0 : seconds.reduce(0, +) / Double(seconds.count))) s per week "
                      + "(slowest \(String(format: "%.0f", seconds.max() ?? 0)) s)")
        let rules = Dictionary(model.flatMap(\.repairs).map { ($0.rule.rawValue, 1) }, uniquingKeysWith: +).sorted { $0.value > $1.value }
        if !rules.isEmpty { report.append("\nRepairs by rule: " + rules.map { "\($0.key) \($0.value)" }.joined(separator: ", ")) }
        if !lineups.isEmpty {
            report.append("\n## 12-week probe\n")
            report.append("\(Set(lineups).count) distinct lineups in \(lineups.count) weeks.\n")
            report.append("| Phase | Main reps (median, range) | Accessory reps (median, range) |")
            report.append("|---|---|---|")
            for phase in ["base", "build", "peak", "light"] {
                guard let reps = phases[phase] else { continue }
                func describe(_ values: [Double]) -> String {
                    guard let median = Self.median(values) else { return "–" }
                    return "\(Coach.number(median)) (\(Coach.number(values.min()!))–\(Coach.number(values.max()!)))"
                }
                report.append("| \(phase) | \(describe(reps.main)) | \(describe(reps.accessory)) |")
            }
            report.append("")
            report += probe
        }
        if !grid.isEmpty {
            report.append("## Goal fit\n")
            report.append("| Profile | Goal | Main reps | Accessory reps | Conditioning, carries or supersets |")
            report.append("|---|---|---|---|---|")
            report += fit
            report.append("\n## Profiles\n")
            report += grid
        }
        for line in report.joined(separator: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            print("PROGRAM§ " + line)
        }
        // A score, not a gate: the run always passes so the report is always written.
    }
}
