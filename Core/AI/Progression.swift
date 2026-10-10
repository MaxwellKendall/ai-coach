import Foundation

/// FIT-100: each main lift's next step, decided before a week is designed: add load, hold, or back off. FIT-98 found
/// that models designing a whole week plan too many drops and leave goals short, whatever their size; deciding each
/// lift on its own, from how it went, and handing the week's designer the top sets fixes the part they get wrong. The
/// designer still chooses everything else. Light weeks aren't decided; the program lightens them.
enum Progression {
    enum Step: String, CaseIterable, Sendable {
        /// Add more is twice the usual step, for a lift behind its goal's line whose last session went to plan.
        case addMore = "add_more", add, hold, backOff = "back_off"
    }

    /// What's known about one lift going into the week: the evidence a decider reads.
    struct Lift: Sendable {
        var exercise: String
        var name: String
        /// Its top set the last time it was planned, when it was.
        var plannedLoad: Double?
        var plannedReps: Double?
        /// The last two sessions it was done in, most recent first.
        var sessions: [[LoggedSet]]
        /// Days from the last session to this week's Monday.
        var daysOff: Int?
        /// A goal's estimated max now and where it should be by the end of this week, for a goal lift.
        var now: Double?
        var aim: Double?
        /// This week's reps for main lifts, from the program brief's phase; nil keeps the last reps.
        var reps: Double? = nil

        /// Behind its goal's line by more than 2.5%.
        var behind: Bool {
            guard let aim, let now = now ?? lastMax else { return false }
            return now < aim * 0.975
        }

        /// The last session's best set as an estimated max.
        var lastMax: Double? {
            sessions.first?.compactMap { set -> Double? in
                guard let load = set.value("load_lb") ?? set.value("load_lb_hand"), let reps = set.value("reps") else { return nil }
                return ProgramPlan.estimatedMax(load: load, reps: reps)
            }.max()
        }
    }

    /// A step turned into the week's top set for the lift.
    struct Decision: Equatable, Sendable {
        var exercise: String
        var step: Step
        var load: Double
        var reps: Double
        /// The estimated max the top set shows: what the step aims for.
        var estimatedMax: Double
        var perHand: Bool
        /// How sure the decider was, 0 to 1; 1 for the rule table.
        var confidence: Double
    }

    // MARK: The evidence

    /// The lifts to decide: last week's main lifts and the goal lifts, each with sessions to go on. After a light week
    /// (a deload), from the hard week before it: its loads were lightened on purpose, so they aren't the base.
    static func lifts(_ request: ProgramDesigner.Request) -> [Lift] {
        let calendar = request.calendar
        let afterLight = request.programIndex.map { $0 > 0 && request.programPlan.indices.contains($0 - 1) && request.programPlan[$0 - 1].light } ?? false
        let cutoff = afterLight ? calendar.date(byAdding: .day, value: -7, to: request.monday)! : request.monday
        let past = request.history.filter { $0.date < cutoff }
        let since = calendar.date(byAdding: .day, value: -56, to: request.monday)!
        let lastWeek = afterLight ? [] : request.lastWeek
        let mains = request.lastWeek.filter { $0.main && $0.note != TrainingGenerator.warmupNote }.map(\.exercise)
        let slugs = (mains + request.goalLifts.filter { $0.measure == "1rm_lb" }.map(\.exercise))
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return slugs.compactMap { slug in
            let sets = past.filter { $0.exercise == slug }
            let days = Set(sets.map { calendar.startOfDay(for: $0.date) }).sorted(by: >)
            guard let last = days.first else { return nil }
            let sessions = days.prefix(2).map { day in sets.filter { calendar.isDate($0.date, inSameDayAs: day) } }
            let planned = lastWeek.filter { $0.exercise == slug }.max { ($0.target("load_lb") ?? $0.target("load_lb_hand") ?? 0) < ($1.target("load_lb") ?? $1.target("load_lb_hand") ?? 0) }
            let goal = request.goalLifts.first { $0.exercise == slug && $0.measure == "1rm_lb" }
            let aim = goal.flatMap { goal in
                request.programIndex.flatMap { index in
                    request.programPlan.indices.contains(index)
                        ? ProgramPlan.expected(from: goal.start, target: goal.target, at: index, weeks: request.programPlan) : nil
                }
            }
            return Lift(exercise: slug, name: request.names[slug] ?? slug,
                        plannedLoad: planned.flatMap { $0.target("load_lb") ?? $0.target("load_lb_hand") }, plannedReps: planned?.target("reps"),
                        sessions: sessions, daysOff: calendar.dateComponents([.day], from: last, to: cutoff).day,
                        now: goal.flatMap { _ in GoalProgress.current("\(slug).1rm_lb", sets: past, weighIns: [], since: since) } ?? goal?.start,
                        aim: aim, reps: request.brief.map { Double($0.mainReps) })
        }
    }

    /// "Bench Press: last time, 6 days ago, planned 185 × 5; did 185 × 5, 185 × 5, 185 × 4 at RPE 9.5. The time before: 180 ×
    /// 5, 180 × 5, 180 × 5 at RPE 8. Goal: estimated max about 200 now, 205 by the end of this week."
    static func evidence(_ lift: Lift) -> String {
        func done(_ sets: [LoggedSet]) -> String {
            let each = sets.map { set in
                [(set.value("load_lb") ?? set.value("load_lb_hand")).map(Coach.number), set.value("reps").map(Coach.number)]
                    .compactMap { $0 }.joined(separator: " × ")
            }.joined(separator: ", ")
            return each + (sets.compactMap { $0.value("rpe") }.max().map { " at RPE \(Coach.number($0))" } ?? "")
        }
        var text = "\(lift.name): last time\(lift.daysOff.map { ", \($0) days ago," } ?? "")"
        if let load = lift.plannedLoad, let reps = lift.plannedReps { text += " planned \(Coach.number(load)) × \(Coach.number(reps));" }
        if let last = lift.sessions.first { text += " did \(done(last))." }
        if lift.sessions.count > 1 { text += " The time before: \(done(lift.sessions[1]))." }
        if let aim = lift.aim {
            text += " Goal: estimated max about \(Coach.number((lift.now ?? aim).rounded())) now, \(Coach.number(aim.rounded())) by the end of this week."
        }
        return text
    }

    /// A set short of the reps planned, or of the session's most common reps when there was no plan.
    static func short(_ sets: [LoggedSet], planned: Double?) -> Bool {
        let reps = sets.compactMap { $0.value("reps") }
        guard let target = planned ?? Dictionary(grouping: reps, by: { $0 }).max(by: { $0.value.count < $1.value.count })?.key else { return false }
        return reps.contains { $0 < target }
    }

    /// The week's shared evidence for a decider: its place in the program, last week as done, and sleep.
    static func context(_ request: ProgramDesigner.Request) -> String {
        var lines: [String] = []
        if let program = request.program {
            lines.append("\(request.programIndex.map { "Week \($0 + 1)\(request.programWeeks.map { " of \($0)" } ?? ""), " } ?? "")\(ProgramPlan.title(program).lowercased()) week.")
        }
        lines += ProgramDesigner.lastWeekDone(request)
        if let sleep = request.sleepHours { lines.append("Slept \(Coach.number((sleep * 2).rounded() / 2)) h a night on average last week.") }
        return lines.joined(separator: "\n")
    }

    /// FIT-101: a hard week's main lifts decided, in the order they were gathered: what `Planner.design` and the evals
    /// give the week's designer. Light weeks aren't decided; a decider that fails leaves the lifts to the designer.
    static func decided(_ request: ProgramDesigner.Request, by decider: any ProgressionDecider) async -> [Decision] {
        guard request.program?.light != true else { return [] }
        let lifts = lifts(request)
        guard !lifts.isEmpty, let decided = try? await decider.decide(lifts, context: context(request)) else { return [] }
        return lifts.compactMap { decided[$0.exercise] }
    }

    // MARK: Turning a step into the top set

    /// The step as an estimated max, from last time's top set: add puts 5 lb on it (2.5 a hand, as
    /// `TrainingGenerator.nextLoad`), add more 10 (5), hold keeps it, back off takes 10% off (plan.md "returning
    /// athlete"). The top set is that max at this week's reps, so a phase that moves to triples goes heavier, not lighter.
    static func decision(_ lift: Lift, step: Step, confidence: Double = 1) -> Decision? {
        let top = lift.sessions.first?.max { ($0.value("load_lb") ?? $0.value("load_lb_hand") ?? 0) < ($1.value("load_lb") ?? $1.value("load_lb_hand") ?? 0) }
        let perHand = top?.value("load_lb_hand") != nil
        guard let base = lift.plannedLoad ?? top.flatMap({ $0.value("load_lb") ?? $0.value("load_lb_hand") }),
              let baseReps = lift.plannedReps ?? top?.value("reps") else { return nil }
        let increment = perHand ? 2.5 : 5.0
        let from = switch step {
        case .addMore: base + 2 * increment
        case .add: base + increment
        case .hold: base
        case .backOff: base * 0.9
        }
        let max = ProgramPlan.estimatedMax(load: from, reps: baseReps)
        let reps = lift.reps ?? baseReps
        let exact = max * (37 - min(reps, 36)) / 36
        let load = perHand ? (exact / 2.5).rounded() * 2.5 : TrainingGenerator.roundTo5(exact)
        return Decision(exercise: lift.exercise, step: step, load: load, reps: reps, estimatedMax: max, perHand: perHand, confidence: confidence)
    }

    /// "Bench Press: add → top set 190 × 5."
    static func line(_ decision: Decision, names: [String: String]) -> String {
        let step = switch decision.step { case .addMore: "add more"; case .add: "add"; case .hold: "hold"; case .backOff: "back off" }
        return "\(names[decision.exercise] ?? decision.exercise): \(step) → top set \(Coach.number(decision.load))\(decision.perHand ? " each" : "") × \(Coach.number(decision.reps))."
    }

    // MARK: The rule table

    /// The step from the rules: more than 4 weeks off backs off, more than 2 holds (`TrainingGenerator.nextLoad`);
    /// missed reps twice running backs off, once holds; RPE over the tier's cap, or 9+, holds; otherwise, every rep done
    /// at or under the cap, add, or add more when the lift is behind its goal's line. (`nextLoad` only adds at 1 under the
    /// cap; planned at the cap, nothing would ever go up.)
    struct Rules: ProgressionDecider {
        var tier: AgeTier
        var name: String { "rules" }

        func decide(_ lifts: [Lift], context: String) async throws -> [String: Decision] {
            Dictionary(lifts.compactMap { lift in Progression.decision(lift, step: step(lift)).map { (lift.exercise, $0) } },
                       uniquingKeysWith: { first, _ in first })
        }

        func step(_ lift: Lift) -> Step {
            if let off = lift.daysOff, off > 28 { return .backOff }
            if let off = lift.daysOff, off > 14 { return .hold }
            guard let last = lift.sessions.first, !last.isEmpty else { return .hold }
            if Progression.short(last, planned: lift.plannedReps) {
                let before = lift.sessions.dropFirst().first
                return before.map { Progression.short($0, planned: lift.plannedReps) } == true ? .backOff : .hold
            }
            if let rpe = last.compactMap({ $0.value("rpe") }).max(), rpe >= 9 || rpe > tier.topRPE { return .hold }
            return lift.behind ? .addMore : .add
        }
    }
}

/// FIT-100: what decides each lift's next step. The rule table here; a decision model in the evals (OpenAIDecisions).
protocol ProgressionDecider: Sendable {
    var name: String { get }
    /// Each lift's decision, by exercise; a lift left out is left to the week's designer. `context` is the week's shared
    /// evidence: sessions done, sleep, the program's phase.
    func decide(_ lifts: [Progression.Lift], context: String) async throws -> [String: Progression.Decision]
}
