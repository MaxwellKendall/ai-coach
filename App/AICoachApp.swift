import SwiftUI
import SwiftData

@main
struct AICoachApp: App {
    let container: ModelContainer
    @State private var account = Account()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        do {
            container = try AppSchema.container()
            try Seeder.seedIfEmpty(container.mainContext)
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
                if let uid = account.user?.uid { await GroupSync.all(container.mainContext, me: uid) }
            }
        }
    }
}
