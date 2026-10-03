import Foundation
import FoundationModels

/// FIT-46: an exercise asked for that isn't in the library ("split squats"). The model fills in what the plan rules
/// need to place and dose it; the user sees it on the confirm sheet and it's saved only on Apply.
@Generable
struct NewExerciseDraft {
    @Guide(description: "The exercise's usual name in title case, e.g. Split Squat")
    var name: String
    @Guide(.anyOf(["squat", "hinge", "push", "pull", "carry", "core"]))
    var pattern: String
    @Guide(description: "Equipment it needs, only from: barbell, rack, bench, dumbbells, pull_up_bar. Empty for bodyweight.")
    var equipment: [String]
    @Guide(description: "Main muscles, only from: quads, glutes, hamstrings, adductors, pectorals, deltoids, lats, upper_back, triceps, biceps, core, spinal_erectors, forearms")
    var muscles: [String]
    @Guide(description: "True if it's a hold done for time, like a plank")
    var timed: Bool
}

enum NewExercise {
    static func draft(_ name: String) async throws -> TemplateSeed {
        let session = LanguageModelSession(instructions: "Describe a strength training exercise for a workout planner.")
        let draft = try await session.respond(to: name, generating: NewExerciseDraft.self).content
        return seed(draft, said: name)
    }

    /// Only values the planner knows survive. The model's name is used when it's what was said, in the singular
    /// and with capitals ("split squats" → Split Squat); otherwise the name as said.
    static func seed(_ draft: NewExerciseDraft, said: String) -> TemplateSeed {
        func stem(_ name: String) -> [String] {
            Slug.make(name).split(separator: "-").map { $0.count > 3 && $0.hasSuffix("s") && !$0.hasSuffix("ss") ? String($0.dropLast()) : String($0) }
        }
        let name = stem(draft.name) == stem(said) ? draft.name : said.capitalized
        let muscles = Set(BodyArea.muscles.values.flatMap { $0 } + ["quads", "glutes", "hamstrings", "core"])
        let attributes = [
            TemplateAttribute(key: "movement_pattern", values: [draft.pattern]),
            TemplateAttribute(key: "muscles_primary", values: draft.muscles.filter(muscles.contains)),
            TemplateAttribute(key: "equipment", values: draft.equipment.filter(Profile.allEquipment.contains)),
            TemplateAttribute(key: "tags", values: draft.timed ? ["isometric"] : []),
        ].filter { !$0.values.isEmpty }
        return TemplateSeed(kind: .exercise, name: name, slug: Slug.make(name), attributes: attributes)
    }
}
