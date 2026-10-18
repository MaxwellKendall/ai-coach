import Foundation

/// A goal onboarding offers (FIT-38). Each is measured its own way, so the starting-point question follows it.
struct GoalOption: Identifiable, Sendable {
    /// FIT-179: `time` is a race time, lower being better.
    enum Measure: Sendable { case body, load, reps, time }

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
    /// FIT-124: lifts first. The app is for adults getting back to barbell strength with a goal and a date.
    static let all: [GoalOption] = [
        GoalOption(id: "squat", title: "Squat more", why: "A heavier estimated max.", kind: .training,
                   metric: "back-squat.1rm_lb", unit: "lb", measure: .load, exercise: "back-squat"),
        GoalOption(id: "bench", title: "Bench more", why: "A heavier estimated max.", kind: .training,
                   metric: "bench-press.1rm_lb", unit: "lb", measure: .load, exercise: "bench-press"),
        GoalOption(id: "deadlift", title: "Deadlift more", why: "A heavier estimated max.", kind: .training,
                   metric: "deadlift.1rm_lb", unit: "lb", measure: .load, exercise: "deadlift"),
        GoalOption(id: "pullups", title: "More pull-ups", why: "Strict, in a row.", kind: .training,
                   metric: "pull-up.reps", unit: "reps", measure: .reps, exercise: "pull-up"),
        GoalOption(id: "weight", title: "Lose weight", why: "About a pound a week, keeping your strength.", kind: .body,
                   metric: "weight_lb", unit: "lb", measure: .body, exercise: nil),
        GoalOption(id: "pushups", title: "More push-ups", why: "In a row. No equipment needed.", kind: .training,
                   metric: "push-up.reps", unit: "reps", measure: .reps, exercise: "push-up"),
        // FIT-179: a race time. Its starting point is a recent run (Running.outdoor), its value what the runs predict.
        GoalOption(id: "5k", title: "Run a faster 5K", why: "A time to beat, by a date.", kind: .training,
                   metric: Running.metric(meters: 5000), unit: "s", measure: .time, exercise: nil),
        GoalOption(id: "10k", title: "Run a faster 10K", why: "A time to beat, by a date.", kind: .training,
                   metric: Running.metric(meters: 10000), unit: "s", measure: .time, exercise: nil),
        GoalOption(id: "half", title: "Run a half marathon", why: "A time to beat, by a date.", kind: .training,
                   metric: Running.metric(meters: 21097.5), unit: "s", measure: .time, exercise: nil),
        GoalOption(id: "marathon", title: "Run a marathon", why: "A time to beat, by a date.", kind: .training,
                   metric: Running.metric(meters: 42195), unit: "s", measure: .time, exercise: nil),
    ]

    /// The goals a group can share: race times aren't group goals yet (FIT-179).
    static var group: [GoalOption] { all.filter { $0.measure != .time } }

    /// A race goal's distance in meters.
    var meters: Double? { Running.meters(metric) }

    static func with(id: String) -> GoalOption? { all.first { $0.id == id } }

    /// What the goal measures: "Body weight", "Back squat max", "Pull-ups in a row".
    /// FIT-107: the lift on its own, for shared pages: "Bench press", "Pull-ups".
    var liftName: String {
        name.replacingOccurrences(of: " max", with: "").replacingOccurrences(of: " in a row", with: "")
    }

    var name: String {
        switch id {
        case "weight": "Body weight"
        case "squat": "Back squat max"
        case "bench": "Bench press max"
        case "deadlift": "Deadlift max"
        case "pullups": "Pull-ups in a row"
        case "5k": "5K time"
        case "10k": "10K time"
        case "half": "Half marathon time"
        case "marathon": "Marathon time"
        default: "Push-ups in a row"
        }
    }

    /// How far one tap of − or + moves its target.
    /// A race time moves 30 seconds a tap.
    var step: Double { measure == .reps ? 1 : measure == .time ? 30 : 5 }

    /// "57:30" for a race time; whole numbers for lifts and reps, a tenth for body weight.
    func format(_ value: Double) -> String {
        measure == .time ? Running.clock(value) : Coach.number(measure == .body ? value : value.rounded())
    }

    /// The unit after a value: none for a race time, which reads as a clock.
    var shownUnit: String { measure == .time ? "" : unit }

    /// "Get to 180 lb", "Squat 225", "12 pull-ups".
    func title(target: Double) -> String {
        let number = Int(target.rounded())
        return switch id {
        case "weight": "Get to \(number) lb"
        case "squat": "Squat \(number)"
        case "bench": "Bench \(number)"
        case "deadlift": "Deadlift \(number)"
        case "pullups": "\(number) pull-ups"
        case "5k", "10k", "half", "marathon": "\(id == "half" ? "Half" : id == "marathon" ? "Marathon" : id.uppercased()) in \(Running.clock(target))"
        default: "\(number) push-ups"
        }
    }
}

/// One "Where are you starting?" row: age, body weight, or an exercise.
struct StartRow: Equatable, Sendable {
    /// `run`: a recent run, distance and time, for a race goal (FIT-179).
    enum Measure: Sendable { case age, body, load, reps, hold, run }
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
    /// Lifts whose starting point was estimated from their goal, once each, so one cleared stays cleared.
    var estimated: Set<String> = []

    static let weekRange = 4...52

    /// The training settings these answers make, once the age is known (FIT-73: the first week is designed from
    /// them before the program starts). Matches what `Profile.trainingSettings` will hold after Start.
    func trainingSettings(workoutTime: Int = 7 * 60, maxWeeklySets: Int = 60) -> TrainingSettings? {
        guard let age, !days.isEmpty else { return nil }
        return TrainingSettings(age: age, daysPerWeek: days.count, sessionMinutes: minutes, trainingDays: Week.ordered(days),
                                workoutTime: workoutTime, equipment: equipment, injuredAreas: BodyArea.muscles(for: hurts.sorted()),
                                avoidExercises: avoid, maxWeeklySets: maxWeeklySets,
                                starts: starts.values.sorted { $0.exercise < $1.exercise }, bodyWeight: weight)
    }

    /// The goals as the program designer reads them: "Bench 225 by Jan 25".
    func goalLines(by end: Date) -> [String] {
        goals.compactMap(GoalOption.with(id:)).compactMap { option in
            target(option).map { "\(option.title(target: $0)) by \(end.formatted(.dateTime.month(.abbreviated).day()))" }
        }
    }

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
            if goal.measure == .time, !rows.contains(where: { $0.id == Running.outdoor }) { rows.append(StartRow(id: Running.outdoor, measure: .run)) }
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
        case .time:
            guard let meters = goal.meters, let run = starts[Running.outdoor], let distance = run.value("distance_m"),
                  let seconds = run.value("duration_s") else { return nil }
            return Running.riegel(seconds: seconds, from: distance, to: meters)?.rounded()
        }
    }

    func target(_ goal: GoalOption) -> Double? { targets[goal.id] ?? suggestedTarget(goal) }

    /// A lift goal set without a starting point says the user already lifts: its start is estimated from the target,
    /// the inverse of `suggestedTarget`'s 1% a week (at most 25%), as a set of 5, dashed to confirm. Without it, week 1
    /// guessed from body weight as if they'd never lifted (squat 105 × 8 for a "Squat 245" goal).
    mutating func estimateStarts() {
        for goal in goals.compactMap(GoalOption.with(id:)) where goal.measure == .load {
            guard let slug = goal.exercise, starts[slug] == nil, !estimated.contains(slug), let target = targets[goal.id] else { continue }
            let max = target / min(1.25, 1 + 0.01 * Double(weeks))
            starts[slug] = StartingSet(exercise: slug, measurements: [
                Measurement(metric: "load_lb", value: TrainingGenerator.roundTo5(ProgramPlan.load(forMax: max, reps: 5)), unit: "lb"),
                Measurement(metric: "reps", value: 5, unit: "reps"),
            ])
            estimated.insert(slug)
            unconfirmed.insert("start.\(slug)")
        }
    }

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
        case .time:
            // Half a percent faster a week, at most 10%, to the nearest 15 seconds.
            guard let start else { return nil }
            return (start * max(0.9, 1 - 0.005 * weeks) / 15).rounded() * 15
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
