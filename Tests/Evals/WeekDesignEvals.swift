import Foundation
import FoundationModels
import Testing
@testable import AICoach

/// FIT-426: the money case. A Pro lifter's week designed by the AI from the program's shape, their goals, their notes
/// and how last week went, against the week code plans (mode 1, the baseline), on the author's real history and five
/// scripted ones. Scored by code (the outline kept, the decided top sets, equipment, pain, PlanGuard's rules, changes
/// explained) and by a judge reading both weeks blind. Passes when the AI week wins the judge clearly and never loses a
/// code check the baseline passes. Run with `scripts/week-eval.sh [designer] [judge]`, which writes
/// Tests/Evals/week-results-<designer>.md.
struct WeekDesignEvals {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    /// The week after the imported history ends, and the one before it, which each scenario logs its own way.
    private static let monday = Week.start(of: calendar.date(from: DateComponents(year: 2026, month: 7, day: 20))!, calendar: calendar)
    private static let lastMonday = calendar.date(byAdding: .day, value: -7, to: monday)!

    enum Twist: String, CaseIterable, Sendable {
        case real = "Real history: last week done as planned"
        case missed = "A missed week: nothing logged last week"
        case stalled = "A stalled lift: bench short of its reps at RPE 10"
        case pain = "A pain note: knee sore at the bottom of squats"
        case travel = "Travel: a hotel week, dumbbells only"
        case pr = "A PR week: bench and squat easy, two reps over"
    }

    struct Scenario: Sendable {
        var twist: Twist
        var request: ProgramDesigner.Request
        /// Last week's planned top load of each main lift, for the pain check.
        var lastTop: [String: Double]
    }

    // MARK: Scenarios

    private static func scenario(_ twist: Twist, inputs: ProgramDesignerEvals.Inputs) async -> Scenario {
        let author = ProgramDesignerEvals.profiles[0]
        let settings = author.settings
        let tier = AgeTier.of(age: settings.age)
        let program = ProgramPlan.weeks(count: 12, deloadEvery: tier.deloadEveryWeeks)
        // Week 5 of 12, a hard week; travel makes it a hotel week of the same kind.
        let index = program.indices.first { $0 >= 4 && !program[$0].light } ?? 4
        var week = program[index]
        if twist == .travel { week.travel = true }
        let before = inputs.history.filter { $0.date < lastMonday }
        let planned = TrainingGenerator.week(startingOn: lastMonday, settings: settings, catalog: inputs.catalog, history: before,
                                             weeksSinceDeload: 1, program: program[index - 1], calendar: calendar).workouts
        let bySlug = Dictionary(inputs.catalog.map { ($0.slug, $0) }, uniquingKeysWith: { a, _ in a })
        var notes: [String] = []
        let logged: [LoggedSet] = twist == .missed ? [] : planned.filter { $0.note != TrainingGenerator.warmupNote }.flatMap { row -> [LoggedSet] in
            let sets = Int(row.target("sets") ?? 0)
            return (0..<sets).map { set in
                var measurements = row.targets.filter { $0.metric != "sets" }
                func change(_ metric: String, _ value: (Double) -> Double) {
                    measurements = measurements.map { $0.metric == metric ? Measurement(metric: metric, value: value($0.value), unit: $0.unit) : $0 }
                }
                switch twist {
                case .stalled where row.exercise == "bench-press" && row.main && set >= sets - 2:
                    change("reps") { max(1, $0 - 2) }
                    measurements = measurements.filter { $0.metric != "rpe" } + [Measurement(metric: "rpe", value: 10, unit: "RPE")]
                case .pr where row.main && ["bench-press", "back-squat"].contains(row.exercise):
                    change("reps") { $0 + 2 }
                    measurements = measurements.filter { $0.metric != "rpe" } + [Measurement(metric: "rpe", value: 7, unit: "RPE")]
                default: break
                }
                return LoggedSet(date: row.date.addingTimeInterval(3600), exercise: row.exercise, pattern: bySlug[row.exercise]?.pattern,
                                 measurements: measurements)
            }
        }
        let thursday = calendar.date(byAdding: .day, value: 4, to: lastMonday)!
        switch twist {
        case .stalled: notes = ["Wed Jul 15, Bench Press: couldn't finish the last two sets, shoulders felt beat up"]
        case .pain: notes = ["Thu Jul 16, Back Squat: knee sore at the bottom, worse on the last set",
                             "Sat Jul 18, check-in: knee still a bit sore going down stairs"]
        case .travel: notes = ["Sun Jul 19, check-in: travelling all next week, hotel gym with dumbbells only"]
        case .pr: notes = ["\(thursday.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())), Bench Press: felt easy, could have done more"]
        default: break
        }
        let history = before + logged
        let since = calendar.date(byAdding: .day, value: -56, to: monday)!
        let lifts = author.targets.map { target in
            GoalLift(exercise: target.exercise, measure: "1rm_lb",
                     start: GoalProgress.current("\(target.exercise).1rm_lb", sets: history, weighIns: [], since: since) ?? target.pounds * 0.8,
                     target: target.pounds, deadline: nil)
        }
        let outline = TrainingGenerator.week(startingOn: monday, settings: settings, catalog: inputs.catalog, history: history,
                                             weeksSinceDeload: Training.weeksSinceDeload(history, before: monday, calendar: calendar),
                                             program: week, calendar: calendar).workouts
        var request = ProgramDesigner.Request(
            monday: monday, settings: settings, catalog: inputs.catalog, names: inputs.names, history: history,
            weeksSinceDeload: Training.weeksSinceDeload(history, before: monday, calendar: calendar), program: week,
            programIndex: index, programWeeks: program.count, goals: author.goals, lastWeek: planned, goalLifts: lifts,
            programPlan: program, outline: outline, notes: notes, calendar: calendar)
        request.progression = await Progression.decided(request, by: Progression.Rules(tier: tier))
        let lastTop = Dictionary(planned.filter { $0.main }.compactMap { row in row.target("load_lb").map { (row.exercise, $0) } },
                                 uniquingKeysWith: max)
        return Scenario(twist: twist, request: request, lastTop: lastTop)
    }

    // MARK: Code checks

    struct Checks: Sendable {
        var outline: Bool
        var progression: Bool
        var equipment: Bool
        var pain: Bool?
        var rules: Bool
        /// The share of rows that differ from the outline and say why; nil for the baseline, which is the outline.
        var explained: Double?

        var passed: [String: Bool] {
            var all = ["outline kept": outline, "decided top sets": progression, "equipment": equipment, "PlanGuard rules": rules]
            if let pain { all["pain respected"] = pain }
            if let explained { all["changes explained"] = explained >= 0.8 }
            return all
        }
    }

    private static func working(_ rows: [PlannedWorkout]) -> [PlannedWorkout] { rows.filter { $0.note != TrainingGenerator.warmupNote } }

    private static func checks(_ rows: [PlannedWorkout], _ scenario: Scenario, baseline: Bool) -> Checks {
        let request = scenario.request
        let rows = working(rows)
        var equipment = request.settings.equipment
        if request.program?.travel == true { equipment.formIntersection(ProgramPlan.travelEquipment) }
        let bySlug = Dictionary(request.catalog.map { ($0.slug, $0) }, uniquingKeysWith: { a, _ in a })
        let days = { (rows: [PlannedWorkout]) in Set(rows.map { calendar.startOfDay(for: $0.date) }) }
        // A decided top set planned within a plate of it. Travel weeks have no barbell, so they decide nothing here.
        // A pain note may hold or ease the lift it's about (the designer's told so); the pain check scores that one.
        let sore: Set<String> = scenario.twist == .pain ? ["squat", "lunge"] : []
        let progression = request.program?.travel == true || request.progression.filter { !sore.contains(bySlug[$0.exercise]?.pattern ?? "") }.allSatisfy { decision in
            let loads = rows.filter { $0.exercise == decision.exercise }.compactMap { $0.target("load_lb") ?? $0.target("load_lb_hand") }
            return loads.max().map { abs($0 - decision.load) <= 5 } ?? false
        }
        let pain: Bool? = scenario.twist == .pain ? rows.filter { bySlug[$0.exercise]?.pattern == "squat" || bySlug[$0.exercise]?.pattern == "lunge" }
            .allSatisfy { row in (row.target("load_lb") ?? 0) <= (scenario.lastTop[row.exercise] ?? .infinity) } : nil
        let context = PlanGuard.Context(settings: request.settings, catalog: request.catalog, names: request.names,
                                        history: request.history.filter { $0.date < request.monday }, light: request.program?.light ?? false,
                                        calendar: calendar, wholeWeek: true, decided: request.progression)
        var explained: Double?
        if !baseline {
            let outline = working(request.outline)
            let changed = rows.filter { row in
                !outline.contains { calendar.isDate($0.date, inSameDayAs: row.date) && $0.exercise == row.exercise
                    && $0.target("load_lb") == row.target("load_lb") && $0.target("reps") == row.target("reps") }
            }
            explained = changed.isEmpty ? 1 : Double(changed.filter { $0.adjustedReason?.isEmpty == false }.count) / Double(changed.count)
        }
        return Checks(outline: days(rows) == days(request.outline),
                      progression: progression,
                      equipment: rows.allSatisfy { bySlug[$0.exercise]?.equipment.isSubset(of: equipment) ?? false },
                      pain: pain,
                      rules: PlanGuard.check(rows, context).repairs.isEmpty,
                      explained: explained)
    }

    // MARK: The judge

    @Generable
    struct Verdict {
        @Guide(description: "How well week A serves this person, 1 to 10", .range(1...10))
        var a: Int
        @Guide(description: "How well week B serves this person, 1 to 10", .range(1...10))
        var b: Int
        @Guide(description: "A or B: the one a good coach would write")
        var better: String
        @Guide(description: "Why, in two sentences, naming what in their notes or last week decided it")
        var why: String
    }

    private static func render(_ rows: [PlannedWorkout], names: [String: String], reasons: Bool) -> String {
        Dictionary(grouping: working(rows), by: \.date).sorted { $0.key < $1.key }.map { _, rows in
            let day = ProgramDesigner.weekdays[(calendar.component(.weekday, from: rows[0].date) + 5) % 7]
            return "\(day) \(rows[0].session): " + rows.map { row in
                "\(names[row.exercise] ?? row.exercise) \(Proposal.dose(row))"
                    + (reasons ? row.adjustedReason.map { " (\($0))" } ?? "" : "")
            }.joined(separator: ", ")
        }.joined(separator: "\n")
    }

    private static func judge(_ scenario: Scenario, code: [PlannedWorkout], ai: [PlannedWorkout], aiFirst: Bool,
                              model: any AIModel) async -> Verdict? {
        let request = scenario.request
        let context = ([ProgramDesigner.prompt(request, settings: request.settings, light: request.program?.light ?? false)
            .components(separatedBy: "\nMenu, by movement:").first ?? ""]).joined()
        let (a, b) = aiFirst ? (ai, code) : (code, ai)
        let session = model.session(instructions: """
            You are a head strength coach reviewing two versions of one person's training week, written by two of your \
            coaches. Judge which week a good coach would write for this person from what's below: their program, goals, \
            notes and how last week went. Weigh fit to the person over variety: progression where last week was easy, \
            holding or easing where it was hard or hurt, respect for pain and equipment, and the program's shape.
            """)
        return try? await session.respond(to: """
            The person and their week:
            \(context)

            Week A:
            \(render(a, names: request.names, reasons: true))

            Week B:
            \(render(b, names: request.names, reasons: true))
            """, generating: Verdict.self)
    }

    // MARK: Run

    @Test func designedAgainstTheCodeWeek() async throws {
        let environment = ProcessInfo.processInfo.environment
        let designer = EvalModel.current()
        let judge = EvalModel.model(environment["EVAL_JUDGE"].flatMap { $0.isEmpty ? nil : $0 } ?? "claude-opus-5-5")
        try #require(designer.isAvailable, Comment(rawValue: EvalModel.unavailable(designer)))
        try #require(judge.isAvailable, Comment(rawValue: EvalModel.unavailable(judge)))
        let inputs = try ProgramDesignerEvals.inputs()
        var report = ["# Week design evals (FIT-426): weeks by \(designer.name) against the code week, judged by \(judge.name)", ""]
        var rows: [String] = [], detail: [String] = []
        var wins = 0, margins: [Double] = [], losses: [String] = [], designed = 0, seconds: [Double] = []

        for (number, twist) in Twist.allCases.enumerated() {
            let scenario = await Self.scenario(twist, inputs: inputs)
            let code = scenario.request.outline
            let result = await ProgramDesigner.week(scenario.request, model: designer)
            if result.source == .model { designed += 1 }
            seconds.append(result.seconds)
            let ai = result.week.workouts
            let codeChecks = Self.checks(code, scenario, baseline: true), aiChecks = Self.checks(ai, scenario, baseline: false)
            // Each check the baseline passes and the AI week fails is a loss.
            let lost = codeChecks.passed.filter { $0.value && aiChecks.passed[$0.key] == false }.map(\.key).sorted()
            losses += lost.map { "\(twist.rawValue): \($0)" }
            let aiFirst = number % 2 == 0
            let verdict = await Self.judge(scenario, code: code, ai: ai, aiFirst: aiFirst, model: judge)
            let aiScore = verdict.map { aiFirst ? $0.a : $0.b }, codeScore = verdict.map { aiFirst ? $0.b : $0.a }
            let aiWon = verdict.map { $0.better.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix(aiFirst ? "A" : "B") } ?? false
            if aiWon { wins += 1 }
            if let aiScore, let codeScore { margins.append(Double(aiScore - codeScore)) }
            func marks(_ checks: Checks) -> String {
                checks.passed.sorted { $0.key < $1.key }.map { "\($0.value ? "✓" : "✗") \($0.key)" }.joined(separator: ", ")
            }
            rows.append("| \(twist.rawValue) | \(result.source.rawValue) | \(codeScore.map(String.init) ?? "–") | \(aiScore.map(String.init) ?? "–") | "
                        + "\(verdict == nil ? "no verdict" : aiWon ? "AI" : "code") | \(lost.isEmpty ? "none" : lost.joined(separator: ", ")) |")
            detail.append("## \(twist.rawValue)\n")
            if !scenario.request.notes.isEmpty { detail.append("Notes: " + scenario.request.notes.joined(separator: " · ") + "\n") }
            detail.append("**Code week** (\(marks(codeChecks)))\n\n" + Self.render(code, names: inputs.names, reasons: false) + "\n")
            detail.append("**AI week** (\(result.source.rawValue), \(String(format: "%.0f", result.seconds)) s; \(marks(aiChecks)))\n\n"
                          + Self.render(ai, names: inputs.names, reasons: true) + "\n")
            if let fallback = result.fallbackReason { detail.append("Fallback: \(fallback)\n") }
            if !result.repairs.isEmpty { detail.append("Repairs: " + result.repairs.map(\.text).joined(separator: " · ") + "\n") }
            if let verdict { detail.append("Judge: \(verdict.why)\n") }
        }

        let count = Twist.allCases.count
        let margin = margins.isEmpty ? 0 : margins.reduce(0, +) / Double(margins.count)
        let passed = wins >= count - 1 && margin >= 1 && losses.isEmpty && designed == count
        let perWeek = EvalModel.cost(designer).map { $0 / Double(max(designed, 1)) }
        report.append("**\(passed ? "PASS" : "FAIL")** · AI week judged better in \(wins) of \(count) · mean margin \(String(format: "%+.1f", margin)) "
                      + "· code checks lost: \(losses.count) · designed by the model \(designed)/\(count) "
                      + "· \(String(format: "%.0f", seconds.reduce(0, +) / Double(max(seconds.count, 1)))) s a week "
                      + "· \(EvalModel.dollars(perWeek)) a design · judge \(EvalModel.dollars(EvalModel.cost(judge)))")
        report.append("\nThe bar: judged better in at least \(count - 1) of \(count) with a mean margin of +1 or more, no code check lost, every week designed by the model.\n")
        report.append("| Scenario | Source | Code | AI | Judge's pick | Checks lost |")
        report.append("| --- | --- | --- | --- | --- | --- |")
        report += rows
        report.append("")
        report += detail
        for line in report.joined(separator: "\n").components(separatedBy: "\n") { print("WEEK§ " + line) }
    }
}
