import Foundation
import Testing
@testable import AICoach

/// FIT-58: which links the app opens as invites.
struct InviteLinkTests {
    private func code(_ link: String) -> String? { InviteLink.code(from: URL(string: link)!) }

    @Test func invitesOnTheJoinHostOrUnderJoin() {
        #expect(code("https://join.barbrabell.com/x7k2pq9a") == "X7K2PQ9A")
        #expect(code("https://barbrabell.com/join/X7K2PQ9A") == "X7K2PQ9A")
        #expect(code("https://dev.barbrabell.com/join/X7K2PQ9A") == "X7K2PQ9A")
    }

    @Test func notInvites() {
        #expect(code("https://share.barbrabell.com/w/abc123def456") == nil)
        #expect(code("https://barbrabell.com/X7K2PQ9A") == nil)
        #expect(code("https://join.barbrabell.com/") == nil)
        #expect(code("https://join.barbrabell.com/SHORT") == nil)
        #expect(code("https://join.evil.com/X7K2PQ9A") == nil)
        #expect(code("http://join.barbrabell.com/X7K2PQ9A") == nil)
    }

    @Test func sharedInvitesPointAtThisBuildsBackend() {
        #expect(InviteLink.url(code: "X7K2PQ9A").absoluteString == "https://dev.barbrabell.com/join/X7K2PQ9A")
    }

    /// FIT-109: what's pasted after installing from the invite page.
    @Test func aPastedLinkMessageOrCode() {
        #expect(InviteLink.code(pasted: "https://join.barbrabell.com/X7K2PQ9A") == "X7K2PQ9A")
        #expect(InviteLink.code(pasted: "Join my group “Dawn Patrol” in Barbrabell. https://join.barbrabell.com/X7K2PQ9A") == "X7K2PQ9A")
        #expect(InviteLink.code(pasted: "  a1b2c3d4\n") == "A1B2C3D4")
        #expect(InviteLink.code(pasted: "Let's lift tomorrow") == nil)
        #expect(InviteLink.code(pasted: "https://example.com/X7K2PQ9A") == nil)
    }
}

/// FIT-113: shared sessions' links.
struct SessionLinkTests {
    @Test func aSessionLinkOnAnyOfOurHosts() {
        #expect(InviteLink.session(from: URL(string: "https://share.barbrabell.com/s/ae79125c4c25")!) == "ae79125c4c25")
        #expect(InviteLink.session(from: URL(string: "https://barbrabell.com/s/AE79125C4C25")!) == "ae79125c4c25")
        #expect(InviteLink.session(from: URL(string: "https://barbrabell.com/w/ae79125c4c25")!) == nil)
        #expect(InviteLink.session(from: URL(string: "https://evil.com/s/ae79125c4c25")!) == nil)
        #expect(InviteLink.session(pasted: "Train with me: Lower body, Thursday https://share.barbrabell.com/s/ae79125c4c25") == "ae79125c4c25")
    }

    @Test func theSharersTimeOfDay() {
        #expect(JoinSessionSheet.time("6:00\u{202F}AM") == DateComponents(hour: 6, minute: 0))
        #expect(JoinSessionSheet.time("5:30 PM") == DateComponents(hour: 17, minute: 30))
        #expect(JoinSessionSheet.time("dawn") == nil)
    }

    /// FIT-130: a coach's invite, barbrabell.com/c/CODE, on any of the app's hosts.
    @Test func coachInvites() {
        #expect(InviteLink.coach(from: URL(string: "https://dev.barbrabell.com/c/LT7JWBW6S2")!) == "LT7JWBW6S2")
        #expect(InviteLink.coach(from: URL(string: "https://barbrabell.com/c/lt7jwbw6s2")!) == "LT7JWBW6S2")
        #expect(InviteLink.coach(from: URL(string: "https://barbrabell.com/c/LT7JWBW6S")!) == nil)
        #expect(InviteLink.coach(from: URL(string: "https://barbrabell.com/c/LT7JWBW6S0")!) == nil)
        #expect(InviteLink.coach(from: URL(string: "https://example.com/c/LT7JWBW6S2")!) == nil)
        #expect(InviteLink.code(from: URL(string: "https://barbrabell.com/c/LT7JWBW6S2")!) == nil)
    }
}
