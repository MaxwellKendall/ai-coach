import Foundation
import Testing
@testable import AICoach

/// FIT-372: Messages' dot is the coach's words not yet read on this phone, never my own.
struct CoachMessagesTests {
    private func comment(_ at: String, by: String) -> Cloud.Comment {
        Cloud.Comment(day: "2026-11-10", at: at, by: by, byName: nil, text: "Keep the bar speed up")
    }

    private let read = CoachMessages.date("2026-11-10T18:00:00Z")

    @Test func theCoachsNewerMessageIsUnread() {
        #expect(CoachMessages.unread([comment("2026-11-10T18:00:01.250Z", by: "coach")], me: "me", readAt: read))
    }

    @Test func whatWasReadIsnt() {
        #expect(!CoachMessages.unread([comment("2026-11-10T18:00:00Z", by: "coach"), comment("2026-11-10T09:00:00Z", by: "coach")],
                                      me: "me", readAt: read))
    }

    @Test func myOwnMessagesNeverAre() {
        #expect(!CoachMessages.unread([comment("2026-11-11T08:00:00Z", by: "me")], me: "me", readAt: read))
        #expect(!CoachMessages.unread([comment("2026-11-11T08:00:00Z", by: "me")], me: "me", readAt: nil))
    }

    @Test func neverReadHereAnyOfTheirsIs() {
        #expect(CoachMessages.unread([comment("2026-10-01T08:00:00Z", by: "coach")], me: "me", readAt: nil))
        #expect(!CoachMessages.unread([], me: "me", readAt: nil))
    }
}
