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
}
