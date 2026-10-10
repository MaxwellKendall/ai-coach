import Foundation
import FoundationModels
import Testing
@testable import AICoach

/// FIT-72: weeks designed by the real on-device model, over a grid of profiles and a 12-week program probe. Scored,
/// not gated: repairs PlanGuard made per week, distinct lineups, rep ranges by phase, goal fit and latency. Run with
/// `scripts/program-eval.sh [model]`, which writes Tests/Evals/program-results-<model>.md (FIT-92: any model).
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
        /// FIT-92: the strength goals, for where the probe's program plans each lift to end up.
        var targets: [ProgramScore.Target] = []
    }

    enum Goal: String, Sendable { case strength, fatLoss = "fat loss", general }

    private static let gym: Set<String> = ["barbell", "rack", "dumbbells", "pull_up_bar", "bench"]

    private static func settings(age: Int, days: [Int], minutes: Int, equipment: Set<String>, style: TrainingStyle,
                                 injured: [String] = [], starts: [StartingSet] = [], bodyWeight: Double = 190) -> TrainingSettings {
        var settings = TrainingSettings(age: age, daysPerWeek: days.count, sessionMinutes: minutes, trainingDays: days,
                                        workoutTime: 7 * 60, equipment: equipment, maxWeeklySets: 60, style: style, warmups: true,
                                        starts: starts)
        settings.injuredAreas = BodyArea.muscles(for: injured)
        settings.bodyWeight = bodyWeight
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
                history: true, goal: .strength, targets: [.init(exercise: "bench-press", pounds: 225), .init(exercise: "back-squat", pounds: 275)]),
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
                goal: .strength, targets: [.init(exercise: "deadlift", pounds: 405)]),
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
    private static let monday = Week.start(of: calendar.date(from: DateComponents(year: 2026, month: 7, day: 20))!, calendar: calendar)

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

    /// FIT-73: weighted exercises planned without a load.
    private static func missingLoads(_ week: TrainingWeek, catalog: [String: Exercise]) -> [String] {
        working(week).filter { row in
            guard let exercise = catalog[row.exercise], !exercise.isTimed,
                  !exercise.equipment.isDisjoint(with: ProgramDesigner.loadBearing) else { return false }
            return row.target("load_lb") == nil && row.target("load_lb_hand") == nil
        }.map(\.exercise)
    }

    private static func summary(_ result: ProgramDesigner.Result) -> String {
        let rules = Dictionary(result.repairs.map { ($0.rule.rawValue, 1) }, uniquingKeysWith: +).sorted { $0.key < $1.key }
            .map { "\($0.value) \($0.key)" }.joined(separator: ", ")
        return "\(result.source == .model ? "model" : "⚠️ fallback (\(result.fallbackReason ?? ""))") · \(String(format: "%.1f", result.seconds)) s · "
            + "\(working(result.week).reduce(0) { $0 + Int($1.target("sets") ?? 0) }) sets · "
            + "\(result.repairs.count) repairs\(rules.isEmpty ? "" : " (\(rules))") · \(result.calls.count) tool calls"
    }

    // MARK: The probe

    struct Probe {
        var profile: Profile
        var program: [ProgramWeek]
        /// FIT-95: the program brief the weeks were designed within, and the goals they worked toward.
        var brief: ProgramBrief?
        var lifts: [GoalLift]
        var results: [ProgramDesigner.Result]
        /// FIT-100: each hard week's decided top sets, and what decided them.
        var decisions: [Progression.Decision] = []
        var decider: (any ProgressionDecider)?
        var weeks: [TrainingWeek] { results.map(\.week) }
        var light: [Bool] { program.map(\.light) }
    }

    /// A whole program for one profile: its brief first (FIT-95), then each week planned from the last one, and logged
    /// like a person (FIT-97).
    private static func probe(_ profile: Profile, weeks count: Int, inputs: Inputs, model: any AIModel,
                              briefModel: any AIModel) async -> Probe {
        let bySlug = Dictionary(inputs.catalog.map { ($0.slug, $0) }, uniquingKeysWith: { a, _ in a })
        let tier = AgeTier.of(age: profile.settings.age)
        let program = ProgramPlan.weeks(count: count, deloadEvery: profile.settings.deloadEveryWeeks ?? tier.deloadEveryWeeks)
        var history = profile.history ? inputs.history : [], last: [PlannedWorkout] = [], results: [ProgramDesigner.Result] = []
        let since = calendar.date(byAdding: .day, value: -56, to: monday)!
        let lifts = profile.targets.map { target in
            let start = GoalProgress.current("\(target.exercise).1rm_lb", sets: history, weighIns: [], since: since)
                ?? profile.settings.starts.first { $0.exercise == target.exercise }.flatMap { start in
                    start.value("load_lb").flatMap { load in start.value("reps").map { ProgramPlan.estimatedMax(load: load, reps: $0) } }
                }
                ?? target.pounds * 0.8
            return GoalLift(exercise: target.exercise, measure: "1rm_lb", start: start, target: target.pounds, deadline: nil)
        }
        let brief = await ProgramBrief.write(ProgramBrief.Request(settings: profile.settings, catalog: inputs.catalog, names: inputs.names,
                                                                  goals: profile.goals, goalLifts: lifts, weeks: program), model: briefModel)
        let decider = EvalModel.decider(tier: tier)
        var decisions: [Progression.Decision] = []
        for (index, week) in program.enumerated() {
            var request = ProgramDesigner.Request(
                monday: ProgramPlan.monday(index, start: monday, calendar: calendar), settings: profile.settings,
                catalog: inputs.catalog, names: inputs.names, history: history, weeksSinceDeload: 1, program: week,
                programIndex: index, programWeeks: count, goals: profile.goals, lastWeek: last,
                brief: brief?.phase(week.phase), goalLifts: lifts, programPlan: program, calendar: calendar)
            // FIT-100: hard weeks' main lifts decided first, as `Planner.design` does (FIT-101).
            if let decider {
                request.progression = await Progression.decided(request, by: decider)
                decisions += request.progression
            }
            let result = await ProgramDesigner.week(request, model: model)
            results.append(result)
            history += ProbeLog.log(result.week, index: index, patterns: bySlug.mapValues(\.pattern))
            last = result.week.workouts
        }
        return Probe(profile: profile, program: program, brief: brief, lifts: lifts, results: results, decisions: decisions, decider: decider)
    }

    private static func percent(_ share: Double) -> String { "\(Int((share * 100).rounded()))%" }

    /// "Bench Press 208 → 236 of 225 (105%)".
    private static func tracks(_ probe: Probe, names: [String: String]) -> [String] {
        probe.profile.targets.map { target in
            let track = ProgramScore.track(probe.weeks, light: probe.light, target: target)
            let name = names[target.exercise] ?? target.exercise
            guard let end = track.end, let share = track.share else { return "\(name): not planned" }
            return "\(name) \(track.start.map { Coach.number($0.rounded()) + " → " } ?? "")\(Coach.number(end.rounded())) of \(Coach.number(target.pounds)) (\(percent(share)))"
        }
    }

    // MARK: Runs

    @Test func designedWeeks() async throws {
        let model = EvalModel.current(), briefModel = EvalModel.brief()
        try #require(model.isAvailable, Comment(rawValue: EvalModel.unavailable(model)))
        try #require(briefModel.isAvailable, Comment(rawValue: EvalModel.unavailable(briefModel)))
        let environment = ProcessInfo.processInfo.environment
        let weeks = Int(environment["EVAL_WEEKS"] ?? "") ?? 12
        let filter = environment["EVAL_FILTER"].map { $0.lowercased() } ?? ""
        let inputs = try Self.inputs()
        let bySlug = Dictionary(inputs.catalog.map { ($0.slug, $0) }, uniquingKeysWith: { a, _ in a })
        var report: [String] = []
        var all: [ProgramDesigner.Result] = []

        // The grid: one week each.
        var grid: [String] = [], fit: [String] = [], firstLoads: [String] = []
        for profile in Self.profiles where filter.isEmpty || profile.name.lowercased().contains(filter) {
            let result = await ProgramDesigner.week(ProgramDesigner.Request(
                monday: Self.monday, settings: profile.settings, catalog: inputs.catalog, names: inputs.names,
                history: profile.history ? inputs.history : [], weeksSinceDeload: 1, program: profile.program,
                goals: profile.goals, calendar: Self.calendar), model: model)
            all.append(result)
            grid.append("### \(profile.name)\n\n\(Self.summary(result))\n")
            grid += Self.render(result.week, names: inputs.names).map { "- \($0)" }
            if !result.repairs.isEmpty { grid.append("\nRepairs: " + result.repairs.map(\.text).joined(separator: " · ")) }
            let missing = Self.missingLoads(result.week, catalog: bySlug)
            if !missing.isEmpty { grid.append("\nNo load: " + missing.map { inputs.names[$0] ?? $0 }.joined(separator: ", ")) }
            firstLoads.append("| \(profile.name) | \(result.source.rawValue) | \(Self.working(result.week).filter { $0.target("load_lb") != nil || $0.target("load_lb_hand") != nil }.count) | \(missing.count) | \(result.repairs.filter { $0.rule == .load }.count) |")
            if !result.why.isEmpty { grid.append("\nWhy: " + result.why.prefix(6).joined(separator: " · ")) }
            grid.append("")
            let main = Self.median(Self.reps(result.week, main: true)), accessory = Self.median(Self.reps(result.week, main: false))
            fit.append("| \(profile.name) | \(profile.goal.rawValue) | \(main.map(Coach.number) ?? "–") | \(accessory.map(Coach.number) ?? "–") | "
                       + "\(Self.conditioning(result.week, catalog: bySlug)) |")
        }

        // The probe: a whole program for each of EVAL_PROBE's profiles (the author by default).
        var probes: [Probe] = []
        if weeks > 0, filter.isEmpty || "probe".contains(filter) {
            let tokens = (environment["EVAL_PROBE"].flatMap { $0.isEmpty ? nil : $0 } ?? "author").lowercased()
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            for token in tokens {
                guard let profile = Self.profiles.first(where: { $0.name.lowercased().contains(token) }) else { continue }
                let probe = await Self.probe(profile, weeks: weeks, inputs: inputs, model: model, briefModel: briefModel)
                probes.append(probe)
                all += probe.results
            }
        }

        let designed = all.filter { $0.source == .model }
        let seconds = designed.map(\.seconds)
        let repairs = designed.isEmpty ? 0 : Double(designed.reduce(0) { $0 + $1.repairs.count }) / Double(designed.count)
        let average = seconds.isEmpty ? 0 : seconds.reduce(0, +) / Double(seconds.count)
        let copies = all.flatMap { ProgramScore.copiedSessions($0.week) }
        let odd = all.flatMap { ProgramScore.oddItems($0.week, catalog: bySlug, names: inputs.names) }
        let decider = probes.first?.decider
        let decisions = probes.flatMap(\.decisions)
        report.append("# Program designer evals: weeks by \(model.name), brief by \(briefModel.name)\(decider.map { ", decisions by \($0.name)" } ?? "")")
        report.append("")
        var headline = "**\(designed.count)/\(all.count) weeks designed by the model** · "
        headline += "\(String(format: "%.1f", repairs)) repairs per week · \(String(format: "%.0f", average)) s per week "
        headline += "(slowest \(String(format: "%.0f", seconds.max() ?? 0)) s)"
        let weekCost = EvalModel.cost(model), briefCost = EvalModel.cost(briefModel)
        headline += " · weeks \(EvalModel.dollars(weekCost)), briefs \(EvalModel.dollars(briefCost))"
        if let usage = EvalModel.usage(model) { headline += " · weeks: " + usage }
        if let usage = EvalModel.usage(briefModel) { headline += " · briefs: " + usage }
        report.append(headline)
        // A decider's cost: the Decisions API bills input only; the rule table is free.
        let decisionCost = probes.compactMap { $0.decider as? OpenAIDecisions }.reduce(0) { $0 + $1.cost }
        if decider != nil {
            let counts = Progression.Step.allCases.map { step in "\(decisions.filter { $0.step == step }.count) \(step.rawValue.replacingOccurrences(of: "_", with: " "))" }
            report.append("\nDecisions: \(counts.joined(separator: ", ")) · \(EvalModel.dollars(decisionCost))")
        }
        let rules = Dictionary(designed.flatMap(\.repairs).map { ($0.rule.rawValue, 1) }, uniquingKeysWith: +).sorted { $0.value > $1.value }
        if !rules.isEmpty { report.append("\nRepairs by rule: " + rules.map { "\($0.key) \($0.value)" }.joined(separator: ", ")) }
        report.append("\nCopied sessions: \(copies.isEmpty ? "none" : copies.joined(separator: ", ")) · "
                      + "Odd items: \(odd.isEmpty ? "none" : odd.joined(separator: ", "))")

        // FIT-92: the program as a whole.
        var progressions: [ProgramScore.Progression] = [], goals: [String] = [], deloads = (lighter: 0, of: 0)
        var shares: [Double] = [], briefProblems: [String] = []
        var changes: [String: [Double]] = [:]
        if !probes.isEmpty {
            report.append("\n## Programs\n")
            report.append("| Profile | Distinct lineups | Main lifts up · held · dropped | Rises over 10% | Goals: planned estimate | Deloads lighter | Exercises changed between phases | Brief problems |")
            report.append("|---|---|---|---|---|---|---|---|")
            for probe in probes {
                let progression = ProgramScore.progression(probe.weeks, light: probe.light, names: inputs.names)
                let deload = ProgramScore.deloads(probe.weeks, light: probe.light)
                let phase = ProgramScore.phaseChanges(probe.weeks, phases: probe.program.map(\.phase), light: probe.light)
                let track = Self.tracks(probe, names: inputs.names)
                let problems = ProgramScore.briefProblems(probe.brief, weeks: probe.program, goalLifts: probe.lifts.map(\.exercise),
                                                          catalog: bySlug, names: inputs.names, equipment: probe.profile.settings.equipment)
                briefProblems += problems.map { "\(probe.profile.name.split(separator: ":")[0]): \($0)" }
                shares += probe.profile.targets.compactMap { ProgramScore.track(probe.weeks, light: probe.light, target: $0).share ?? 0 }
                progressions.append(progression)
                goals += track
                deloads = (deloads.lighter + deload.lighter, deloads.of + deload.of)
                for (name, change) in phase { changes[name, default: []].append(change) }
                report.append("| \(probe.profile.name) | \(Set(probe.weeks.map(Self.lineup)).count) of \(probe.weeks.count) | "
                              + "\(progression.up) · \(progression.held) · \(progression.down) | "
                              + "\(progression.jumps.isEmpty ? "none" : progression.jumps.joined(separator: ", ")) | "
                              + "\(track.isEmpty ? "–" : track.joined(separator: "; ")) | \(deload.lighter) of \(deload.of) | "
                              + "\(phase.isEmpty ? "–" : phase.map { "\($0.0) \(Self.percent($0.1))" }.joined(separator: ", ")) | "
                              + "\(problems.isEmpty ? "none" : problems.joined(separator: "; ")) |")
            }
            for probe in probes {
                report.append("\n## 12-week probe: \(probe.profile.name)\n")
                report.append(ProbeLog.description + "\n")
                if let brief = probe.brief {
                    report.append("Brief by \(briefModel.name):\n")
                    report += brief.phases.map { "- **\($0.phase)**: \($0.focus). Main lifts: \($0.mainLifts.joined(separator: ", ")), \($0.mainReps) reps; the rest \($0.accessoryReps)." }
                    report.append("")
                } else {
                    report.append("No brief: the model couldn't write one.\n")
                }
                var phases: [String: (main: [Double], accessory: [Double])] = [:]
                for (week, result) in zip(probe.program, probe.results) {
                    let phase = week.light ? "light" : week.phase.rawValue
                    phases[phase, default: ([], [])].main += Self.reps(result.week, main: true)
                    phases[phase, default: ([], [])].accessory += Self.reps(result.week, main: false)
                }
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
                for (index, (week, result)) in zip(probe.program, probe.results).enumerated() {
                    report.append("**Week \(index + 1), \(ProgramPlan.title(week))** · \(Self.summary(result))")
                    report += Self.render(result.week, names: inputs.names).map { "- \($0)" }
                    report.append("")
                }
            }
        }
        if !grid.isEmpty {
            report.append("## First loads\n")
            report.append("| Profile | Source | Loaded sets | Weighted with no load | Loads cut to a ceiling |")
            report.append("|---|---|---|---|---|")
            report += firstLoads
            report.append("")
            report.append("## Goal fit\n")
            report.append("| Profile | Goal | Main reps | Accessory reps | Conditioning, carries or supersets |")
            report.append("|---|---|---|---|---|")
            report += fit
            report.append("\n## Profiles\n")
            report += grid
        }

        // One row for Tests/Evals/program-compare.md, which scripts/program-eval.sh builds from every model's results.
        let up = progressions.reduce(0) { $0 + $1.up }, held = progressions.reduce(0) { $0 + $1.held }
        let down = progressions.reduce(0) { $0 + $1.down }, jumps = progressions.reduce(0) { $0 + $1.jumps.count }
        let changed = ["base→build", "build→peak"].compactMap { name in
            changes[name].map { "\(name) \(Self.percent($0.reduce(0, +) / Double($0.count)))" }
        }
        // FIT-98: the verdicts, and what each job costs.
        let run = ProgramScore.Run(weeks: all.count, byModel: designed.count, repairsPerWeek: repairs, copies: copies.count, odd: odd.count,
                                   progression: ProgramScore.Progression(up: up, held: held, down: down), goalShares: shares, deloads: deloads)
        let weekFailures = probes.isEmpty ? ["no probe"] : ProgramScore.weekFailures(run)
        if probes.isEmpty { briefProblems = ["no probe"] }
        func verdict(_ failures: [String]) -> String { failures.isEmpty ? "✅ passes" : "❌ " + failures.joined(separator: "; ") }
        report.insert(contentsOf: ["", "**Week design: \(verdict(weekFailures))**", "", "**Brief: \(verdict(briefProblems))**"], at: 3)
        let perWeek = weekCost.map { $0 / Double(max(1, all.count)) }, perBrief = briefCost.map { $0 / Double(max(1, probes.count)) }
        let decidedWeeks = probes.reduce(0) { total, probe in total + probe.program.filter { !$0.light }.count }
        let cells = [model.name, briefModel.name, decider?.name ?? "none", verdict(weekFailures), verdict(briefProblems), EvalModel.dollars(perWeek.map { $0 + decisionCost / Double(max(1, decidedWeeks)) }), EvalModel.dollars(perBrief),
                     "\(designed.count)/\(all.count)", String(format: "%.1f", repairs), String(format: "%.0f s", average),
                     "\(copies.count)", "\(odd.count)", probes.isEmpty ? "–" : "\(up) · \(held) · \(down)", probes.isEmpty ? "–" : "\(jumps)",
                     goals.isEmpty ? "–" : goals.joined(separator: "; "), deloads.of == 0 ? "–" : "\(deloads.lighter) of \(deloads.of)",
                     changed.isEmpty ? "–" : changed.joined(separator: ", "), EvalModel.usage(model) ?? "–"]
        report.append("\n<!-- compare: | \(cells.joined(separator: " | ")) | -->")
        for line in report.joined(separator: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            print("PROGRAM§ " + line)
        }
        // A score, not a gate: the run always passes so the report is always written.
    }
}
