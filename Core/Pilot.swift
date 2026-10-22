/// FIT-215: the coach pilot's athlete app is free and simple. One switch in code, not a setting: on, it hides Pro
/// (the paywall, StoreKit, gifts), the in-app AI (program design, the coach, spoken edits), voice, and groups (live
/// workouts, Train with a Friend, shared programs). Nothing is deleted; turning it off brings them all back.
enum Pilot {
    static let simple = true

    /// Pro is sold and gates the program; off, everything Pro gated is free.
    static var sellsPro: Bool { !simple }
    /// The on-device model and Claude through our server, and with them voice (spoken entry needs the model).
    static var inAppAI: Bool { !simple }
    /// Groups, live workouts, and sessions or programs shared with friends.
    static var groups: Bool { !simple }
}
