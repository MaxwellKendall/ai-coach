/// FIT-215: the coach pilot's athlete app is free and simple. One switch in code, not a setting: on, it hides Pro
/// (the paywall, StoreKit, gifts), the in-app AI (program design, the coach, spoken edits), voice, and groups (live
/// workouts, Train with a Friend, shared programs). Nothing is deleted; turning it off brings them all back.
enum Pilot {
    static let simple = true

    /// Pro is sold and gates the program; off, everything Pro gated is free.
    static var sellsPro: Bool { !simple }
    /// FIT-122: Pro given as a gift, bought on the web.
    static var gifts: Bool { sellsPro }
    /// The on-device model and Claude through our server, and with them voice (spoken entry needs the model).
    static var inAppAI: Bool { !simple }
    /// Groups, live workouts, and sessions or programs shared with friends.
    static var groups: Bool { !simple }
}

/// FIT-422 (author, 2026-11-11): where a week's sessions come from. Code for a free lifter, the AI for a Pro lifter (our
/// tokens, business model v2's "models cost money"), and the coach's weeks for a client, Pro or not: the app's AI
/// stays out of a coach's weeks.
enum WeekSource: Equatable, Sendable {
    case code, ai, coach

    /// Nil when there's nothing to plan from: FIT-201, in the pilot the app plans only for a program of its own.
    static func of(lifterPro: Bool, coached: Bool, hasProgram: Bool) -> WeekSource? {
        if coached { return .coach }
        guard hasProgram || !Pilot.simple else { return nil }
        return lifterPro ? .ai : .code
    }

    /// The app plans the week itself, by code or the AI; the coach's weeks are the coach's.
    var plansItself: Bool { self != .coach }
}
