import Foundation

/// The review demo reads its logins from the environment. scripts/demo-video.mjs replaces this
/// file for one recording and writes this stub back afterwards. Do not put a password here.
enum ReviewDemoSecrets {
    static let clientEmail = ProcessInfo.processInfo.environment["DEMO_CLIENT_EMAIL"] ?? ""
    static let coachEmail = ProcessInfo.processInfo.environment["DEMO_COACH_EMAIL"] ?? ""
    static let password = ProcessInfo.processInfo.environment["DEMO_PASSWORD"] ?? ""
}
