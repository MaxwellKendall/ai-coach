/// The app's tabs (FIT-64). The coach sits in the slot iOS 26 keeps for Search.
enum AppTab: Hashable {
    case clients, today, program, progress, groups, coach
}

/// FIT-445: who's using the app, decided in one place: a coach, a coached client, or a lifter on their own. The tab
/// bar, and so every coach-only screen, follows from it. Groups and the coach keep their own `Pilot` switches.
struct AppMode: Equatable, Sendable {
    /// Coach mode, for this account: the coach door ("Go to My Clients" or "Train on my own too", even for someone
    /// coached themselves), a real client found, or coach mode saved before FIT-445 that `keepsSavedCoaching` kept.
    var coach: Bool
    /// FIT-381: a program of their own, anything planned, or a coach of their own.
    var trains: Bool

    /// Whom `Cloud.myClients` found: coaching anyone but the server's sample client (FIT-240) makes a coach.
    static func coaches(_ clients: [Cloud.Person]) -> Bool { clients.contains { !$0.isSample } }

    /// Coach mode saved before FIT-445, when the launch's check counted the sample client the server makes for anyone
    /// with no clients, so it turned clients and solo lifters into coaches. It's kept for someone who really coaches
    /// (a real client or an invite out), or who doesn't train, as "Go to My Clients" leaves a coach; anyone who trains
    /// with only the sample client goes back to the athlete's tabs, and signing in again by the coach door brings it back.
    static func keepsSavedCoaching(clients: [Cloud.Person], invites: Int, trains: Bool) -> Bool {
        coaches(clients) || invites > 0 || !trains
    }

    /// In the tab bar's order. FIT-381: a coach who doesn't train sees Clients alone.
    var tabs: [AppTab] {
        (coach ? [.clients] : []) + (!coach || trains ? [.today, .program, .progress] : [])
    }

    /// The tab to show when `selected` isn't in the bar any more; nil when it still is. The coach and groups tabs
    /// aren't this type's to hide.
    func replacing(_ selected: AppTab) -> AppTab? {
        guard selected != .coach, selected != .groups, !tabs.contains(selected) else { return nil }
        return tabs.first
    }
}
