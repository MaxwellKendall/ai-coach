import Foundation

/// FIT-8: the week in numbers, alerts and the 4-week goal check-in, all from logs (fitness-planner commands/review.md).
/// The on-device model only writes a paragraph about these numbers.
enum WeeklyReview {
    /// FIT-8's alert thresholds.
    static let proteinFloor = 120.0
    static let sleepFloor = 6.0
    static let kcalFloor = 2_200.0
    static let painNotes = 3

    /// Workouts done against planned, sets, and daily averages over days where each was logged.
    struct Numbers: Equatable, Sendable {
        var workoutsDone: Int
        var workoutsPlanned: Int
        var sets: Int
        var protein: Double?
        var kcal: Double?
        var sleep: Double?
        var weight: Double?
        var weightChange: Double?
        var push = 0
        var pull = 0
    }

    struct Alert: Equatable, Sendable {
        var title: String
        var detail: String
        /// A body area the notes keep naming; the review offers to add it as an injury.
        var area: String?
    }

    /// One goal over the week.
    struct GoalWeek: Equatable, Sendable {
        var from: Double
        var to: Double
        var target: Double
        var pace: GoalProgress.Pace
    }

    /// A proposed new target. Goals are user-owned, so nothing changes unless it's picked.
    struct CheckIn: Equatable, Sendable {
        var proposed: Double
        /// Ahead offers to raise the goal; behind offers to keep it, or move it to where this pace lands.
        var ahead: Bool
        var weeksLeft: Int
    }

    /// The days this review covers: Monday to Sunday of `date`'s week.
    static func days(of date: Date, calendar: Calendar = .current) -> Range<Date> {
        let monday = Week.monday(of: date, calendar: calendar)
        return monday..<calendar.date(byAdding: .day, value: 7, to: monday)!
    }

    static func numbers(week: Range<Date>, workoutDays planned: [Date], sets: [LoggedSet], protein: [DatedValue],
                        kcal: [DatedValue], sleep: [DatedValue], weighIns: [DatedValue], calendar: Calendar = .current) -> Numbers {
        let done = Set(sets.filter { week.contains($0.date) }.map { calendar.startOfDay(for: $0.date) })
        let inWeek = sets.filter { week.contains($0.date) }
        func average(_ values: [DatedValue]) -> Double? {
            let values = values.filter { week.contains($0.date) }.map(\.value)
            return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
        let sorted = weighIns.sorted { $0.date < $1.date }
        let last = sorted.last { week.contains($0.date) }
        let before = sorted.last { $0.date < week.lowerBound }
        return Numbers(workoutsDone: done.count,
                       workoutsPlanned: Set(planned.filter(week.contains).map(calendar.startOfDay)).union(done).count,
                       sets: inWeek.count, protein: average(protein), kcal: average(kcal), sleep: average(sleep),
                       weight: last?.value, weightChange: last.flatMap { last in before.map { last.value - $0.value } },
                       push: inWeek.filter { $0.pattern == "push" }.count, pull: inWeek.filter { $0.pattern == "pull" }.count)
    }

    /// FIT-8's alerts for the week. `workoutDays` are days with a session; daily values are per-day totals.
    /// Pain is counted in notes from the 4 weeks to the week's end, for areas not already marked injured.
    static func alerts(week: Range<Date>, workoutDays: [Date], protein: [DatedValue], kcal: [DatedValue],
                       sleep: [DatedValue], notes: [(date: Date, text: String)], injured: [String],
                       calendar: Calendar = .current) -> [Alert] {
        let sessions = Set(workoutDays.filter(week.contains).map(calendar.startOfDay)).sorted()
        func day(_ date: Date) -> String { date.formatted(.dateTime.weekday(.wide)) }
        func on(_ values: [DatedValue], _ date: Date) -> Double? {
            values.first { calendar.isDate($0.date, inSameDayAs: date) }?.value
        }
        var alerts: [Alert] = []

        // Protein within a day of a session: the day before or the day of, whichever was lower.
        let lowProtein: [(Date, Double)] = sessions.compactMap { session in
            let before = calendar.date(byAdding: .day, value: -1, to: session)!
            let low = [before, session].compactMap { date in on(protein, date).map { (date, $0) } }.min { $0.1 < $1.1 }
            return low.flatMap { $0.1 < proteinFloor ? $0 : nil }
        }
        if !lowProtein.isEmpty {
            alerts.append(Alert(title: "Protein under \(Int(proteinFloor)) g around \(count(lowProtein.count, "workout"))",
                                detail: list(lowProtein.map { "\(day($0.0)) \(Int($0.1.rounded())) g" }) + "."))
        }

        // Sleep is logged on the morning after the night, so the session day's sleep is the night before.
        let shortSleep = sessions.compactMap { session in on(sleep, session).flatMap { $0 < sleepFloor ? (session, $0) : nil } }
        if !shortSleep.isEmpty {
            alerts.append(Alert(title: "Under \(Int(sleepFloor)) h of sleep before \(count(shortSleep.count, "workout"))",
                                detail: list(shortSleep.map { "\(day($0.0)) \(Coach.number($0.1)) h" }) + ". Say so on the day and it’ll go easier."))
        }

        let lowKcal = sessions.compactMap { session in on(kcal, session).flatMap { $0 < kcalFloor ? (session, $0) : nil } }
        if !lowKcal.isEmpty {
            alerts.append(Alert(title: "Under \(Int(kcalFloor).formatted()) kcal on \(count(lowKcal.count, "training day"))",
                                detail: list(lowKcal.map { "\(day($0.0)) \(Int($0.1.rounded()).formatted())" }) + "."))
        }

        let since = calendar.date(byAdding: .day, value: -28, to: week.upperBound)!
        var byArea: [String: [Date]] = [:]
        for note in notes where note.date >= since && note.date < week.upperBound && hurts(note.text) {
            let words = note.text.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
            if let area = BodyArea.mentioned(in: words) { byArea[area, default: []].append(note.date) }
        }
        let known = BodyArea.muscles(for: injured)
        for (area, dates) in byArea.sorted(by: { $0.key < $1.key })
        where dates.count >= painNotes && BodyArea.muscles(for: [area]).isDisjoint(with: known) == true {
            let days = list(dates.sorted().map { $0.formatted(.dateTime.month(.abbreviated).day()) })
            alerts.append(Alert(title: "\(area.prefix(1).uppercased() + area.dropFirst()) came up in \(dates.count) notes",
                                detail: "\(days). Plans can go easier on it until you say it’s fine.", area: area))
        }
        return alerts
    }

    /// Every 4 weeks of the program (not in its last 4), a goal well ahead or behind gets a proposed new target:
    /// where this pace lands by the end, to the goal's step.
    static func checkIn(from start: Double, now: Double, target: Double, pace: GoalProgress.Pace, forecast: Double?,
                        step: Double, week: Int, weeks: Int) -> CheckIn? {
        let done = week + 1, left = weeks - done
        guard done % 4 == 0, left >= 4, let forecast, pace == .ahead || pace == .behind else { return nil }
        let up = target >= start
        let proposed = (forecast / step).rounded() * step
        if pace == .ahead {
            let raised = up ? max(proposed, target + step) : min(proposed, target - step)
            return CheckIn(proposed: raised, ahead: true, weeksLeft: left)
        }
        // Only a target between here and the old one; at or past the goal there's nothing to move to.
        guard up ? (proposed < target && proposed > now) : (proposed > target && proposed < now) else { return nil }
        return CheckIn(proposed: proposed, ahead: false, weeksLeft: left)
    }

    private static func hurts(_ text: String) -> Bool {
        let text = text.lowercased()
        return ["pain", "sore", "hurt", "ache", "tight", "tweak", "twinge", "strain", "sharp", "niggle"].contains { text.contains($0) }
    }

    /// "1 workout", "2 workouts".
    static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    /// "a", "a and b", "a, b and c".
    static func list(_ items: [String]) -> String {
        items.count <= 1 ? items.joined() : items.dropLast().joined(separator: ", ") + " and " + items.last!
    }
}
