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

    @Test func outsideDemoNothingIsAnswered() {
        #expect(DemoCloud.coachInvite("K7Q2MX", demo: false) == nil)
        #expect(DemoCloud.acceptCoach("K7Q2MX", demo: false) == nil)
        #expect(DemoCloud.clientInvite(client: "Jess", demo: false) == nil)
    }
}
