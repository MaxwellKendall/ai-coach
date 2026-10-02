import Foundation
import SwiftData

@Model
final class Goal {
    @Attribute(.unique) var id: UUID
    var kind: GoalKind
    var metric: String
    var target: Double
    var unit: String
    var deadline: Date?
    var status: GoalStatus
    var createdAt: Date
    var updatedAt: Date

    init(kind: GoalKind, metric: String, target: Double, unit: String, deadline: Date? = nil,
         status: GoalStatus = .active, now: Date = .now) {
        self.id = UUID()
        self.kind = kind
        self.metric = metric
        self.target = target
        self.unit = unit
        self.deadline = deadline
        self.status = status
        self.createdAt = now
        self.updatedAt = now
    }
}
