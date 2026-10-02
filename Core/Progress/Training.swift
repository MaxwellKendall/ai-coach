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
