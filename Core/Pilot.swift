/// FIT-215: the coach pilot's athlete app is free and simple. One switch in code, not a setting: on, it hides Pro
/// (the paywall, StoreKit, gifts), the in-app AI (program design, the coach, spoken edits), voice, and groups (live
/// workouts, Train with a Friend, shared programs). Nothing is deleted; turning it off brings them all back.
enum Pilot {
    static let simple = true

    /// Pro is sold and gates the program; off, everything Pro gated is free. FIT-267: the consumer app sells its plan,
    /// as a hard paywall after the program is picked.
    static var sellsPro: Bool { !simple || Edition.consumer }
    /// FIT-122: Pro given as a gift, bought on the web. Not the consumer app's.
    static var gifts: Bool { sellsPro && !Edition.consumer }
    /// The on-device model and Claude through our server, and with them voice (spoken entry needs the model).
    static var inAppAI: Bool { !simple }
    /// Groups, live workouts, and sessions or programs shared with friends.
    static var groups: Bool { !simple }
    /// FIT-273: runs, check-ins and coaches aren't in the consumer app's launch set.
    static var runs: Bool { !Edition.consumer }
    static var checkIns: Bool { !Edition.consumer }
    static var coaches: Bool { !Edition.consumer }

    /// FIT-201: in the pilot the app plans weeks itself only for a program of its own. A coach's client gets the weeks
    /// the coach writes; someone logging on their own, none.
    static func plansWeeks(hasProgram: Bool, coached: Bool) -> Bool { !simple || (hasProgram && !coached) }
}
