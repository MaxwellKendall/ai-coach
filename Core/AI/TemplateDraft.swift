import Foundation
import FoundationModels

@Generable
struct TemplateDraft {
    @Guide(description: "The name in title case, e.g. Bang Bang Salmon or Goblet Squat")
    var name: String
    @Guide(description: "Facts about it. Each has a snake_case key and one or more short values.")
    var attributes: [Attribute]

    @Generable
    struct Attribute {
        @Guide(description: "snake_case key")
        var key: String
        @Guide(description: "One value per list item, ingredient, step or cue")
        var values: [String]
    }
}

enum TemplateParser {
    /// Keys used by the bundled seed, so AI-added templates render like the rest of the catalog.
    private static let keys: [TemplateKind: String] = [
        .exercise: "movement_pattern, muscles_primary, muscles_secondary, equipment, substitutes, tags, cues, programming_notes, warm_up_protocol",
        .recipe: "protein (main protein, e.g. chicken), servings, effort (low, medium or high), prep_time, cook_time, tags, source, ingredients, instructions",
    ]

    /// The LLM only structures the text; the user confirms and edits the result before saving.
    static func parse(_ text: String, kind: TemplateKind) async throws -> TemplateSeed {
        let session = LanguageModelSession(instructions: """
            Turn the user's \(kind.rawValue) into structured data. Use these keys where they apply: \(keys[kind] ?? "").
            Only include facts stated in the text. Do not invent quantities or nutrition.
            """)
        let draft = try await session.respond(to: text, generating: TemplateDraft.self).content
        return TemplateSeed(
            kind: kind, name: draft.name, slug: Slug.make(draft.name),
            attributes: draft.attributes
                .map { TemplateAttribute(key: CatalogImporter.snakeCase($0.key), values: $0.values.filter { !$0.isEmpty }) }
                .filter { !$0.key.isEmpty && !$0.values.isEmpty })
    }
}
