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

    /// FIT-122: a gift's code, however it arrives, and the reminder before its year ends.
    @Test func giftCodesAreReadFromTypingOrTheirLink() {
        #expect(InviteLink.gift("abcd-efgh-jklm") == "ABCDEFGHJKLM")
        #expect(InviteLink.gift(" ABCD EFGH JKLM ") == "ABCDEFGHJKLM")
        #expect(InviteLink.gift(from: URL(string: "https://barbrabell.com/g/ABCDEFGHJKLM")!) == "ABCDEFGHJKLM")
        #expect(InviteLink.gift(from: URL(string: "https://dev.barbrabell.com/g/ABCDEFGHJKLM")!) == "ABCDEFGHJKLM")
        #expect(InviteLink.gift(from: URL(string: "https://example.com/g/ABCDEFGHJKLM")!) == nil)
        #expect(InviteLink.gift(from: URL(string: "https://barbrabell.com/s/ae79125c4c25")!) == nil)
        // 0, 1, I and O aren't in codes.
        #expect(InviteLink.gift("ABCD-EFGH-JKL0") == nil)
        #expect(InviteLink.gift("ABCD") == nil)
    }

    @Test func aGiftsReminderComesTwoWeeksBeforeItEnds() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let until = now.addingTimeInterval(365 * 24 * 3600)
        #expect(Pro.giftReminderDate(until: until, now: now) == until.addingTimeInterval(-14 * 24 * 3600))
        #expect(Pro.giftReminderDate(until: now.addingTimeInterval(7 * 24 * 3600), now: now) == nil)
    }
}
