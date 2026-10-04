import Foundation

/// FIT-16: one member's progress on a group goal, derived from their own logs like any program goal.
/// Relative goals ("lose 10 lb") start from where each member was when they first published, so people
/// at different weights compare.
enum GroupProgress {
    enum Mode: String, Codable, Sendable { case relative, absolute }

    struct Mine: Equatable, Sendable {
        /// Where this member started, in the goal's unit.
        var baseline: Double
        var value: Double
        /// 0–100.
        var pct: Double
        var onPace: Bool?
    }

    /// The member's own target: their start plus the change for a relative goal, the goal itself otherwise.
    static func target(_ goal: Double, mode: Mode, baseline: Double) -> Double {
        mode == .relative ? baseline + goal : goal
    }

    /// Weight is the latest weigh-in and a max is the best ever, so a baseline taken at joining moves only
    /// with new logs. Nil until there's a log for the metric.
    static func current(_ metric: String, sets: [LoggedSet], weighIns: [DatedValue]) -> Double? {
        GoalProgress.current(metric, sets: sets, weighIns: weighIns, since: .distantPast)
    }

    static func mine(metric: String, goal: Double, mode: Mode, deadline: Date?, baseline: Double?, joined: Date,
                     sets: [LoggedSet], weighIns: [DatedValue], now: Date = .now) -> Mine? {
        guard let value = current(metric, sets: sets, weighIns: weighIns) else { return nil }
        let start = baseline ?? value
        let done = GoalProgress.fraction(from: start, now: value, target: target(goal, mode: mode, baseline: start))
        return Mine(baseline: start, value: value, pct: (done * 100).rounded(),
                    onPace: deadline.map { onPace(done: done, from: joined, to: $0, now: now) })
    }

    /// Straight-line expectation from joining to the deadline, with the program's 80% rule
    /// (`GoalProgress.pace`): under 80% of where you'd expect to be is behind.
    static func onPace(done: Double, from start: Date, to deadline: Date, now: Date) -> Bool {
        let total = deadline.timeIntervalSince(start)
        guard total > 0 else { return done >= 1 }
        let expected = min(1, max(0, now.timeIntervalSince(start) / total))
        return done >= expected * 0.8
    }

    /// The quarter mark crossed going from `old` to `new` percent, if any: posted to the group feed as a win.
    static func milestone(from old: Double?, to new: Double) -> Int? {
        let marks = [25, 50, 75, 100]
        let before = old ?? 0
        return marks.last { Double($0) <= new && Double($0) > before }
    }

    /// The group's combined progress: the mean of each member's percent, 0–100.
    static func together(_ pcts: [Double]) -> Double? {
        pcts.isEmpty ? nil : pcts.reduce(0, +) / Double(pcts.count)
    }

    /// Whole days from `now` to the deadline, never negative.
    static func daysLeft(until deadline: Date, now: Date = .now, calendar: Calendar = .current) -> Int {
        max(0, calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: deadline)).day ?? 0)
    }

    /// "Lose 10 lb", "Add 20 lb to bench press max", "Bench press max 225 lb", "+5 pull-ups".
    static func title(metric: String, goal: Double, mode: Mode) -> String {
        let option = GoalOption.all.first { $0.metric == metric }
        let number = Coach.number(abs(goal))
        let unit = option?.unit ?? ""
        let name = option?.name.lowercased() ?? metric
        guard mode == .relative else { return "\(option?.name ?? metric) \(Coach.number(goal)) \(unit)" }
        switch option?.measure {
        case .body: return goal < 0 ? "Lose \(number) lb" : "Gain \(number) lb"
        case .reps: return "+\(number) \(name.replacingOccurrences(of: " in a row", with: ""))"
        default: return "Add \(number) lb to \(name)"
        }
    }

    /// The change since the start, signed: "−6.2 lb", "+15 lb", "+3 reps".
    static func change(_ value: Double, from baseline: Double, unit: String) -> String {
        let delta = value - baseline
        let sign = delta < 0 ? "−" : "+"
        return "\(sign)\(Coach.number(abs(delta))) \(unit)"
    }
}
