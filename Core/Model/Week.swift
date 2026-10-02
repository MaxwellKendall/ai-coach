import Foundation

enum Week {
    /// Start of the Monday on or before `date`, regardless of the locale's first weekday.
    static func monday(of date: Date, calendar: Calendar = .current) -> Date {
        let day = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: day) // 1 = Sunday … 7 = Saturday
        let daysSinceMonday = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -daysSinceMonday, to: day)!
    }
}
