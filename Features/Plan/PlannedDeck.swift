import Foundation

/// The week cards the Program tab shows without a program of the app's (FIT-202, TKL-845).
enum PlannedDeck {
    /// A coach's client: every week from the first planned through this one or the last planned, whichever is later
    /// (none when nothing's planned). On their own: this week and next, planned or not.
    static func mondays(planned: [Date], this: Date, coached: Bool, calendar: Calendar = .current) -> [Date] {
        let next = { (monday: Date) in calendar.date(byAdding: .day, value: 7, to: monday)! }
        guard coached else { return [this, next(this)] }
        let weeks = Set(planned.map { Week.start(of: $0, calendar: calendar) })
        guard let first = weeks.min(), let last = weeks.max() else { return [] }
        return Array(sequence(first: min(first, this), next: next).prefix { $0 <= max(last, this) })
    }
}
