import Foundation

/// Where a program goal is now (FIT-39), derived from logs since the program started; nil until there's a log.
enum GoalProgress {
    enum Pace: Equatable, Sendable { case starting, behind, onPace, ahead }

    /// "weight_lb": the last weigh-in. "<exercise>.1rm_lb": the best Brzycki estimate. "<exercise>.reps": most reps
    /// in an unloaded set.
    static func current(_ metric: String, sets: [LoggedSet], weighIns: [DatedValue], since start: Date) -> Double? {
        // FIT-179: a race time is the fastest the runs predict.
        if let meters = Running.meters(metric) { return Running.best(meters, sets: sets, since: start)?.time }
        if metric == "weight_lb" { return weighIns.filter { $0.date >= start }.max { $0.date < $1.date }?.value }
        let parts = metric.split(separator: ".").map(String.init)
        guard parts.count == 2 else { return nil }
        let sets = sets.filter { $0.exercise == parts[0] && $0.date >= start }
        switch parts[1] {
        case "1rm_lb":
            return sets.compactMap { set in
                guard let load = set.value("load_lb"), let reps = set.value("reps"), reps <= 12 else { return nil }
                return ProgramPlan.estimatedMax(load: load, reps: reps).rounded()
            }.max()
        case "reps": return sets.filter { $0.value("load_lb") == nil }.compactMap { $0.value("reps") }.max()
        default: return nil
        }
    }

    /// The set behind `current` for a max or reps goal: the heaviest estimate, or the most unloaded reps.
    static func best(_ metric: String, sets: [LoggedSet], since start: Date) -> LoggedSet? {
        if let meters = Running.meters(metric) { return Running.best(meters, sets: sets, since: start)?.run }
        let parts = metric.split(separator: ".").map(String.init)
        guard parts.count == 2 else { return nil }
        let sets = sets.filter { $0.exercise == parts[0] && $0.date >= start }
        switch parts[1] {
        case "1rm_lb": return sets.filter { ($0.value("reps") ?? 99) <= 12 }.max { estimate($0) < estimate($1) }
        case "reps": return sets.filter { $0.value("load_lb") == nil }.max { ($0.value("reps") ?? 0) < ($1.value("reps") ?? 0) }
        default: return nil
        }
    }

    private static func estimate(_ set: LoggedSet) -> Double {
        guard let load = set.value("load_lb"), let reps = set.value("reps") else { return 0 }
        return ProgramPlan.estimatedMax(load: load, reps: reps).rounded()
    }

    /// The goal over time, one point a day: weigh-ins as logged, maxes and reps as the best so far, like `current`.
    static func trend(_ metric: String, sets: [LoggedSet], weighIns: [DatedValue], since start: Date,
                      calendar: Calendar = .current) -> [DatedValue] {
        var byDay: [Date: Double] = [:]
        if metric == "weight_lb" {
            for weighIn in weighIns.sorted(by: { $0.date < $1.date }) where weighIn.date >= start {
                byDay[calendar.startOfDay(for: weighIn.date)] = weighIn.value
            }
            return byDay.keys.sorted().map { DatedValue(date: $0, value: byDay[$0]!) }
        }
        for set in sets where set.date >= start {
            let day = calendar.startOfDay(for: set.date)
            guard byDay[day] == nil, let value = current(metric, sets: sets.filter { $0.date < calendar.date(byAdding: .day, value: 1, to: day)! },
                                                         weighIns: [], since: start) else { continue }
            byDay[day] = value
        }
        return byDay.keys.sorted().map { DatedValue(date: $0, value: byDay[$0]!) }
    }

    /// Whether a smaller value is better: a race time.
    static func lowerIsBetter(_ metric: String) -> Bool { Running.meters(metric) != nil }

    /// FIT-263: which way the goal is met. A race time, and weight to lose, go down; a max, reps and weight to gain go
    /// up. Never read from start against target alone: a lift's start at or above its target isn't a goal to go down.
    static func goesDown(_ metric: String, from start: Double, target: Double) -> Bool {
        lowerIsBetter(metric) || (metric == "weight_lb" && target < start)
    }

    /// How far from the start to the target, 0–1, the goal's way. Behind the start is 0. A start already at or past
    /// the target (a lift target set below the starting max) counts only once `now` moves past the start, so it never
    /// reads 100% on its first day (FIT-263).
    static func fraction(_ metric: String, from start: Double, now: Double, target: Double) -> Double {
        let way: Double = goesDown(metric, from: start, target: target) ? -1 : 1
        let moved = (now - start) * way, needed = (target - start) * way
        guard needed > 0 else { return moved > 0 ? 1 : 0 }
        return min(1, max(0, moved / needed))
    }

    /// Against the way the program expects by the end of last week (prototype rule): under 80% is behind, 125% or
    /// more is ahead, which is when the 4-week check-in offers to raise the goal.
    static func pace(_ metric: String, from start: Double, now: Double, target: Double, week: Int, weeks: [ProgramWeek]) -> Pace {
        guard week > 0 else { return .starting }
        let expected = fraction(metric, from: start, now: ProgramPlan.expected(from: start, target: target, at: week - 1, weeks: weeks),
                                target: target)
        let done = fraction(metric, from: start, now: now, target: target)
        if done < expected * 0.8 { return .behind }
        return expected > 0 && done >= expected * 1.25 ? .ahead : .onPace
    }

    /// FIT-278: the same rule against a goal's own date, a straight line from the program's start to it.
    static func pace(_ metric: String, from start: Double, now: Double, target: Double, started: Date, today: Date, due: Date) -> Pace {
        let done = today.timeIntervalSince(started), total = due.timeIntervalSince(started)
        guard done >= 7 * 86_400, total > 0 else { return .starting }
        let expected = min(1, done / total), reached = fraction(metric, from: start, now: now, target: target)
        if reached < expected * 0.8 { return .behind }
        return reached >= expected * 1.25 ? .ahead : .onPace
    }

    /// FIT-278: how far short of the target a forecast lands, the goal's way; below zero is past it.
    static func shortfall(_ metric: String, from start: Double, lands: Double, target: Double) -> Double {
        (target - lands) * (goesDown(metric, from: start, target: target) ? -1 : 1)
    }

    /// Where the goal stands: the logged value, except that a max or reps goal never reads below where it started.
    /// Program sets are below a max on purpose (3×4 pull-ups from someone who can do 8), so they aren't a loss. A
    /// weigh-in or a race time can go either way and is shown as it is.
    static func standing(_ metric: String, logged: Double?, from start: Double) -> Double {
        guard let logged else { return start }
        guard metric != "weight_lb", !lowerIsBetter(metric) else { return logged }
        return max(logged, start)
    }

    /// `trend` as `standing` reads it: flat at the start until a set beats it.
    static func standingTrend(_ metric: String, _ trend: [DatedValue], from start: Double) -> [DatedValue] {
        trend.map { DatedValue(date: $0.date, value: standing(metric, logged: $0.value, from: start)) }
    }

    /// Where the goal lands by `end` if it keeps moving as it has since `started`. Nil before two weeks of logs (too
    /// little to draw a line through), and nil when it hasn't moved toward the target: a line the wrong way, five
    /// months long, says nothing a few sessions mean ("-45 reps by Apr 3"). Never below zero.
    static func forecast(from start: Double, now: Double, target: Double, started: Date, today: Date, end: Date) -> Double? {
        let done = today.timeIntervalSince(started), left = max(0, end.timeIntervalSince(today))
        guard done >= 14 * 86_400, (now - start) * (target - start) > 0 else { return nil }
        return max(0, now + (now - start) / done * left)
    }

    /// How much it has to move each week from today to reach the target by `end`.
    static func perWeek(now: Double, target: Double, today: Date, end: Date) -> Double {
        (target - now) / max(1, end.timeIntervalSince(today) / (7 * 86_400))
    }
}
