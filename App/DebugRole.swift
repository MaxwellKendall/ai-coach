#if DEBUG
import Foundation
import SwiftData

/// FIT-445: `-uiTesting YES -role coach|client|solo|soloPro` opens the app as that role, the same on every launch, for
/// RoleUITests and screenshots: a new in-memory store, no defaults from an earlier run, and signed out, so nothing
/// reaches the server. Each role is the debug switches that already exist: coach is `-sampleClients`, client is
/// `-coach Sam` with a session of Sam's today, solo is a ready program started today, soloPro is solo with `-pro`.
/// `-noProgram YES` leaves solo without a program. Other launch arguments still win, so `-role client -sampleClients
/// YES` is a client with a sample roster.
enum DebugRole {
    static var uiTesting: Bool { UserDefaults.standard.bool(forKey: "uiTesting") }
    static var role: String? { uiTesting ? UserDefaults.standard.string(forKey: "role") : nil }

    /// Before anything reads the defaults or the saved roster.
    @MainActor static func prepare() {
        guard uiTesting else { return }
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
        try? FileManager.default.removeItem(at: Roster.savedURL)
        var defaults: [String: Any] = ["welcomed": true]
        switch role {
        case "coach": defaults["sampleClients"] = true
        case "client": defaults["coach"] = "Sam"
        case "soloPro": defaults["pro"] = true
        default: break
        }
        // The registration domain, under the launch arguments.
        UserDefaults.standard.register(defaults: defaults)
    }

    @MainActor static func seed(_ context: ModelContext, now: Date = .now) throws {
        switch role {
        case "client":
            // A session Sam wrote for today, as the server would sync it (FIT-202).
            let at = Calendar.current.startOfDay(for: now).timeIntervalSince1970 + 18 * 3600
            let lifts: [(String, Double)] = [("back-squat", 185), ("bench-press", 135)]
            let rows: [[String: Any]] = lifts.enumerated().map { index, lift in
                ["id": UUID().uuidString, "kind": "workout", "at": at + Double(index), "slot": "Lower A", "template": lift.0,
                 "targets": [["metric": "sets", "value": 3, "unit": "sets"], ["metric": "reps", "value": 5, "unit": "reps"],
                             ["metric": "load_lb", "value": lift.1, "unit": "lb"]],
                 "note": "", "main": index == 0, "pinned": true]
            }
            let body = String(decoding: try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]), as: UTF8.self)
            try SyncUnits.apply("plan#\(SyncUnits.day(now))", body: body, in: context)
            try context.save()
        case "solo", "soloPro":
            guard !UserDefaults.standard.bool(forKey: "noProgram"),
                  let program = ReadyProgram.all.first(where: { $0.slug == "full-body-3" }) ?? ReadyProgram.all.first else { return }
            let profile = Profile(age: 34, weightLb: 180)
            context.insert(profile)
            // Today (0 = Monday) and every other day after it, so Today has a session.
            let today = (Calendar.current.component(.weekday, from: now) + 5) % 7
            let days = (0..<program.days(nearest: 3)).map { (today + 2 * $0) % 7 }
            try Planner.start(program, days: days, equipment: Profile.allEquipment, profile: profile, in: context, now: now)
        default:
            break
        }
    }
}
#endif
