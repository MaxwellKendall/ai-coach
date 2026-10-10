import Foundation

/// FIT-83: what the free plan includes before Pro. Pro is more coaching, not a smarter model; the whole loop stays
/// free, and a few redesigns of the week a month.
enum FreeLimits {
    /// Week redesigns a calendar month on the free plan: the Regenerate sheet's new version and each Try another.
    static let redesignsPerMonth = 3

    /// Redesigns left this month, from the dates of the ones used.
    static func redesignsLeft(_ used: [Date], now: Date = .now, calendar: Calendar = .current) -> Int {
        let thisMonth = used.filter { calendar.isDate($0, equalTo: now, toGranularity: .month) }.count
        return max(0, redesignsPerMonth - thisMonth)
    }
}
