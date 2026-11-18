#if DEBUG
import Foundation

/// TKL-460: the server's answers in the App Review demo (`-demo YES`), for what the invited-client and coach chapters
/// show: a coach's invite looked up and accepted, and a client invite made. Nothing reaches a server and nothing is
/// written anywhere; outside demo mode each answer is nil and the real call runs. A coach's change to a client's plan
/// is "sent" by `Cloud.push` answering kept.
enum DemoCloud {
    static let coach = "Sam Rivera"
    static let coachUID = "00000000-0000-4000-8000-000000000460"
    static let inviteCode = "K7Q2MX"

    /// The demo account's uid (FIT-446): fixed, the purchase's token.
    static let uid = "00000000-0000-4000-8000-000000000446"

    /// TKL-460 round 2: who is signed in. Signed in at launch, unless `-demoSignedOut YES` opens it signed out so a
    /// chapter shows signing in; then any email and password sign in here, as that email. No server, no secret.
    static func user(signedOut: Bool, email: String?) -> Account.User? {
        if signedOut && email == nil { return nil }
        let email = email?.trimmingCharacters(in: .whitespaces).lowercased()
        return Account.User(uid: uid, name: "Demo Lifter", email: email, provider: nil)
    }

    @MainActor static func coachInvite(_ code: String, demo: Bool = DebugRole.demo) -> Cloud.CoachInvite? {
        demo ? Cloud.CoachInvite(answer: coach) : nil
    }

    @MainActor static func acceptCoach(_ code: String, demo: Bool = DebugRole.demo, now: Date = .now) -> Cloud.Person? {
        demo ? Cloud.Person(uid: coachUID, name: coach, since: now.ISO8601Format()) : nil
    }

    @MainActor static func clientInvite(client: String?, demo: Bool = DebugRole.demo, now: Date = .now) -> Cloud.ClientInvite? {
        guard demo else { return nil }
        let code = "R4TB9W"
        return Cloud.ClientInvite(code: code, url: "https://join.barbrabell.com/\(code)", createdAt: now.ISO8601Format(),
                                  client: client?.isEmpty == false ? client : nil)
    }
}
#endif
