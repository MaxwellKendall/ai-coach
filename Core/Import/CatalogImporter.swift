import Foundation

/// Bundled seed format, and what the importers produce.
struct TemplateSeed: Codable, Hashable, Sendable {
    var kind: TemplateKind
    var name: String
    var slug: String
    var attributes: [TemplateAttribute]
}

struct PantrySeed: Codable, Hashable, Sendable {
    var name: String
    var stocked: Bool
}

/// Converts the sibling repos' catalog files into seeds. Front-matter keys and sections are kept
/// generically (snake_case, in file order) so new fields in the source files come through untouched.
enum CatalogImporter {
    static func exercise(markdown: String, fileName: String) -> TemplateSeed? {
        template(.exercise, markdown: markdown, fileName: fileName)
    }

    /// `ratings` comes from grocery-planner/recent-recipes.yaml, keyed by recipe slug.
    static func recipe(markdown: String, fileName: String, ratings: [String: [(String, String)]] = [:]) -> TemplateSeed? {
        guard var seed = template(.recipe, markdown: markdown, fileName: fileName) else { return nil }
        for (key, value) in ratings[seed.slug] ?? [] {
            seed.attributes.append(TemplateAttribute(key: "\(key)_rating", values: [value]))
        }
        return seed
    }

    private static func template(_ kind: TemplateKind, markdown: String, fileName: String) -> TemplateSeed? {
        guard let card = MarkdownCard(markdown), let name = card.field("name").first else { return nil }
        let slug = card.field("slug").first ?? (fileName as NSString).deletingPathExtension
        var attributes: [TemplateAttribute] = []
        for (key, values) in card.fields where !["name", "slug"].contains(key) {
            let kept = values.filter(isRealValue)
            if !kept.isEmpty { attributes.append(TemplateAttribute(key: key, values: kept)) }
        }
        for (heading, items) in card.sections where !items.isEmpty {
            attributes.append(TemplateAttribute(key: snakeCase(heading), values: items))
        }
        return TemplateSeed(kind: kind, name: name, slug: slug, attributes: attributes)
    }

    /// grocery-planner leaves unfilled fields as placeholders (`cost_per_serving: ~$X.XX`, `servings: unknown`).
    private static func isRealValue(_ value: String) -> Bool {
        !value.contains("X.XX") && value.lowercased() != "unknown"
    }

    static func snakeCase(_ heading: String) -> String {
        Slug.make(heading).replacingOccurrences(of: "-", with: "_")
    }

    /// Reads `recipes: <slug>: ratings: <key>: <number>` from recent-recipes.yaml. Non-numeric fields
    /// (rated_on, last_used, is_memorized) are skipped.
    static func ratings(yaml: String) -> [String: [(String, String)]] {
        var result: [String: [(String, String)]] = [:]
        var slug: String?
        var inRatings = false
        for line in yaml.components(separatedBy: .newlines) {
            let indent = line.prefix { $0 == " " }.count
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let colon = t.firstIndex(of: ":") else { continue }
            let key = String(t[..<colon])
            let value = t[t.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch indent {
            case 2: slug = key; inRatings = false
            case 4: inRatings = key == "ratings"
            case 6 where inRatings && Double(value) != nil:
                if let slug { result[slug, default: []].append((key, value)) }
            default: break
            }
        }
        return result
    }

    /// Every item under `staples:` and `current_stock:` in pantry.yaml, stocked unless its status says otherwise.
    /// Stops at the `# Non-grocery` comment since those aren't food.
    static func pantry(yaml: String) -> [PantrySeed] {
        var items: [PantrySeed] = []
        var section: String?
        for line in yaml.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.lowercased().hasPrefix("# non-grocery") { break }
            if t.isEmpty || t.hasPrefix("#") { continue }
            let indent = line.prefix { $0 == " " }.count
            guard let colon = t.firstIndex(of: ":") else { continue }
            let key = String(t[..<colon])
            let value = t[t.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if indent == 0 {
                section = key
            } else if indent == 2, section == "staples" || section == "current_stock" {
                items.append(PantrySeed(name: key, stocked: true))
            } else if indent == 4, key == "status", !items.isEmpty {
                items[items.count - 1].stocked = value == "stocked"
            }
        }
        return items
    }
}
