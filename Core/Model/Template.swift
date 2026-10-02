import Foundation
import SwiftData

/// One ordered, possibly multi-valued fact about a template, e.g. `cues` or `servings`.
struct TemplateAttribute: Codable, Hashable, Sendable {
    var key: String
    var values: [String]
}

/// Catalog entry (exercise or recipe). Domain-specific fields live in `attributes`.
@Model
final class Template {
    @Attribute(.unique) var id: UUID
    var kind: TemplateKind
    var name: String
    @Attribute(.unique) var slug: String
    var attributes: [TemplateAttribute]
    var createdAt: Date
    var updatedAt: Date

    init(kind: TemplateKind, name: String, slug: String, attributes: [TemplateAttribute] = [], now: Date = .now) {
        self.id = UUID()
        self.kind = kind
        self.name = name
        self.slug = slug
        self.attributes = attributes
        self.createdAt = now
        self.updatedAt = now
    }

    func values(_ key: String) -> [String] {
        attributes.first { $0.key == key }?.values ?? []
    }
}
