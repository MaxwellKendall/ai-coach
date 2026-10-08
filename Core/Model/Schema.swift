import Foundation
import SwiftData

enum AppSchema {
    static let models: [any PersistentModel.Type] = [
        Goal.self, Plan.self, PlannedActivity.self, LogEntry.self, Template.self, Win.self, PantryItem.self, Profile.self,
    ]

    /// The app's store, one per process: the app and its intents (FIT-65) share it.
    @MainActor static let shared: ModelContainer = {
        do { return try container() } catch { fatalError("Could not open the data store: \(error)") }
    }()

    static func container(inMemory: Bool = false, url: URL? = nil) throws -> ModelContainer {
        let config: ModelConfiguration
        if let url {
            config = ModelConfiguration(url: url)
        } else {
            config = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        }
        return try ModelContainer(for: Schema(models), configurations: config)
    }
}
