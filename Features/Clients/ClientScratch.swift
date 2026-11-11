import Foundation
import SwiftData

/// FIT-376: a client's units in a store of their own, so a coach changes the client's goals and profile with the
/// client's own editors (FIT-346, FIT-355). What changed comes back as the client's units, with the coach's name on it.
@MainActor
final class ClientScratch {
    private let container: ModelContainer
    let context: ModelContext
    private let before: [String: String]

    init(units: [String: String], templates: [Template]) throws {
        container = try AppSchema.container(inMemory: true)
        context = ModelContext(container)
        for template in templates {
            context.insert(Template(kind: template.kind, name: template.name, slug: template.slug, attributes: template.attributes))
        }
        // Their own exercises first, as SyncEngine applies them, so the logs that name one find it.
        for (key, body) in units.sorted(by: { ($0.key.hasPrefix("template#") ? 0 : 1, $0.key) < ($1.key.hasPrefix("template#") ? 0 : 1, $1.key) }) {
            try SyncUnits.apply(key, body: body, in: context)
        }
        try context.save()
        before = Self.owned(try SyncUnits.all(in: context))
    }

    func goal(_ key: String) -> Goal? {
        guard let id = UUID(uuidString: String(key.dropFirst("goal#".count))) else { return nil }
        return try? context.fetch(FetchDescriptor<Goal>(predicate: #Predicate { $0.id == id })).first
    }

    var profile: Profile? { try? context.fetch(FetchDescriptor<Profile>()).first }

    /// The goal and profile units changed since it was made, each marked as set by `coach`; none if nothing changed.
    func changes(by coach: String) throws -> [String: String?] {
        try context.save()
        let now = Self.owned(try SyncUnits.all(in: context))
        let keys = Set(now.keys).union(before.keys).filter { now[$0] != before[$0] }
        guard !keys.isEmpty else { return [:] }
        for key in keys where key.hasPrefix("goal#") { goal(key)?.setBy = coach }
        if keys.contains("profile") { profile?.changedBy = coach }
        let after = Self.owned(try SyncUnits.all(in: context))
        return Dictionary(uniqueKeysWithValues: keys.map { ($0, after[$0]) })
    }

    /// What a coach may change of the client's own: their goals and profile.
    private static func owned(_ units: [String: String]) -> [String: String] {
        units.filter { $0.key == "profile" || $0.key.hasPrefix("goal#") }
    }
}
