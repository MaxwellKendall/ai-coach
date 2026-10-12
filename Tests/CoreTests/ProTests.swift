import Foundation
import Testing
@testable import AICoach

/// FIT-120: the trial's reminder and timeline. Buying Pro is checked against AICoach.storekit by running from Xcode
/// (StoreKit testing isn't active in command-line test runs here: no products load, purchases fail "notEntitled"),
/// and in the sandbox on TestFlight.
struct ProTests {
    @Test func theReminderComesTwoDaysBeforeTheTrialEnds() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ends = now.addingTimeInterval(14 * 24 * 3600)
        #expect(Pro.reminderDate(trialEnds: ends, now: now) == ends.addingTimeInterval(-2 * 24 * 3600))
        // A day before the end, it's too late to remind.
        #expect(Pro.reminderDate(trialEnds: now.addingTimeInterval(24 * 3600), now: now) == nil)
    }

    @Test func theTimelineSaysWhenItsBilled() {
        let steps = PaywallView.timeline(trialDays: Pro.trialDays)
        #expect(steps.map(\.day) == ["Today", "Day 12", "Day 14"])
    }

    @Test func theAnnualTrialIsTwoWeeks() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../AICoach.storekit")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"subscriptionPeriod\": \"P2W\""))
    }
}
