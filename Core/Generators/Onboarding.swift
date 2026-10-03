import Foundation

/// A goal onboarding offers (FIT-38). Each is measured its own way, so the starting-point question follows it.
struct GoalOption: Identifiable, Sendable {
    enum Measure: Sendable { case body, load, reps }

    let id: String
    let title: String
    let why: String
    let kind: GoalKind
    let metric: String
    let unit: String
    let measure: Measure
    /// The exercise whose starting point is the goal's, if any.
    let exercise: String?

    /// Running isn't planned yet, so there's no 5K goal here (FIT-36).
    static let all: [GoalOption] = [
        GoalOption(id: "weight", title: "Lose weight", why: "About a pound a week, keeping your strength.", kind: .body,
                   metric: "weight_lb", unit: "lb", measure: .body, exercise: nil),
        GoalOption(id: "squat", title: "Squat more", why: "A heavier estimated max.", kind: .training,
                   metric: "back-squat.1rm_lb", unit: "lb", measure: .load, exercise: "back-squat"),
        GoalOption(id: "bench", title: "Bench more", why: "A heavier estimated max.", kind: .training,
                   metric: "bench-press.1rm_lb", unit: "lb", measure: .load, exercise: "bench-press"),
        GoalOption(id: "deadlift", title: "Deadlift more", why: "A heavier estimated max.", kind: .training,
                   metric: "deadlift.1rm_lb", unit: "lb", measure: .load, exercise: "deadlift"),
        GoalOption(id: "pullups", title: "More pull-ups", why: "Strict, in a row.", kind: .training,
                   metric: "pull-up.reps", unit: "reps", measure: .reps, exercise: "pull-up"),
        GoalOption(id: "pushups", title: "More push-ups", why: "In a row. No equipment needed.", kind: .training,
                   metric: "push-up.reps", unit: "reps", measure: .reps, exercise: "push-up"),
    ]

    static func with(id: String) -> GoalOption? { all.first { $0.id == id } }

    /// What the goal measures: "Body weight", "Back squat max", "Pull-ups in a row".
    var name: String {
        switch id {
        case "weight": "Body weight"
        case "squat": "Back squat max"
        case "bench": "Bench press max"
        case "deadlift": "Deadlift max"
        case "pullups": "Pull-ups in a row"
        default: "Push-ups in a row"
        }
    }

    /// How far one tap of − or + moves its target.
    var step: Double { measure == .reps ? 1 : 5 }

    /// "Get to 180 lb", "Squat 225", "12 pull-ups".
    func title(target: Double) -> String {
        let number = Int(target.rounded())
        return switch id {
        case "weight": "Get to \(number) lb"
        case "squat": "Squat \(number)"
        case "bench": "Bench \(number)"
        case "deadlift": "Deadlift \(number)"
        case "pullups": "\(number) pull-ups"
        default: "\(number) push-ups"
        }
    }
}

/// One "Where are you starting?" row: age, body weight, or an exercise.
struct StartRow: Equatable, Sendable {
    enum Measure: Sendable { case age, body, load, reps, hold }
    /// "age", "weight" or an exercise slug.
    var id: String
    var measure: Measure
}

/// Everything onboarding asks, before it's saved. Pure, so the rules that build rows and suggest targets are tested.
struct OnboardingAnswers: Sendable {
    var goals: [String] = []
    /// Targets the user said or set; the rest are suggested.
    var targets: [String: Double] = [:]
    var weeks = 16
    var equipment: Set<String> = ["barbell", "rack", "bench", "dumbbells", "pull_up_bar"]
    var avoid: Set<String> = []
    var age: Int?
    var weight: Double?
    /// By exercise slug.
    var starts: [String: StartingSet] = [:]
    var days = [0, 2, 4]
    var minutes = 45
    var hurts: Set<String> = []
    /// Values heard or suggested and not touched since, drawn dashed: "goals", "weeks", "age", "weight", "days",
    /// "minutes", "hurts", "move.<slug>", "start.<slug>", "target.<goal>".
    var unconfirmed: Set<String> = []

    static let weekRange = 4...52

    /// Exercises you have the equipment for and haven't unticked.
    func available(_ catalog: [Exercise]) -> [Exercise] {
        catalog.filter { $0.equipment.isSubset(of: equipment) && !avoid.contains($0.slug) }
    }

    /// Age and body weight, then what each goal is measured by, then the main lift the program would pick for
    /// each pattern.
    func startRows(_ catalog: [Exercise]) -> [StartRow] {
        var rows = [StartRow(id: "age", measure: .age), StartRow(id: "weight", measure: .body)]
        func add(_ exercise: Exercise) {
            guard !rows.contains(where: { $0.id == exercise.slug }) else { return }
            rows.append(StartRow(id: exercise.slug, measure: Self.measure(exercise)))
        }
        for goal in goals.compactMap(GoalOption.with(id:)) {
            if let slug = goal.exercise, let exercise = catalog.first(where: { $0.slug == slug }) { add(exercise) }
        }
        let available = available(catalog)
        for pattern in ["squat", "hinge", "push", "pull"] {
            if let exercise = TrainingGenerator.pick(Slot(pattern: pattern, main: true), from: available, excluding: [], recent: []) {
                add(exercise)
            }
        }
        return rows
    }

    static func measure(_ exercise: Exercise) -> StartRow.Measure {
        exercise.isTimed ? .hold : exercise.equipment.isSubset(of: ["pull_up_bar"]) ? .reps : .load
    }

    /// Where a goal starts, in its unit: body weight, the estimated max, or most reps in a row.
    func baseline(_ goal: GoalOption) -> Double? {
        switch goal.measure {
        case .body: return weight
        case .load:
            guard let start = goal.exercise.flatMap({ starts[$0] }), let load = start.value("load_lb"),
                  let reps = start.value("reps") else { return nil }
            return ProgramPlan.estimatedMax(load: load, reps: reps).rounded()
        case .reps: return goal.exercise.flatMap { starts[$0]?.value("reps") }
        }
    }

    func target(_ goal: GoalOption) -> Double? { targets[goal.id] ?? suggestedTarget(goal) }

    /// Code's proposal, which the user edits. About a pound a week of weight, at most 10%; strength up 1% a week
    /// (at most 25%); reps up one every two weeks (at most double). Without a starting point, the age tier's
    /// target (fitness-planner CLAUDE.md "Age-Bracket Goal Tiers").
    func suggestedTarget(_ goal: GoalOption) -> Double? {
        let tier = GoalSuggestions.tier(age: age ?? 35)
        let weeks = Double(self.weeks)
        let start = baseline(goal)
        switch goal.measure {
        case .body:
            guard let start else { return nil }
            return TrainingGenerator.roundTo5(max(start - weeks, start * 0.9))
        case .load:
            if let start { return TrainingGenerator.roundTo5(start * min(1.25, 1 + 0.01 * weeks)) }
            guard let weight else { return nil }
            let multiple = switch goal.id {
            case "squat": tier.squat
            case "deadlift": tier.hinge
            default: tier.push
            }
            return TrainingGenerator.roundTo5(weight * multiple)
        case .reps:
            if let start { return min(start * 2, start + (weeks / 2).rounded(.down)) }
            return Double(goal.id == "pullups" ? tier.pullUps : tier.pushUps)
        }
    }

    /// The best set of the 8 weeks up to the last time it was done, for prefilling a row "from your logs": the
    /// highest estimated max, most reps, or longest hold.
    static func recentBest(_ history: [LoggedSet], exercise: Exercise, before date: Date,
                           calendar: Calendar = .current) -> StartingSet? {
        let done = history.filter { $0.exercise == exercise.slug && $0.date < date }
        guard let last = done.map(\.date).max() else { return nil }
        let since = calendar.date(byAdding: .day, value: -56, to: last)!
        let sets = done.filter { $0.date >= since }
        func keep(_ metrics: [String], from set: LoggedSet) -> StartingSet {
            StartingSet(exercise: exercise.slug, measurements: set.measurements.filter { metrics.contains($0.metric) })
        }
        switch measure(exercise) {
        case .hold:
            return sets.filter { $0.value("duration_s") != nil }.max { $0.value("duration_s")! < $1.value("duration_s")! }
                .map { keep(["duration_s"], from: $0) }
        case .reps:
            return sets.filter { $0.value("reps") != nil && $0.value("load_lb") == nil }.max { $0.value("reps")! < $1.value("reps")! }
                .map { keep(["reps"], from: $0) }
        default:
            func estimate(_ set: LoggedSet) -> Double {
                ProgramPlan.estimatedMax(load: set.value("load_lb") ?? 0, reps: min(set.value("reps") ?? 0, 12))
            }
            return sets.filter { $0.value("load_lb") != nil && $0.value("reps") != nil }.max { estimate($0) < estimate($1) }
                .map { keep(["load_lb", "reps"], from: $0) }
        }
    }
}
