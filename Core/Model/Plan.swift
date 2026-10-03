import Foundation
import SwiftData

/// One week of planned activity, keyed by the Monday that starts it.
@Model
final class Plan {
    @Attribute(.unique) var id: UUID
    var weekStart: Date
    @Relationship(deleteRule: .cascade, inverse: \PlannedActivity.plan)
    var items: [PlannedActivity] = []
    /// Generator notices for the week, e.g. a deload or going over the weekly set ceiling.
    var warnings: [String] = []
    var createdAt: Date
    var updatedAt: Date

    init(weekContaining date: Date, calendar: Calendar = .current, now: Date = .now) {
        self.id = UUID()
        self.weekStart = Week.monday(of: date, calendar: calendar)
        self.createdAt = now
        self.updatedAt = now
    }
}

@Model
final class PlannedActivity {
    @Attribute(.unique) var id: UUID
    var kind: ActivityKind
    var date: Date
    var slot: String?
    var templateRef: UUID?
    var targets: [Measurement]
    /// e.g. "warm-up" or "tempo 3-1-1-1".
    var note: String = ""
    var adjustedReason: String?
    /// Rows sharing a group are one superset or circuit (FIT-21); nil is a block of its own.
    var group: Int?
    /// Kept when the week is regenerated (FIT-40).
    var pinned = false
    var plan: Plan?
    var createdAt: Date
    var updatedAt: Date

    init(kind: ActivityKind, date: Date, slot: String? = nil, templateRef: UUID? = nil,
         targets: [Measurement] = [], note: String = "", adjustedReason: String? = nil, group: Int? = nil,
         now: Date = .now) {
        self.id = UUID()
        self.kind = kind
        self.date = date
        self.slot = slot
        self.templateRef = templateRef
        self.targets = targets
        self.note = note
        self.adjustedReason = adjustedReason
        self.group = group
        self.createdAt = now
        self.updatedAt = now
    }
}
