import Testing
@testable import AICoach

/// FIT-445: the tabs each role sees, decided in one place.
struct AppModeTests {
    private let athlete: [AppTab] = [.today, .program, .progress]

    @Test func aCoachWhoDoesntTrainSeesClientsAlone() {
        let mode = AppMode(choseCoaching: true, coached: false, realClients: false, trains: false)
        #expect(mode.coach)
        #expect(mode.tabs == [.clients])
    }

    @Test func aCoachWhoTrainsSeesClientsFirst() {
        #expect(AppMode(choseCoaching: true, coached: false, realClients: true, trains: true).tabs == [.clients] + athlete)
    }

    @Test func aCoachedClientSeesNoClients() {
        #expect(AppMode(choseCoaching: false, coached: true, realClients: false, trains: true).tabs == athlete)
    }

    /// The bug: the server's sample client made a coached client a coach, and Clients opened at launch.
    @Test func aSampleRosterNeverMakesAClientACoach() {
        let mode = AppMode(choseCoaching: true, coached: true, realClients: false, trains: true)
        #expect(!mode.coach)
        #expect(!mode.tabs.contains(.clients))
        // Someone coached who really coaches others too keeps both.
        #expect(AppMode(choseCoaching: true, coached: true, realClients: true, trains: true).tabs == [.clients] + athlete)
    }

    @Test func aLifterOnTheirOwnSeesTheThreeTabs() {
        #expect(AppMode(choseCoaching: false, coached: false, realClients: false, trains: true).tabs == athlete)
        // Signed out, or with no program yet: still the three, never Clients.
        #expect(AppMode(choseCoaching: false, coached: false, realClients: false, trains: false).tabs == athlete)
    }

    @Test func aHiddenTabIsReplacedByTheFirstShown() {
        let client = AppMode(choseCoaching: false, coached: true, realClients: false, trains: true)
        #expect(client.replacing(.clients) == .today)
        #expect(client.replacing(.program) == nil)
        #expect(client.replacing(.coach) == nil)
        #expect(AppMode(choseCoaching: true, coached: false, realClients: false, trains: false).replacing(.today) == .clients)
    }

    @Test func theServersSampleClientIsKnownByItsUID() {
        #expect(Cloud.Person(uid: "sample-mike-abc", name: "Mike Torres (sample)", since: "").isSample)
        #expect(!Cloud.Person(uid: "0f3a-real-sub", name: "Ann", since: "").isSample)
    }
}
