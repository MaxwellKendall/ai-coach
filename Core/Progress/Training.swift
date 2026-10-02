import Foundation

/// One logged working set, decoupled from SwiftData so these rules stay pure.
struct LoggedSet: Sendable {
    var date: Date
    var exercise: String
    var pattern: String?
    var measurements: [Measurement]

    func value(_ metric: String) -> Double? {
        measurements.first { $0.metric == metric }?.value
    }
}

/// One point on a per-day chart.
struct DatedValue: Hashable, Sendable {
    var date: Date
    var value: Double
}

/// Training derivations ported from fitness-planner (.claude/CLAUDE.md and commands/review.md).
enum Training {
    /// Brzycki, CLAUDE.md "1RM Estimation": valid for 1–10 reps at RPE ≤ 8.
    static func estimated1RM(loadLb: Double, reps: Double, rpe: Double?) -> Double? {
        guard (1...10).contains(reps), (rpe ?? 0) <= 8 else { return nil }
        return loadLb * 36 / (37 - reps)
    }

    /// CLAUDE.md "Session Rating Composite". Effort is 1–10, energy and form 1–5, completion 0–1.
    /// Below 0.5 is a bad day whose sets shouldn't move 1RM estimates.
    static func composite(effort: Double, energy: Double, form: Double, completion: Double) -> Double {
        (effort / 2 + energy + form * 2 + completion * 5) / 10
    }

    /// Best estimate per exercise. review.md step 4: estimates never regress, so it's the max over history.
    static func estimated1RMs(_ sets: [LoggedSet]) -> [String: Double] {
        var best: [String: Double] = [:]
        for set in sets {
            guard let load = set.value("load_lb"), let reps = set.value("reps"),
                  let estimate = estimated1RM(loadLb: load, reps: reps, rpe: set.value("rpe")) else { continue }
            best[set.exercise] = max(best[set.exercise] ?? 0, estimate)
        }
        return best
    }

    /// Best estimate so far, one point per training day. Like `estimated1RMs`, it never regresses.
    static func estimated1RMTrend(_ sets: [LoggedSet], exercise: String, calendar: Calendar = .current) -> [DatedValue] {
        var byDay: [Date: Double] = [:]
        for set in sets where set.exercise == exercise {
            guard let load = set.value("load_lb"), let reps = set.value("reps"),
                  let estimate = estimated1RM(loadLb: load, reps: reps, rpe: set.value("rpe")) else { continue }
            let day = calendar.startOfDay(for: set.date)
            byDay[day] = max(byDay[day] ?? 0, estimate)
        }
        var best = 0.0
        return byDay.keys.sorted().map { day in
            best = max(best, byDay[day]!)
            return DatedValue(date: day, value: best)
        }
    }

    /// Consecutive full training weeks before `monday`. A week with less than 60% of the median training
    /// week's sets (a deload, a missed week or a layoff) resets the count. Derived, so imported history works.
    static func weeksSinceDeload(_ sets: [LoggedSet], before monday: Date, calendar: Calendar = .current) -> Int {
        var perWeek: [Date: Int] = [:]
        for set in sets where set.date < monday { perWeek[Week.monday(of: set.date, calendar: calendar), default: 0] += 1 }
        let volumes = perWeek.values.sorted()
        guard !volumes.isEmpty else { return 0 }
        let threshold = Double(volumes[volumes.count / 2]) * 0.6
        var weeks = 0
        var week = calendar.date(byAdding: .day, value: -7, to: monday)!
        while Double(perWeek[week] ?? 0) >= threshold {
            weeks += 1
            week = calendar.date(byAdding: .day, value: -7, to: week)!
        }
        return weeks
    }

    /// Working sets per movement pattern over the `days` calendar days ending on `date` (review.md step 3).
    static func setsByPattern(_ sets: [LoggedSet], endingOn date: Date, days: Int = 28,
                              calendar: Calendar = .current) -> [String: Int] {
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))!
        let start = calendar.date(byAdding: .day, value: -days, to: end)!
        var totals: [String: Int] = [:]
        for set in sets where set.date >= start && set.date < end {
            if let pattern = set.pattern { totals[pattern, default: 0] += 1 }
        }
        return totals
    }
}
