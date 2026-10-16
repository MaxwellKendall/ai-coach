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
                await GroupSync.all(container.mainContext, me: uid)
            }
        }
    }
}
