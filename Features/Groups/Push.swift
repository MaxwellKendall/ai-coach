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
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = Push.hex(deviceToken)
        // Signed out, this fails and nothing is stored; signing in to a group asks again.
        Task { try? await Cloud.registerDevice(token) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let groupId = response.notification.request.content.userInfo["groupId"] as? String else { return }
        await MainActor.run { Navigator.shared.group = Cloud.GroupSummary(groupId: groupId, name: "", role: "member") }
    }
}
