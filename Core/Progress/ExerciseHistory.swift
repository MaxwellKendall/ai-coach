import Foundation

/// FIT-356: what was logged, by day: past sessions, and one exercise's last sessions. Derived from the log (§2.6).
enum ExerciseHistory {
    struct Line: Equatable, Sendable {
        var reps: Double?
        var load: Double?
        var seconds: Double?
        var meters: Double?
    }

    struct Lift: Equatable, Sendable {
        var exercise: String
        var sets: [Line]
        /// The best Brzycki estimate in these sets (`Training.estimated1RM`), if one qualifies.
        var best: Double?
    }

    struct Day: Equatable, Sendable, Identifiable {
        var date: Date
        var lifts: [Lift]
        /// TKL-1087: how it went, in the lifter's own words (the session summary's note); nil when there's none.
        var note: String? = nil
        /// TKL-1087: the coach's note on the day's session (`PlannedActivity.sessionNote`), never merged with `note`.
        var coachNote: String? = nil
        var id: Date { date }
    }

    /// TKL-1087: a note written about a workout, and when.
    struct Note: Equatable, Sendable {
        var date: Date
        var text: String
    }

    /// TKL-1087: every day with lifting, with the lifter's notes and the coach's session notes on the days they fall on.
    /// A day's own notes join in the order written; notes on days without lifting are left out.
    static func days(_ sets: [LoggedSet], notes: [Note], coachNotes: [Note], calendar: Calendar = .current) -> [Day] {
        func byDay(_ notes: [Note]) -> [Date: [String]] {
            Dictionary(grouping: notes.sorted { $0.date < $1.date }.compactMap { note -> Note? in
                let text = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : Note(date: calendar.startOfDay(for: note.date), text: text)
            }, by: \.date).mapValues { $0.map(\.text) }
        }
        let mine = byDay(notes), coach = byDay(coachNotes)
        return days(sets, calendar: calendar).map { day in
            var day = day
            day.note = mine[day.date].map { $0.joined(separator: "\n\n") }
            day.coachNote = coach[day.date]?.first
            return day
        }
    }

    /// TKL-1087: a note's first line with words on it, for the History list.
    static func firstLine(_ note: String) -> String {
        note.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
    }

    /// Every day with lifting, newest first; each day's exercises in the order first logged. With `exercise`, only that
    /// exercise's days.
    static func days(_ sets: [LoggedSet], exercise: String? = nil, calendar: Calendar = .current) -> [Day] {
        let chosen = sets.filter { exercise == nil || $0.exercise == exercise }.sorted { $0.date < $1.date }
        let byDay = Dictionary(grouping: chosen) { calendar.startOfDay(for: $0.date) }
        return byDay.keys.sorted(by: >).map { day in
            let daySets = byDay[day]!
            var order: [String] = []
            for set in daySets where !order.contains(set.exercise) { order.append(set.exercise) }
            return Day(date: day, lifts: order.map { slug in
                let mine = daySets.filter { $0.exercise == slug }
                let best = mine.compactMap { set -> Double? in
                    guard let load = set.value("load_lb"), let reps = set.value("reps") else { return nil }
                    return Training.estimated1RM(loadLb: load, reps: reps, rpe: set.value("rpe"))
                }.max()
                return Lift(exercise: slug, sets: mine.map { Line(reps: $0.value("reps"), load: $0.value("load_lb") ?? $0.value("load_lb_hand"),
                                                                   seconds: $0.value("duration_s"), meters: $0.value("distance_m")) }, best: best)
            })
        }
    }

    /// "3 × 5 @ 170 lb", or set by set where they differ: "5 @ 170 · 5 @ 175 · 3 @ 175 lb". Unloaded: "3 × 10";
    /// held: "3 × 45 s"; carried: "3 × 40 m @ 53".
    static func summary(_ sets: [Line]) -> String {
        guard !sets.isEmpty else { return "" }
        func one(_ line: Line) -> String {
            let count = line.seconds.map { "\(Coach.number($0)) s" } ?? line.meters.map { "\(Coach.number($0)) m" } ?? line.reps.map(Coach.number) ?? "?"
            return line.load.map { "\(count) @ \(Coach.number($0))" } ?? count
        }
        let unit = sets.contains { $0.load != nil } ? " lb" : ""
        if Set(sets.map(one)).count == 1 { return sets.count == 1 ? one(sets[0]) + unit : "\(sets.count) × \(one(sets[0]))\(unit)" }
        return sets.map(one).joined(separator: " · ") + unit
    }
}
