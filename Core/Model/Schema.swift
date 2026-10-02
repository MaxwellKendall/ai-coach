import Foundation
import SwiftData

enum AppSchema {
    static let models: [any PersistentModel.Type] = [
        Goal.self, Plan.self, PlannedActivity.self, LogEntry.self, Template.self, Win.self, PantryItem.self, Profile.self,
    ]

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
