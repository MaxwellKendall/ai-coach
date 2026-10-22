import UIKit
import UserNotifications
import Observation

/// FIT-53: "Dad started Push day". Permission is asked in context (FIT-59): when you start or join a group, or
/// turn on live sharing. Never at launch.
@MainActor
enum Push {
    static func request() async {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        if granted { UIApplication.shared.registerForRemoteNotifications() }
    }

    /// Coming back to the app when already allowed: APNs tokens can change.
    static func refresh() async {
        if await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .authorized {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    static func hex(_ token: Data) -> String { token.map { String(format: "%02x", $0) }.joined() }

    // MARK: Coaching (FIT-220)

    /// Whether the evening "Log today's session?" nudge is on; the client turns it off on You.
    static var nudges: Bool {
        get { UserDefaults.standard.object(forKey: "push.nudges") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "push.nudges")
            if let token = UserDefaults.standard.string(forKey: "push.token") { Task { await register(token) } }
        }
    }

    /// The device, with its time zone so the nudge comes in the evening, and whether it's wanted. Signed out, this fails
    /// and nothing is stored; the next launch or sign-in registers again.
    static func register(_ token: String) async {
        UserDefaults.standard.set(token, forKey: "push.token")
        try? await Cloud.registerDevice(token, tz: TimeZone.current.identifier, nudges: nudges)
    }

    /// Notifications haven't been allowed or refused yet, so asking would show the system prompt.
    static func undecided() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .notDetermined
    }
}

/// FIT-220: what a tapped coaching notification opens: `{kind, day}` at the top of its userInfo (infra/lambda/push.ts).
struct PushTarget: Equatable, Sendable {
    enum Kind: String, Sendable {
        /// The coach changed the week: sync, then that day.
        case plan
        /// The evening of a planned day with nothing logged: that day.
        case nudge
        /// The coach replied: that day's session and its thread.
        case reply
        /// A program was sent: the offer.
        case offer
    }

    var kind: Kind
    /// The client's own calendar day, as the server reckoned it in the zone the device registered.
    var day: Date?

    init(kind: Kind, day: Date?) {
        self.kind = kind
        self.day = day
    }

    init?(_ userInfo: [AnyHashable: Any], calendar: Calendar = .current) {
        guard let raw = userInfo["kind"] as? String, let kind = Kind(rawValue: raw) else { return nil }
        let parts = (userInfo["day"] as? String)?.split(separator: "-").compactMap { Int($0) } ?? []
        self.init(kind: kind, day: parts.count == 3 ? calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) : nil)
    }
}

/// The group a tapped notification opens.
@MainActor @Observable
final class Navigator {
    static let shared = Navigator()
    var group: Cloud.GroupSummary?
    /// FIT-65: Talk to Coach (Action button, Siri) asks for the coach.
    var coach = false
    /// FIT-113: a shared session to join, by its id, once onboarding (if any) is done.
    var session: String?
    /// FIT-111: a shared program to start, likewise.
    var program: String?
    /// FIT-122: a gift's code, from its link, to redeem.
    var gift: String?
    /// FIT-130: a coach's invite code, from its link, to allow.
    var coachInvite: String?
    /// FIT-131: a program a coach sent, waiting for an answer.
    var offer: Cloud.ProgramOffer?
    /// FIT-220: a coaching notification tapped, until the root has opened it.
    var pushed: PushTarget?
    /// FIT-220: the day it opens on Today, handed over by the root.
    var day: PushTarget?
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        #if DEBUG
        // `-push reply:2026-10-19`: open as if that coaching notification had been tapped (FIT-220).
        if let raw = UserDefaults.standard.string(forKey: "push") {
            let parts = raw.split(separator: ":").map(String.init)
            MainActor.assumeIsolated {
                Navigator.shared.pushed = PushTarget(["kind": parts[0], "day": parts.count > 1 ? parts[1] : ""])
            }
        }
        #endif
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = Push.hex(deviceToken)
        Task { await Push.register(token) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        // FIT-220: the coach changed the week while the app is open: the change is on the server, so fetch it now.
        if PushTarget(notification.request.content.userInfo)?.kind == .plan {
            await MainActor.run { SyncEngine.shared.sync() }
        }
        return [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        if let target = PushTarget(userInfo) {
            await MainActor.run { Navigator.shared.pushed = target }
            return
        }
        guard Pilot.groups, let groupId = userInfo["groupId"] as? String else { return }
        await MainActor.run { Navigator.shared.group = Cloud.GroupSummary(groupId: groupId, name: "", role: "member") }
    }
}
