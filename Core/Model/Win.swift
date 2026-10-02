import Foundation
import SwiftData

@Model
final class Win {
    @Attribute(.unique) var id: UUID
    var kind: WinKind
    var goalRef: UUID?
    var logRef: UUID?
    var date: Date
    var createdAt: Date
    var updatedAt: Date

    init(kind: WinKind, goalRef: UUID? = nil, logRef: UUID? = nil, date: Date, now: Date = .now) {
        self.id = UUID()
        self.kind = kind
        self.goalRef = goalRef
        self.logRef = logRef
        self.date = date
        self.createdAt = now
        self.updatedAt = now
    }
}
