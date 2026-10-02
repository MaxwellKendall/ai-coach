import Foundation
import SwiftData

/// Inventory, not part of the Goal → Plan → Log loop, so it gets its own small model.
@Model
final class PantryItem {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var name: String
    var stocked: Bool
    var createdAt: Date
    var updatedAt: Date

    init(name: String, stocked: Bool = true, now: Date = .now) {
        self.id = UUID()
        self.name = name
        self.stocked = stocked
        self.createdAt = now
        self.updatedAt = now
    }
}
