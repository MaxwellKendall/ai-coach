import SwiftUI
import SwiftData

@main
struct AICoachApp: App {
    let container: ModelContainer
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var account = Account()
    /// FIT-83: whether this Apple ID has Pro.
    @State private var pro = Pro()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        do {
            container = AppSchema.shared
            try Seeder.seed(container.mainContext)
            // FIT-82: plans made when weeks began on Monday.
            try Planner.rekeyWeeks(in: container.mainContext)
            #if DEBUG
            // `-units PATH`: sync units from a JSON file ({key: body}), applied as if the server sent them, e.g. a
            // coach's week from Tests/Fixtures (FIT-202).
            if let path = UserDefaults.standard.string(forKey: "units"), let data = FileManager.default.contents(atPath: path),
               let units = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for (key, value) in units.sorted(by: { ($0.key.hasPrefix("template#") ? 0 : 1, $0.key) < ($1.key.hasPrefix("template#") ? 0 : 1, $1.key) }) {
                    let body = String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
                    try SyncUnits.apply(key, body: body, in: container.mainContext)
                }
                try container.mainContext.save()
            }
            #endif
        } catch {
            fatalError("Could not open the data store: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(account)
                .environment(pro)
                .task { await account.refresh() }
                .task { await pro.refresh() }
                // FIT-126: a signed-in account's program and logs sync; signed out, nothing leaves the phone.
                .onChange(of: account.user?.uid, initial: true) { _, uid in
                    if let uid {
                        SyncEngine.shared.start(uid: uid, context: container.mainContext)
                    } else {
                        SyncEngine.shared.stop()
                    }
                }
        }
        .modelContainer(container)
        // FIT-16: coming back to the app shares what changed with your groups.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await account.refresh()
                guard let uid = account.user?.uid else { return }
                SyncEngine.shared.start(uid: uid, context: container.mainContext)
                await Push.refresh()
                if Pilot.groups { await GroupSync.all(container.mainContext, me: uid) }
            }
        }
    }
}
