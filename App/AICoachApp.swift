import SwiftUI
import SwiftData

@main
struct AICoachApp: App {
    let container: ModelContainer
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var account = Account()
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
                .task { await account.refresh() }
        }
        .modelContainer(container)
        // FIT-16: coming back to the app shares what changed with your groups.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await account.refresh()
                guard let uid = account.user?.uid else { return }
                await Push.refresh()
                await GroupSync.all(container.mainContext, me: uid)
            }
        }
    }
}
