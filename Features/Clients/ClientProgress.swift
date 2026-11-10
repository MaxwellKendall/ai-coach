import Foundation

/// FIT-337: a client's progress, derived from their sync units and never stored (principle 6): their logged sets for
/// the app's own progress rules (GoalProgress, Training), weigh-ins and sleep, goals, and each week's sessions done of
/// planned.
enum ClientProgress {
    /// Every logged set with an exercise, oldest first, as Planner.loggedSets makes them from one's own log.
    static func sets(_ units: [String: String], patterns: [String: String] = [:]) -> [LoggedSet] {
        logs(units).filter { $0.kind == .workout }.compactMap { row in
            row.template.map { LoggedSet(date: row.at, exercise: $0, pattern: patterns[$0], measurements: row.measurements) }
        }
        .sorted { $0.date < $1.date }
    }

    /// A check-in measurement over time: "weight_lb" from weigh-ins, "sleep_h" from sleep (FIT-223).
    static func checkIns(_ units: [String: String], _ metric: String) -> [DatedValue] {
        logs(units).filter { $0.kind == .bodyweight || $0.kind == .sleep }.compactMap { row in
            row.measurements.first { $0.metric == metric }.map { DatedValue(date: row.at, value: $0.value) }
        }
        .sorted { $0.date < $1.date }
    }

    /// The check-ins' own words, newest first.
    static func notes(_ units: [String: String]) -> [(date: Date, text: String)] {
        var notes: [(date: Date, text: String)] = []
        for row in logs(units).sorted(by: { $0.at > $1.at }) where row.kind == .bodyweight || row.kind == .sleep {
            let text = row.note.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty && !notes.contains(where: { $0.text == text }) { notes.append((row.at, text)) }
        }
        return notes
    }

    /// Their goals still being worked on.
    static func goals(_ units: [String: String]) -> [SyncUnits.GoalBody] {
        units.filter { $0.key.hasPrefix("goal#") }.compactMap { try? SyncUnits.decode(SyncUnits.GoalBody.self, $0.value) }
            .filter { $0.status == .active }
            .sorted { $0.metric < $1.metric }
    }

    /// The lifts they've logged most, for the progress charts: up to `count`, by sets logged.
    static func mainLifts(_ sets: [LoggedSet], count: Int = 3) -> [String] {
        var counts: [String: Int] = [:]
        for set in sets where set.value("load_lb") != nil && set.value("reps") != nil { counts[set.exercise, default: 0] += 1 }
        let ranked = counts.sorted { a, b in a.value == b.value ? a.key < b.key : a.value > b.value }
        return ranked.prefix(count).map(\.key)
    }

    struct WeekCount: Equatable {
        var sunday: Date
        var done: Int
        var planned: Int
    }

    /// Each of the last `weeks` weeks to the one with `today`: days trained, and days with a session planned or trained.
    static func weeks(_ units: [String: String], today: Date, weeks: Int = 8, calendar: Calendar = .current) -> [WeekCount] {
        let thisWeek = Week.start(of: today, calendar: calendar)
        return (0..<weeks).reversed().map { back in
            let sunday = calendar.date(byAdding: .day, value: -7 * back, to: thisWeek)!
            let days = (0..<7).map { SyncUnits.day(calendar.date(byAdding: .day, value: $0, to: sunday)!, calendar: calendar) }
            let done = days.filter { ClientDay.trained(units, $0) }.count
            let planned = days.filter { ClientDay.trained(units, $0) || ClientDay.planned(units, $0) }.count
            return WeekCount(sunday: sunday, done: done, planned: planned)
        }
    }

    private static func logs(_ units: [String: String]) -> [SyncUnits.LogRow] {
        units.keys.filter { $0.hasPrefix("log#") }.flatMap { ClientDay.log(units, String($0.dropFirst(4))) }
    }
}
