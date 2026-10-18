import Foundation

/// FIT-15: every win since the program started, from the store, and the words for each.
@MainActor enum WinFeed {
    static func wins(profile: Profile?, goals: [Goal], entries: [LogEntry], planned: [PlannedActivity], templates: [Template]) -> [WinItem] {
        guard let profile, let weeks = profile.program, let start = profile.programStart else { return [] }
        let end = profile.targetDate ?? ProgramPlan.monday(weeks.count, start: start)
        let sets = Planner.loggedSets(entries, templates: templates)
        let weighIns = entries.filter { $0.kind == .bodyweight }.compactMap { entry in
            entry.measurements.first { $0.metric == "weight_lb" }.map { DatedValue(date: entry.timestamp, value: $0.value) }
        }
        let tracked = goals.filter { $0.status == .active }.compactMap { goal in
            GoalOption.all.contains { $0.metric == goal.metric } ? goal.baseline.map {
                Wins.Goal(metric: goal.metric, unit: goal.unit, baseline: $0, target: goal.target)
            } : nil
        }
        return Wins.detect(goals: tracked, sets: sets, weighIns: weighIns, since: start, end: end,
                           plannedDays: planned.filter { $0.kind == .workout }.map(\.date),
                           workoutDays: entries.filter { $0.kind == .workout }.map(\.timestamp))
    }

    /// The wins earned on a day, newest first.
    static func wins(_ wins: [WinItem], on day: Date, calendar: Calendar = .current) -> [WinItem] {
        wins.filter { calendar.isDate($0.date, inSameDayAs: day) }
    }
}

/// What a win says, on the card (with or without weights), in the timeline and when opened.
struct WinWords {
    let win: WinItem
    let option: GoalOption?
    var showNumbers = true

    init(_ win: WinItem, showNumbers: Bool = true) {
        self.win = win
        self.showNumbers = showNumbers
        option = GoalOption.all.first { $0.metric == win.metric }
    }

    /// The share card's top line, "PERSONAL BEST".
    var tag: String {
        switch win.kind {
        case .pr: "PERSONAL BEST"
        case .streak: "STREAK"
        case .milestone: win.percent == 100 ? "GOAL REACHED" : win.percent == 50 ? "HALFWAY" : "\(win.percent ?? 0)% THERE"
        }
    }

    var heading: String {
        switch win.kind {
        case .pr: option?.name ?? win.metric
        case .streak: "Every planned session done"
        case .milestone: showNumbers ? "to \(phrase)" : "to my \(shortName) goal"
        }
    }

    /// The big number on the card.
    var big: String {
        switch win.kind {
        case .pr where isTime: showNumbers ? number(win.value) : "−\(number((win.previous ?? win.value) - win.value))"
        case .pr: showNumbers ? number(win.value) : "+\(number(win.value - (win.previous ?? win.value)))"
        case .streak: "\(Int(win.value))"
        case .milestone: showNumbers ? number(win.value) : "\(win.percent ?? 0)%"
        }
    }

    /// Beside the number, or under it inside the ring.
    var unit: String {
        switch win.kind {
        case .pr: shownUnit
        case .streak: "weeks"
        case .milestone: showNumbers ? "of \(number(win.target ?? 0)) \(shownUnit)" : "there"
        }
    }

    var sub: String {
        switch win.kind {
        case .pr where isTime:
            let faster = (win.previous ?? win.value) - win.value
            if showNumbers { return "\(number(faster)) faster than last time" }
            return "New best, \(max(1, Int((faster / max(win.previous ?? 1, 1) * 100).rounded())))% faster than last time"
        case .pr:
            let delta = win.value - (win.previous ?? win.value)
            if showNumbers { return "+\(number(delta)) \(unit(delta)) since last time" }
            let percent = max(1, Int((delta / max(win.previous ?? 1, 1) * 100).rounded()))
            return "New best, \(percent)% up on last time"
        case .streak: return "\(win.workouts) of \(win.workouts) workouts, in a row"
        case .milestone:
            let left = win.weeksLeft.map { $0 == 1 ? "1 week left" : "\($0) weeks left" }
            if win.percent == 100 { return "Goal reached" }
            let togo = showNumbers ? "\(number(abs((win.target ?? 0) - win.value))) \(shownUnit) to go".replacingOccurrences(of: "  ", with: " ") : nil
            return [togo, left].compactMap { $0 }.joined(separator: " · ")
        }
    }

    // MARK: Timeline

    var title: String {
        switch win.kind {
        case .pr: return "\(option?.name ?? win.metric) \(number(win.value)) \(shownUnit)".trimmingCharacters(in: .whitespaces)
        case .streak: return "\(Int(win.value)) weeks, every session"
        case .milestone:
            if win.percent == 100 { return "Reached \(phrase)" }
            if win.percent == 50 { return "Halfway to \(phrase)" }
            return "\(win.percent ?? 0)% of the way to \(phrase)"
        }
    }

    var line: String {
        let date = win.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        switch win.kind {
        case .pr where isTime: return "Personal best, \(number((win.previous ?? win.value) - win.value)) faster · \(date)"
        case .pr:
            let delta = win.value - (win.previous ?? win.value)
            return "Personal best, +\(number(delta)) \(unit(delta)) · \(date)"
        case .streak: return "\(win.workouts) of \(win.workouts) workouts · \(date)"
        case .milestone: return "\(number(win.start ?? 0)) → \(number(win.value)) \(shownUnit) · \(date)".replacingOccurrences(of: "  ", with: " ")
        }
    }

    var why: String {
        switch win.kind {
        case .pr:
            let previous = win.previous.map { "The last best was \(number($0))." } ?? ""
            if isTime { return "Your runs now predict \(number(win.value)). \(previous)" }
            return option?.measure == .reps ? "\(number(win.value)) in a row. \(previous)" : "An estimated max of \(number(win.value)) \(win.unit). \(previous)"
        case .streak: return "Every planned workout was done, \(Int(win.value)) full weeks in a row."
        case .milestone:
            let left = win.weeksLeft.map { " \($0) weeks left." } ?? ""
            return "You started at \(number(win.start ?? 0)) \(shownUnit). The goal is \(number(win.target ?? 0)).\(left)".replacingOccurrences(of: "  ", with: " ").replacingOccurrences(of: " .", with: ".")
        }
    }

    /// "a 250 lb squat", "10 pull-ups", "180 lb".
    private var phrase: String {
        let target = number(win.target ?? 0)
        return switch option?.id {
        case "squat": "a \(target) lb squat"
        case "bench": "a \(target) lb bench"
        case "deadlift": "a \(target) lb deadlift"
        case "pullups": "\(target) pull-ups"
        case "pushups": "\(target) push-ups"
        case "5k", "10k", "half", "marathon": option!.title(target: win.target ?? 0)
        default: "\(target) lb"
        }
    }

    var shortName: String {
        switch option?.id {
        case "squat": "squat"
        case "bench": "bench"
        case "deadlift": "deadlift"
        case "pullups": "pull-up"
        case "pushups": "push-up"
        case "5k", "10k": option!.id.uppercased()
        case "half": "half marathon"
        case "marathon": "marathon"
        default: "weight"
        }
    }

    private func unit(_ delta: Double) -> String { win.unit == "reps" && abs(delta) == 1 ? "rep" : win.unit }

    private func number(_ value: Double) -> String { option?.format(value) ?? Coach.number(value.rounded()) }

    /// FIT-179: a race time reads as a clock, faster being better.
    private var isTime: Bool { option?.measure == .time }
    private var shownUnit: String { option?.shownUnit ?? win.unit }
}
