import Foundation
import Testing
@testable import AICoach

/// FIT-83: the free plan's redesign limit. Buying Pro is checked against AICoach.storekit by running from Xcode
/// (StoreKit testing isn't active in command-line test runs here: no products load, purchases fail "notEntitled"),
/// and in the sandbox on TestFlight.
struct ProTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func date(_ month: Int, _ day: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: month, day: day))! }

    @Test func threeRedesignsAMonthOnTheFreePlan() {
        let now = date(10, 20)
        #expect(FreeLimits.redesignsLeft([], now: now, calendar: calendar) == 3)
        #expect(FreeLimits.redesignsLeft([date(10, 1), date(10, 9)], now: now, calendar: calendar) == 1)
        #expect(FreeLimits.redesignsLeft([date(10, 1), date(10, 9), date(10, 15), date(10, 19)], now: now, calendar: calendar) == 0)
        // Last month's don't count.
        #expect(FreeLimits.redesignsLeft([date(9, 28), date(9, 29), date(9, 30)], now: now, calendar: calendar) == 3)
    }
}
