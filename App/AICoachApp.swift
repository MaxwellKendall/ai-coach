import SwiftUI
import SwiftData

@main
struct AICoachApp: App {
    let container: ModelContainer
    @State private var account = Account()

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
    }
}
