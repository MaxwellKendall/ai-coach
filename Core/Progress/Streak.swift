import Foundation

/// FIT-121: weeks in a row with every planned session done. Rest days are part of a program, so the unit is the week,
/// not the day. A week is full when it has as many days trained as sessions planned: a session moved keeps its new
/// day, and a missed one can be made up on another day that week. A week with nothing planned neither adds nor breaks.
/// Derived from plans and logs, never stored.
enum Streak {
    struct Status: Equatable, Sendable {
        /// Full weeks in a row up to now, this week included once it's full.
        var weeks: Int
        var thisWeek: ThisWeek
    }

    enum ThisWeek: Equatable, Sendable {
        /// Every session so far done (or nothing planned).
        case onTrack
        /// Every planned session done.
        case full
        /// Planned days gone by without a workout, while there are still days to make them up before the week ends.
        case atRisk(missed: [Date], lastDay: Date)
        /// Too many missed to make up: the streak ends with this week.
        case broken
    }

    static func status(since start: Date, plannedDays: [Date], workoutDays: [Date], today: Date = .now,
                       calendar: Calendar = .current) -> Status {
        let planned = Set(plannedDays.map(calendar.startOfDay)), done = Set(workoutDays.map(calendar.startOfDay))
        let thisWeek = ProgramPlan.week(of: today, start: start, calendar: calendar)
        var weeks = 0
        for week in 0..<max(0, thisWeek) {
            if let full = full(week, start: start, planned: planned, done: done, calendar: calendar) { weeks = full ? weeks + 1 : 0 }
        }
        guard thisWeek >= 0 else { return Status(weeks: 0, thisWeek: .onTrack) }

        let monday = ProgramPlan.monday(thisWeek, start: start, calendar: calendar)
        let next = ProgramPlan.monday(thisWeek + 1, start: start, calendar: calendar)
        let days = planned.filter { $0 >= monday && $0 < next }
        let trained = done.filter { $0 >= monday && $0 < next }
        if !days.isEmpty && trained.count >= days.count { return Status(weeks: weeks + 1, thisWeek: .full) }
        let day = calendar.startOfDay(for: today)
        let missed = days.filter { $0 < day && !done.contains($0) }.sorted()
        guard !missed.isEmpty else { return Status(weeks: weeks, thisWeek: .onTrack) }
        // Days left to train, today included unless it's already trained.
        let left = (calendar.dateComponents([.day], from: day, to: next).day ?? 0) - (done.contains(day) ? 1 : 0)
        let lastDay = calendar.date(byAdding: .day, value: -1, to: next)!
        return Status(weeks: weeks, thisWeek: trained.count + left >= days.count ? .atRisk(missed: missed, lastDay: lastDay) : .broken)
    }

    /// Whether program week `week` was full; nil when it had nothing planned.
    static func full(_ week: Int, start: Date, planned: Set<Date>, done: Set<Date>, calendar: Calendar) -> Bool? {
        let monday = ProgramPlan.monday(week, start: start, calendar: calendar)
        let next = ProgramPlan.monday(week + 1, start: start, calendar: calendar)
        let days = planned.filter { $0 >= monday && $0 < next }
        guard !days.isEmpty else { return nil }
        return done.filter { $0 >= monday && $0 < next }.count >= days.count
    }

    /// Today's line: "4 weeks in a row", or what keeps it going: "Do Thursday’s session by Saturday to make it 6 weeks in a row".
    /// Nothing before there are 2 weeks to keep, or once it can't be kept.
    static func line(_ status: Status, today: Date = .now, calendar: Calendar = .current) -> String? {
        switch status.thisWeek {
        case .full, .onTrack:
            return status.weeks >= 2 ? "\(status.weeks) weeks in a row" : nil
        case .atRisk(let missed, let lastDay):
            guard status.weeks >= 1 else { return nil }
            var weekday = Date.FormatStyle.dateTime.weekday(.wide)
            weekday.timeZone = calendar.timeZone
            let names = missed.map { $0.formatted(weekday) + "’s" }
            let what = missed.count == 1 ? "\(names[0]) session" : "\(WeeklyReview.list(names)) sessions"
            let by = calendar.isDate(today, inSameDayAs: lastDay) ? "today" : "by \(lastDay.formatted(weekday))"
            return "Do \(what) \(by) to make it \(status.weeks + 1) weeks in a row"
        case .broken:
            return nil
        }
    }
}
