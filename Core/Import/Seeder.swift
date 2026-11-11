import Foundation
import SwiftData

/// Adds the bundled catalog templates the store lacks, and the pantry into an empty store. Existing templates only gain
/// how-to steps they lack (FIT-75); nothing else on them changes.
/// Debug builds also load the author's fitness-planner history and goals, which Release builds don't bundle.
enum Seeder {
    /// FIT-413: given `defaults`, the catalog is read only when the bundled files changed since it last was (an app
    /// install or update), so an ordinary launch doesn't decode 900 templates before its first frame.
    @MainActor
    static func seed(_ context: ModelContext, bundle: Bundle = .main, remembering defaults: UserDefaults? = nil) throws {
        let stamp = catalogStamp(bundle)
        let empty = try context.fetchCount(FetchDescriptor<Template>()) == 0
        if stamp == nil || defaults?.string(forKey: stampKey) != stamp || empty {
            try seedCatalog(context, bundle: bundle)
        }
        if try context.fetchCount(FetchDescriptor<PantryItem>()) == 0 {
            for seed in try decode([PantrySeed].self, "pantry", bundle) {
                context.insert(PantryItem(name: seed.name, stocked: seed.stocked))
            }
        }
#if DEBUG
        // The author's history is dev's dogfooding data; a prod store starts empty and fills from the account.
        if Backend.current == .dev, try context.fetchCount(FetchDescriptor<LogEntry>()) == 0, bundle.url(forResource: "history", withExtension: "json") != nil {
            let templates = Dictionary(try context.fetch(FetchDescriptor<Template>()).map { ($0.slug, $0.id) },
                                       uniquingKeysWith: { first, _ in first })
            for seed in try decode([LogSeed].self, "history", bundle) {
                context.insert(LogEntry(kind: seed.kind, timestamp: seed.timestamp,
                                        templateRef: seed.template.flatMap { templates[$0] },
                                        measurements: seed.measurements, note: seed.note))
            }
        }
        if Backend.current == .dev, try context.fetchCount(FetchDescriptor<Goal>()) == 0, bundle.url(forResource: "goals", withExtension: "json") != nil {
            for (index, seed) in try decode([GoalSeed].self, "goals", bundle).enumerated() {
                // Goals list in createdAt order, so keep the file's order.
                context.insert(Goal(kind: seed.kind, metric: seed.metric, target: seed.target, unit: seed.unit,
                                    deadline: seed.deadline, now: .now + TimeInterval(index)))
            }
        }
#endif
        if context.hasChanges { try context.save() }
        if let stamp { defaults?.set(stamp, forKey: stampKey) }
    }

    /// Bundled templates the store doesn't have yet (FIT-70: the catalog grows with app updates). Ones it has, and
    /// anything the user made, are left alone.
    @MainActor
    private static func seedCatalog(_ context: ModelContext, bundle: Bundle) throws {
        let existing = Dictionary(try context.fetch(FetchDescriptor<Template>()).map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
        for file in ["exercises", "recipes"] {
            for seed in try decode([TemplateSeed].self, file, bundle) {
                guard let template = existing[seed.slug] else {
                    context.insert(Template(kind: seed.kind, name: seed.name, slug: seed.slug, attributes: seed.attributes))
                    continue
                }
                // FIT-75: how-to steps reach exercises already in the store; nothing else on them changes.
                if let steps = seed.attributes.first(where: { $0.key == "instructions" }),
                   !template.attributes.contains(where: { $0.key == "instructions" }) {
                    template.attributes.append(steps)
                }
            }
        }
    }

    private static let stampKey = "catalogStamp"

    /// The catalog files' sizes and dates, which change whenever the app is installed or updated.
    private static func catalogStamp(_ bundle: Bundle) -> String? {
        var parts: [String] = []
        for name in ["exercises", "recipes"] {
            guard let url = bundle.url(forResource: name, withExtension: "json"),
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize, let date = values.contentModificationDate else { return nil }
            parts.append("\(size)@\(date.timeIntervalSince1970)")
        }
        return parts.joined(separator: ",")
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
