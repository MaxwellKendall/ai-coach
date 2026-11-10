import Foundation

/// FIT-344: the weekly check-in coaches ask for, kept short: four 1–5 ratings and two optional answers. Saved as one
/// log row a week (kind `checkin`, the ratings as measurements, the answers as its note), on the check-in day the
/// coach chose (the `checkin` unit; a day number, 0 = Monday … 6 = Sunday, as profiles keep days; Sunday when none). The week's weight and sessions are
/// worked out from the logs when shown, never asked or stored (principle 6). The coach's flags are Triage's.
enum WeeklyCheckIn {
    struct Rating: Identifiable, Sendable {
        var metric: String
        var name: String
        /// What 1 and 5 mean.
        var low: String
        var high: String
        var id: String { metric }
    }

    static let ratings: [Rating] = [
        Rating(metric: "energy_1to5", name: "Energy", low: "Drained", high: "Great"),
        Rating(metric: "stress_1to5", name: "Stress", low: "Calm", high: "Very stressed"),
        Rating(metric: "soreness_1to5", name: "Soreness", low: "None", high: "Very sore"),
        Rating(metric: "adherence_1to5", name: "Followed the plan", low: "Not at all", high: "All of it"),
    ]

    /// Sunday (day 6), when the coach hasn't chosen a day.
    static let defaultDay = 6

    /// The week's check-in day: the chosen day in the Sunday-to-Saturday week with `date` (Week.start's weeks).
    static func due(_ day: Int, weekOf date: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: Week.offset(min(6, max(0, day))), to: Week.start(of: date, calendar: calendar))!
    }

    /// Whether Today asks for it: from the week's check-in day to its Saturday, until that week has one.
    static func isDue(_ day: Int, today: Date, done: Bool, calendar: Calendar = .current) -> Bool {
        !done && calendar.startOfDay(for: today) >= due(day, weekOf: today, calendar: calendar)
    }

    /// The reminder: every week on the check-in day at 9 am (a calendar weekday runs 1 = Sunday to 7 = Saturday).
    static func reminder(_ day: Int) -> DateComponents {
        DateComponents(hour: 9, minute: 0, weekday: Week.offset(min(6, max(0, day))) + 1)
    }

    /// Ratings worth the coach's look: energy or following the plan at 2 or under, stress or soreness at 4 or over.
    /// As shared/triage.ts reads them.
    static func concerns(_ values: [String: Double]) -> [String] {
        var out: [String] = []
        if let v = values["energy_1to5"], v <= 2 { out.append("low energy") }
        if let v = values["stress_1to5"], v >= 4 { out.append("high stress") }
        if let v = values["soreness_1to5"], v >= 4 { out.append("very sore") }
        if let v = values["adherence_1to5"], v <= 2 { out.append("off the plan") }
        return out
    }

    private static let wentWell = "What went well: "
    private static let wasHard = "What was hard: "

    /// The two answers as the row's note, each on its own line with its question, so it reads anywhere a note shows.
    static func note(wentWell well: String, wasHard hard: String) -> String {
        [(wentWell, well), (wasHard, hard)].compactMap { label, text in
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
            return text.isEmpty ? nil : label + text
        }.joined(separator: "\n")
    }

    /// The two answers back from a note, to change them.
    static func answers(_ note: String) -> (wentWell: String, wasHard: String) {
        var well = "", hard = ""
        for line in note.split(separator: "\n").map(String.init) {
            if line.hasPrefix(wentWell) { well = String(line.dropFirst(wentWell.count)) }
            else if line.hasPrefix(wasHard) { hard = String(line.dropFirst(wasHard.count)) }
        }
        return (well, hard)
    }

    /// "Energy 4 · Stress 2 · Soreness 3 · Plan 5", as the coach's notification reads (push.ts checkInText).
    static func summary(_ values: [String: Double]) -> String {
        ratings.compactMap { rating in
            values[rating.metric].map { "\(rating.metric == "adherence_1to5" ? "Plan" : rating.name) \(Coach.number($0))" }
        }.joined(separator: " · ")
    }

    /// The `checkin` unit's body: the coach's chosen day, 0 = Monday … 6 = Sunday.
    struct Day: Codable, Equatable, Sendable {
        var day: Int
    }
}
