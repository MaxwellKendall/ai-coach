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
        #expect(InviteLink.code(pasted: "Join my group “Dawn Patrol” in Rep & Recipe. https://join.barbrabell.com/X7K2PQ9A") == "X7K2PQ9A")
        #expect(InviteLink.code(pasted: "  a1b2c3d4\n") == "A1B2C3D4")
        #expect(InviteLink.code(pasted: "Let's lift tomorrow") == nil)
        #expect(InviteLink.code(pasted: "https://example.com/X7K2PQ9A") == nil)
    }
}
