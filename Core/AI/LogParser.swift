import Foundation
import FoundationModels

@Generable
struct LogDraft {
    @Guide(description: "One item per meal, sleep, weight or grocery cost mentioned. Empty if none.")
    var items: [Item]

    @Generable
    struct Item {
        @Guide(.anyOf(["meal", "sleep", "weight", "grocery", "workout"]))
        var kind: String
        @Guide(description: "Meals only: the food as said, e.g. chicken bowl. One item per dish.")
        var name: String?
        @Guide(description: "Meals only: how many servings, if said")
        var servings: Double?
        @Guide(description: "Sleep only: hours slept")
        var hours: Double?
        @Guide(description: "Sleep only: quality 1 (awful) to 5 (great), only if the user described it")
        var quality: Double?
        @Guide(description: "Weight only: pounds")
        var weightLb: Double?
        @Guide(description: "Groceries only: dollars spent")
        var costUsd: Double?
        @Guide(description: "Calories, only if the user stated them. Never estimate.")
        var kcal: Double?
        @Guide(description: "Grams of protein, only if the user stated them. Never estimate.")
        var proteinG: Double?
        @Guide(.anyOf(["now", "breakfast", "lunch", "dinner", "yesterday"]))
        var when: String?
    }
}

enum LogParser {
    /// The LLM only structures what was said; the user checks every card before anything is saved.
    static func parse(_ text: String) async throws -> [ParsedLogItem] {
        let session = LanguageModelSession(instructions: """
            Turn what the user says into log items: meals eaten, sleep, body weight, grocery spending.
            A workout (sets, reps, lifts) is kind workout with no other fields. Only include facts that were
            stated. Never estimate calories, protein or any number.
            """)
        let draft = try await session.respond(to: text, generating: LogDraft.self).content
        return keep(draft.items.compactMap(ParsedLogItem.init), said: text)
    }

    /// Code decides (principle 4): the model sometimes adds an item nobody mentioned, e.g. "Groceries $0" for
    /// "weighed 203.4" (FIT-64). An item without its number is dropped, and so is spending the words never mention.
    static func keep(_ items: [ParsedLogItem], said: String) -> [ParsedLogItem] {
        let words = SaidChecks.words(said)
        let spending = said.contains("$") || [" spent ", " spend ", " groceries ", " grocery ", " shopping ", " bought ", " paid ", " dollars ", " bucks "]
            .contains { words.contains($0) }
        return items.filter { item in
            switch item.kind {
            case .weight: (item.weightLb ?? 0) > 0
            case .sleep: (item.hours ?? 0) > 0
            case .grocery: spending && (item.costUsd ?? 0) > 0
            case .meal: !item.name.trimmingCharacters(in: .whitespaces).isEmpty
            case .workout: true
            }
        }
    }
}

extension ParsedLogItem {
    init?(_ item: LogDraft.Item) {
        guard let kind = Kind(rawValue: item.kind) else { return nil }
        self.init(kind: kind, name: item.name ?? "", servings: item.servings, hours: item.hours, quality: item.quality,
                  weightLb: item.weightLb, costUsd: item.costUsd, kcal: item.kcal, proteinG: item.proteinG,
                  when: item.when.flatMap(When.init) ?? .now)
    }
}
