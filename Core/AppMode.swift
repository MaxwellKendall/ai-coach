/// The app's tabs (FIT-64). The coach sits in the slot iOS 26 keeps for Search.
enum AppTab: Hashable {
    case clients, today, program, progress, groups, coach
}

/// FIT-445: who's using the app, decided in one place: a coach, a coached client, or a lifter on their own. The tab
/// bar, and so every coach-only screen, follows from it. Groups and the coach keep their own `Pilot` switches.
struct AppMode: Equatable, Sendable {
    /// Signed in and chose coach mode: the coach door, or real clients of their own (FIT-298).
    var choseCoaching: Bool
    /// Has a coach of their own (`Pro.coaches`, FIT-130).
    var coached: Bool
    /// Coaches someone who isn't a sample client (FIT-240): the server's Mike never makes anyone a coach.
    var realClients: Bool
    /// FIT-381: a program of their own, anything planned, or a coach of their own.
    var trains: Bool

    /// A coached client is shown Clients only once they really coach someone, so a sample roster left from before
    /// FIT-445 can't turn a client into a coach.
    var coach: Bool { choseCoaching && (!coached || realClients) }

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
