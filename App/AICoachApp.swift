import SwiftUI
import SwiftData

@main
struct AICoachApp: App {
    let container: ModelContainer

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
        }
        .modelContainer(container)
    }
}
