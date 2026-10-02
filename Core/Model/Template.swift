import Foundation
import SwiftData

/// Catalog entry (exercise or recipe). Domain-specific fields live in `attributes`.
@Model
final class Template {
    @Attribute(.unique) var id: UUID
    var kind: TemplateKind
    var name: String
    @Attribute(.unique) var slug: String
    var attributes: [String: String]
    var createdAt: Date
    var updatedAt: Date

    init(kind: TemplateKind, name: String, slug: String, attributes: [String: String] = [:], now: Date = .now) {
        self.id = UUID()
        self.kind = kind
        self.name = name
        self.slug = slug
        self.attributes = attributes
        self.createdAt = now
        self.updatedAt = now
    }
}
