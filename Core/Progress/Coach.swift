import Foundation

/// The one-line explanations on Today's cards and the finish card (FIT-27). Plain text from numbers the rules
/// already computed, so it works without Apple Intelligence and never invents anything.
enum Coach {
    /// A planned day: why it looks the way it does.
    static func plan(deload: Bool, reasons: [String]) -> String {
        if reasons.contains(where: { $0.hasSuffix("min available") }) { return "Short on time, so the main lifts stay and the extras go." }
        if reasons.contains(where: { $0.hasPrefix("low energy") }) { return "Taking it easier today: fewer sets, a little less effort." }
        if let injury = reasons.first(where: { $0.contains("injury") }) {
            return "Working around the \(injury.prefix { $0 != ":" }.replacingOccurrences(of: " injury", with: ""))."
        }
        if deload { return "Light week: same moves, a little less weight. Leave a couple of reps in the tank." }
        return "Leave a rep or two in the tank on every set."
    }

    /// FIT-202: a coach's session says what the coach wrote for it (the week's reason, "From Sam"), not the app's tips.
    /// "edited" is the dashboard's mark for a changed row, not something to show.
    static func coached(reasons: [String], coach: String) -> String {
        reasons.first { !$0.isEmpty && $0 != "edited" } ?? "From \(coach)"
    }

    /// A rest day points at the next session.
    static func rest(next: (name: String, date: Date)?, from day: Date, calendar: Calendar = .current) -> String {
        guard let next else { return "Nothing planned. Enjoy the day off." }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: day), to: calendar.startOfDay(for: next.date)).day ?? 0
        let when = days == 1 ? "tomorrow" : "on \(next.date.formatted(.dateTime.weekday(.wide)))"
        return "\(next.name) is \(when)."
    }

    /// One lift as the progression rule saw it: what it was planned at, what was done, and what comes next.
    struct Lift: Equatable, Sendable {
        var name: String
        var load: Double
        var next: Double?
        /// Sets that came in under the planned reps, as (set number, reps done, reps planned).
        var short: [(set: Int, done: Double, planned: Double)] = []

        static func == (a: Lift, b: Lift) -> Bool {
            a.name == b.name && a.load == b.load && a.next == b.next && a.short.map(\.set) == b.short.map(\.set)
        }
    }

    /// A finished session, from its main lifts in order. Unticked sets come first: they don't count.
    static func done(_ lifts: [Lift], missedSets: Int = 0) -> String {
        if missedSets > 0 {
            return "\(missedSets) \(missedSets == 1 ? "set" : "sets") not done. They won’t count, and the plan won’t push you up on those."
        }
        if let lift = lifts.first(where: { !$0.short.isEmpty }), let short = lift.short.last {
            let gap = Int(short.planned - short.done)
            let line = "\(lift.name) came up \(gap == 1 ? "one rep" : "\(gap) reps") short on set \(short.set)"
            return lift.next == lift.load ? line + ", so it stays at \(number(lift.load)) next time." : line + "."
        }
        if let lift = lifts.first(where: { ($0.next ?? 0) > $0.load }), let next = lift.next {
            return "\(lift.name) moved well, so it goes up \(number(next - lift.load)) lb next time."
        }
        if lifts.isEmpty { return "Logged." }
        return "Every set hit. Same weights next time until it feels easier."
    }

    /// "3×5 @ 155 lb", falling back to each measurement's own display.
    static func targets(_ targets: [Measurement]) -> String {
        func value(_ metric: String) -> Double? { targets.first { $0.metric == metric }?.value }
        var parts: [String] = []
        var rest = targets
        if let sets = value("sets"), let reps = value("reps") {
            parts.append("\(number(sets))×\(number(reps))")
            rest.removeAll { ["sets", "reps"].contains($0.metric) }
        }
        if let load = value("load_lb") {
            parts.append("@ \(number(load)) lb")
            rest.removeAll { $0.metric == "load_lb" }
        }
        if let rpe = value("rpe") {
            rest.removeAll { $0.metric == "rpe" }
            return (parts + rest.map(\.display) + ["RPE \(number(rpe))"]).joined(separator: " ")
        }
        return (parts + rest.map(\.display)).joined(separator: " ")
    }

    static func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...1))) }

    /// FIT-183: "45 s" for a hold, "25 min" from two minutes up.
    static func duration(_ seconds: Double) -> String {
        seconds < 120 ? "\(number(seconds)) s" : "\(number((seconds / 6).rounded() / 10)) min"
    }

    /// "400 m" for a carry or a short repeat, or a run in miles ("2 mi") from half a mile up.
    static func distance(_ meters: Double) -> String {
        meters < 800 ? "\(number(meters)) m" : Running.distance(meters)
    }

    /// One set's amount: reps, or how far and how long ("8 km · 45 min"); nil when it has neither.
    static func amount(reps: Double?, meters: Double?, seconds: Double?) -> String? {
        if let reps { return number(reps) }
        let parts = [meters.map(distance), seconds.map(duration)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "3 × 5", "3 × 45 s", or a single run as just "25 min".
    static func sets(_ count: Double, of amount: String, reps: Bool) -> String {
        count == 1 && !reps ? amount : "\(number(count)) × \(amount)"
    }

    /// FIT-183: a day of runs only, by the first run's kind (its note starts with it, as the server writes it).
    static func run(kind note: String) -> String {
        switch note.lowercased().prefix(while: \.isLetter) {
        case "long": "Slow and steady. The distance is the work."
        case "tempo": "Comfortably hard: a pace you could hold for about an hour."
        case "intervals": "Hard on the repeats, easy on the recoveries."
        case "race": "Race day. Start a little slower than you want to."
        default: "Easy enough to talk the whole way."
        }
    }
}

/// "How did it feel?" on the finish card. It is the session's effort (log.md: 1–10), and it becomes the RPE of
/// sets that weren't rated, so the progression rule (which reads RPE) still has something to go on.
enum Feel: Int, CaseIterable, Identifiable, Sendable {
    case easy, good, hard, brutal
    var id: Int { rawValue }
    var label: String { ["Easy", "Good", "Hard", "Brutal"][rawValue] }
    var effort: Double { [5, 7, 8.5, 10][rawValue] }
    var rpe: Double { [6, 7, 8.5, 10][rawValue] }

    init?(effort: Double?) {
        guard let effort else { return nil }
        self = Self.allCases.min { abs($0.effort - effort) < abs($1.effort - effort) }!
    }
}

extension SessionPlan.Block {
    /// "3 × 5 · 140", a superset "3 × 10+10 · 50", bodyweight "2 × 10", or a run "25 min". Warm-ups aren't counted.
    var dose: String {
        func amount(_ set: SessionPlan.PlannedSet) -> String {
            Coach.amount(reps: set.value("reps"), meters: set.value("distance_m"), seconds: set.value("duration_s")) ?? ""
        }
        let firsts = movements.compactMap(\.working.first)
        guard !firsts.isEmpty else { return "" }
        let loads = Set(firsts.compactMap { $0.value("load_lb") ?? $0.value("load_lb_hand") })
        let load = loads.count == 1 ? " · \(Coach.number(loads.first!))" : ""
        let reps = firsts.contains { $0.value("reps") != nil }
        return Coach.sets(Double(rounds), of: firsts.map(amount).joined(separator: "+"), reps: reps) + load
    }
}
