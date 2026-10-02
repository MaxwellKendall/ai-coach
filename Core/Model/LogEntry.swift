import Foundation
import SwiftData

@Model
final class LogEntry {
    @Attribute(.unique) var id: UUID
    var kind: ActivityKind
    var timestamp: Date
    var plannedRef: UUID?
    var measurements: [Measurement]
    var note: String
    @Attribute(.externalStorage) var photo: Data?
    var createdAt: Date
    var updatedAt: Date

    init(kind: ActivityKind, timestamp: Date = .now, plannedRef: UUID? = nil,
         measurements: [Measurement] = [], note: String = "", photo: Data? = nil, now: Date = .now) {
        self.id = UUID()
        self.kind = kind
        self.timestamp = timestamp
        self.plannedRef = plannedRef
        self.measurements = measurements
        self.note = note
        self.photo = photo
        self.createdAt = now
        self.updatedAt = now
    }
}
