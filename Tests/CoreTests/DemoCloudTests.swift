import Foundation
import Testing
@testable import AICoach

/// TKL-460: the review demo's chapters accept a coach's invite and make a client invite with no server, and only in
/// demo mode: outside it every answer is nil, so the real call runs.
@MainActor
struct DemoCloudTests {
    @Test func demoAnswersTheInviteAndAcceptsIt() throws {
        #expect(DemoCloud.coachInvite("K7Q2MX", demo: true) == Cloud.CoachInvite(answer: "Sam Rivera"))
        let coach = try #require(DemoCloud.acceptCoach("K7Q2MX", demo: true))
        #expect(coach.name == "Sam Rivera")
        #expect(!coach.uid.isEmpty)
    }

    @Test func demoMakesAClientInviteForWhoItIsFor() throws {
        let invite = try #require(DemoCloud.clientInvite(client: "Jess Park", demo: true))
        #expect(invite.url.hasSuffix("/\(invite.code)"))
        #expect(invite.client == "Jess Park")
        #expect(DemoCloud.clientInvite(client: "", demo: true)?.client == nil)
    }

    /// TKL-460 round 2: `-demoSignedOut YES` opens the demo signed out, so a chapter shows signing in; any email then
    /// signs in locally, as that email, with no server.
    @Test func demoSignsInLocallyWhenItStartsSignedOut() throws {
        #expect(DemoCloud.user(signedOut: true, email: nil) == nil)
        let signedIn = try #require(DemoCloud.user(signedOut: true, email: "Coach@Example.com "))
        #expect(signedIn.email == "coach@example.com")
        #expect(signedIn.uid == DemoCloud.uid)
        // Without the flag the demo is signed in at launch, as before.
        #expect(DemoCloud.user(signedOut: false, email: nil)?.uid == DemoCloud.uid)
    }

    @Test func outsideDemoNothingIsAnswered() {
        #expect(DemoCloud.coachInvite("K7Q2MX", demo: false) == nil)
        #expect(DemoCloud.acceptCoach("K7Q2MX", demo: false) == nil)
        #expect(DemoCloud.clientInvite(client: "Jess", demo: false) == nil)
    }
}
