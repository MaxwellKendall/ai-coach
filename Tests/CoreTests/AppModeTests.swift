import Testing
@testable import AICoach

/// FIT-445: the tabs each role sees, decided in one place.
struct AppModeTests {
    private let athlete: [AppTab] = [.today, .program, .progress]
    private let mike = Cloud.Person(uid: "sample-mike-abc", name: "Mike Torres (sample)", since: "")
    private let ann = Cloud.Person(uid: "0f3a-real-sub", name: "Ann", since: "")

    @Test func aCoachWhoDoesntTrainSeesClientsAlone() {
        let mode = AppMode(coach: true, trains: false)
        #expect(mode.tabs == [.clients])
    }

    @Test func aCoachWhoTrainsSeesClientsFirst() {
        #expect(AppMode(coach: true, trains: true).tabs == [.clients] + athlete)
    }

    @Test func aClientOrLifterSeesNoClients() {
        #expect(AppMode(coach: false, trains: true).tabs == athlete)
        // Signed out, or with no program yet: still the three, never Clients.
        #expect(AppMode(coach: false, trains: false).tabs == athlete)
    }

    @Test func aHiddenTabIsReplacedByTheFirstShown() {
        let client = AppMode(coach: false, trains: true)
        #expect(client.replacing(.clients) == .today)
        #expect(client.replacing(.program) == nil)
        #expect(client.replacing(.coach) == nil)
        #expect(AppMode(coach: true, trains: false).replacing(.today) == .clients)
    }

    @Test func theServersSampleClientIsKnownByItsUID() {
        #expect(mike.isSample)
        #expect(!ann.isSample)
    }

    /// The bug: the server's sample client made a coached client a coach. Review: a real client does make a coach,
    /// even one coached themselves, so discovering one is enough for Clients to show and load.
    @Test func onlyARealClientMakesACoach() {
        #expect(!AppMode.coaches([]))
        #expect(!AppMode.coaches([mike]))
        #expect(AppMode.coaches([mike, ann]))
    }

    /// Review: against a server from before FIT-445, the old query's sample client is dropped here.
    @Test func theLegacyQuerysSampleIsLeftOut() {
        #expect(Cloud.withoutSample([mike, ann]) == [ann])
        #expect(Cloud.withoutSample([mike]).isEmpty)
    }

    /// Review: coach mode saved before FIT-445 is cleared for a solo lifter or client with only the sample client,
    /// and kept for anyone who really coaches or chose "Go to My Clients" (no program of their own).
    @Test func savedCoachModeIsRepairedForLiftersAndKeptForCoaches() {
        // A solo lifter (a program of their own), or a coached client (trains with their coach), made a coach by Mike.
        #expect(!AppMode.keepsSavedCoaching(clients: [mike], invites: 0, trains: true))
        #expect(!AppMode.keepsSavedCoaching(clients: [], invites: 0, trains: true))
        // Coaches: a real client, an invite out, or Clients alone.
        #expect(AppMode.keepsSavedCoaching(clients: [mike, ann], invites: 0, trains: true))
        #expect(AppMode.keepsSavedCoaching(clients: [mike], invites: 1, trains: true))
        #expect(AppMode.keepsSavedCoaching(clients: [mike], invites: 0, trains: false))
    }
}
