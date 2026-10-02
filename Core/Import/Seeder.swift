import Foundation
import SwiftData

/// Loads the bundled catalog and pantry into an empty store. Never touches existing data.
/// Debug builds also load the author's fitness-planner history and goals, which Release builds don't bundle.
enum Seeder {
    @MainActor
    static func seedIfEmpty(_ context: ModelContext, bundle: Bundle = .main) throws {
        if try context.fetchCount(FetchDescriptor<Template>()) == 0 {
            for file in ["exercises", "recipes"] {
                for seed in try decode([TemplateSeed].self, file, bundle) {
                    context.insert(Template(kind: seed.kind, name: seed.name, slug: seed.slug, attributes: seed.attributes))
                }
            }
        }
        if try context.fetchCount(FetchDescriptor<PantryItem>()) == 0 {
            for seed in try decode([PantrySeed].self, "pantry", bundle) {
                context.insert(PantryItem(name: seed.name, stocked: seed.stocked))
            }
        }
#if DEBUG
        if try context.fetchCount(FetchDescriptor<LogEntry>()) == 0, bundle.url(forResource: "history", withExtension: "json") != nil {
            let templates = Dictionary(try context.fetch(FetchDescriptor<Template>()).map { ($0.slug, $0.id) },
                                       uniquingKeysWith: { first, _ in first })
            for seed in try decode([LogSeed].self, "history", bundle) {
                context.insert(LogEntry(kind: seed.kind, timestamp: seed.timestamp,
                                        templateRef: seed.template.flatMap { templates[$0] },
                                        measurements: seed.measurements, note: seed.note))
            }
        }
        if try context.fetchCount(FetchDescriptor<Goal>()) == 0, bundle.url(forResource: "goals", withExtension: "json") != nil {
            for (index, seed) in try decode([GoalSeed].self, "goals", bundle).enumerated() {
                // Goals list in createdAt order, so keep the file's order.
                context.insert(Goal(kind: seed.kind, metric: seed.metric, target: seed.target, unit: seed.unit,
                                    deadline: seed.deadline, now: .now + TimeInterval(index)))
            }
        }
#endif
        try context.save()
    }

    static func decode<T: Decodable>(_ type: T.Type, _ name: String, _ bundle: Bundle) throws -> T {
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "\(name).json"])
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: Data(contentsOf: url))
    }
}
