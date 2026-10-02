import Foundation
import SwiftData

/// Loads the bundled catalog and pantry into an empty store. Never touches existing data.
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
        try context.save()
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ name: String, _ bundle: Bundle) throws -> T {
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "\(name).json"])
        }
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }
}
