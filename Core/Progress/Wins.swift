import Foundation

/// FIT-15: wins, derived from logs and never stored, so they can always be regenerated. A personal best is a new best
/// max or most reps in a row over where the goal started; a milestone is the first time a goal is 25, 50, 75 or 100%
/// of the way there; a streak is full program weeks, every planned session done, counted from 2.
struct WinItem: Equatable, Sendable, Identifiable {
    enum Kind: Sendable { case pr, milestone, streak }

    var kind: Kind
    var date: Date
    /// Stable across runs, so a win is the same win each time it's derived.
    var key: String
    var metric: String
    var unit: String
    /// The new best, the value when the milestone was crossed, or the streak in weeks.
    var value: Double
    /// Personal best: what it beat.
    var previous: Double?
    var start: Double?
    var target: Double?
    /// Milestone: 25, 50, 75 or 100.
    var percent: Int?
    /// The goal's best-so-far on each day it changed, from the start, for the card's line.
    var trend: [Double] = []
    var weeksLeft: Int?
    /// Streak: workouts done across it.
    var workouts = 0

    var id: String { key }
}

enum Wins {
    struct Goal: Sendable {
        var metric: String
        var unit: String
        var baseline: Double
        var target: Double
    }

    static let milestones = [25, 50, 75, 100]

    /// Every win since the program started, newest first.
    static func detect(goals: [Goal], sets: [LoggedSet], weighIns: [DatedValue], since start: Date, end: Date,
                       plannedDays: [Date], workoutDays: [Date], today: Date = .now, calendar: Calendar = .current) -> [WinItem] {
        var wins: [WinItem] = []
        for goal in goals {
            let trend = GoalProgress.trend(goal.metric, sets: sets, weighIns: weighIns, since: start, calendar: calendar)
            var values = [goal.baseline]
            var best = goal.baseline
            var crossed = Set<Int>()
            for point in trend {
                values.append(point.value)
                if goal.metric != "weight_lb", point.value > best {
                    wins.append(WinItem(kind: .pr, date: point.date, key: "pr:\(goal.metric):\(Int(point.value.rounded()))", metric: goal.metric,
                                    unit: goal.unit, value: point.value, previous: best, start: goal.baseline, target: goal.target,
                                    trend: values, weeksLeft: weeksLeft(from: point.date, to: end)))
                    best = point.value
                }
                let done = GoalProgress.fraction(from: goal.baseline, now: point.value, target: goal.target)
                for percent in milestones where !crossed.contains(percent) && done >= Double(percent) / 100 {
                    crossed.insert(percent)
                    wins.append(WinItem(kind: .milestone, date: point.date, key: "milestone:\(goal.metric):\(percent)", metric: goal.metric,
                                    unit: goal.unit, value: point.value, start: goal.baseline, target: goal.target, percent: percent,
                                    trend: values, weeksLeft: weeksLeft(from: point.date, to: end)))
                }
            }
        }
        wins += streaks(since: start, plannedDays: plannedDays, workoutDays: workoutDays, today: today, calendar: calendar)
        return wins.sorted { ($0.date, $0.key) > ($1.date, $1.key) }
    }

    /// Whole weeks left on the date, not counting a part week.
    static func weeksLeft(from date: Date, to end: Date) -> Int {
        max(0, Int((end.timeIntervalSince(date) / (7 * 86_400)).rounded(.down)))
    }

    /// A full week is every planned session done, and a week with none planned neither adds nor breaks. The week in
    /// progress doesn't count yet. A win at 2 weeks, then every 4.
    private static func streaks(since start: Date, plannedDays: [Date], workoutDays: [Date], today: Date,
                                calendar: Calendar) -> [WinItem] {
        let thisWeek = ProgramPlan.week(of: today, start: start, calendar: calendar)
        guard thisWeek > 0 else { return [] }
        let planned = Set(plannedDays.map(calendar.startOfDay)), done = Set(workoutDays.map(calendar.startOfDay))
        var wins: [WinItem] = [], streak = 0, workouts = 0
        for week in 0..<thisWeek {
            let monday = ProgramPlan.monday(week, start: start, calendar: calendar)
            let next = ProgramPlan.monday(week + 1, start: start, calendar: calendar)
            let days = planned.filter { $0 >= monday && $0 < next }
            guard !days.isEmpty else { continue }
            guard days.isSubset(of: done) else { streak = 0; workouts = 0; continue }
            streak += 1
            workouts += days.count
            if streak == 2 || streak % 4 == 0 {
                wins.append(WinItem(kind: .streak, date: calendar.date(byAdding: .day, value: -1, to: next)!, key: "streak:\(streak)",
                                metric: "streak", unit: "weeks", value: Double(streak), workouts: workouts))
            }
        }
        return wins
    }
}
