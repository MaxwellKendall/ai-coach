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

    /// FIT-201: a coach's code typed on first launch, or pasted with the message it came in.
    @Test func typedCoachCodes() {
        #expect(InviteLink.coach(typed: "lt7jw bw6s") == nil)
        #expect(InviteLink.coach(typed: " lt7jw-bw6s2 ") == "LT7JWBW6S2")
        #expect(InviteLink.coach(typed: "Join me: https://barbrabell.com/c/LT7JWBW6S2.") == "LT7JWBW6S2")
        #expect(InviteLink.coach(typed: "https://example.com/c/LT7JWBW6S2") == nil)
        #expect(InviteLink.coach(typed: "LT7JWBW6S0") == nil)
        #expect(InviteLink.coach(typed: "tomorrow") == nil)
        // FIT-234: 6 long now.
        #expect(InviteLink.coach(typed: " k7m-4qx ") == "K7M4QX")
        #expect(InviteLink.coach(typed: "K7M4Q") == nil)
        #expect(InviteLink.coach(typed: "Join me: https://barbrabell.com/c/K7M4QX") == "K7M4QX")
        #expect(InviteLink.coach(from: URL(string: "https://barbrabell.com/c/k7m4qx")!) == "K7M4QX")
    }

    /// FIT-227: a coach with no name is "your coach" in a sentence, never "Your" of a fallback.
    @Test func aCoachWithNoName() {
        #expect(Cloud.CoachInvite(answer: "Sam Coach").name == "Sam Coach")
        #expect(Cloud.CoachInvite(answer: "Your coach").name == nil)
        let nameless = Cloud.Person(uid: "c", name: nil, since: "2026-10-23")
        #expect(nameless.title == "Your coach")
        #expect(nameless.mention == "your coach")
        #expect(Cloud.Person(uid: "c", name: "Sam", since: "2026-10-23").mention == "Sam")
    }
}
