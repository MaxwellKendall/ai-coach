import Foundation

/// The week runs Sunday to Saturday (FIT-82, the author's call), whatever the locale's first weekday. Day numbers
/// stay 0 = Monday … 6 = Sunday, as profiles store them; `offset` places one in a week.
enum Week {
    /// Start of the Sunday on or before `date`.
    static func start(of date: Date, calendar: Calendar = .current) -> Date {
        let day = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: day) // 1 = Sunday … 7 = Saturday
        return calendar.date(byAdding: .day, value: -(weekday - 1), to: day)!
    }

    /// Days from the week's Sunday to day number `day` (0 = Monday): Sunday 0, Monday 1 … Saturday 6.
    static func offset(_ day: Int) -> Int { (day + 1) % 7 }

    /// The day number (0 = Monday) of a date.
    static func day(of date: Date, calendar: Calendar = .current) -> Int {
        (calendar.component(.weekday, from: date) + 5) % 7
    }

    /// The date of day number `day` in the week starting `start`.
    static func date(_ day: Int, in start: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: offset(day), to: start)!
    }

    /// Day numbers in the order the week runs: Sunday first.
    static let order = [6, 0, 1, 2, 3, 4, 5]

    /// Day numbers sorted as the week runs.
    static func ordered(_ days: some Sequence<Int>) -> [Int] { days.sorted { offset($0) < offset($1) } }
}
