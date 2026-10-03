import Foundation

/// Where a program goal is now (FIT-39), derived from logs since the program started; nil until there's a log.
enum GoalProgress {
    enum Pace: Equatable, Sendable { case starting, onPace, behind }

    /// "weight_lb": the last weigh-in. "<exercise>.1rm_lb": the best Brzycki estimate. "<exercise>.reps": most reps
    /// in an unloaded set.
    static func current(_ metric: String, sets: [LoggedSet], weighIns: [DatedValue], since start: Date) -> Double? {
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

    /// How far from the start to the target, 0–1, in either direction (weight goes down).
    static func fraction(from start: Double, now: Double, target: Double) -> Double {
        guard target != start else { return 1 }
        return min(1, max(0, (now - start) / (target - start)))
    }

    /// On pace when at least 80% of the way the program expects by the end of last week (prototype rule).
    static func pace(from start: Double, now: Double, target: Double, week: Int, weeks: [ProgramWeek]) -> Pace {
        guard week > 0 else { return .starting }
        let expected = fraction(from: start, now: ProgramPlan.expected(from: start, target: target, at: week - 1, weeks: weeks),
                                target: target)
        return fraction(from: start, now: now, target: target) >= expected * 0.8 ? .onPace : .behind
    }
}
