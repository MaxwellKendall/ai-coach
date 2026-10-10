import Foundation
import FoundationModels

@Generable
struct LogDraft {
    @Guide(description: "One item per meal, sleep, weight or grocery cost mentioned. Empty if none.", .maximumCount(6))
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
    static func parse(_ text: String, model: any AIModel = OnDeviceModel()) async throws -> [ParsedLogItem] {
        let session = model.session(instructions: """
            Turn what the user says into log items: meals eaten, sleep, body weight, grocery spending.
            Add a workout item only if they describe a workout they did. Only include facts that were
            stated. Never estimate calories, protein or any number.
            """)
        let draft = try await session.respond(to: text, generating: LogDraft.self)
        return keep(draft.items.compactMap(ParsedLogItem.init), said: text)
    }

    /// Code decides (principle 4): the model adds items nobody mentioned ("Groceries $0" for "weighed 203.4", FIT-64;
    /// a "workout" for "slept 7 hours", FIT-26) and misses numbers that were said. So a weight, hours or cost is kept
    /// only when it was said; a workout only when the words describe one; a meal only when its name shares a word with
    /// what was said; and protein and calories come from the words ("40 grams of protein", "750 calories").
    static func keep(_ items: [ParsedLogItem], said: String) -> [ParsedLogItem] {
        let words = SaidChecks.words(said)
        let numbers = SpokenNumbers.values(in: said)
        func wasSaid(_ value: Double?) -> Bool { value.map { v in v > 0 && numbers.contains { abs($0 - v) < 0.05 } } ?? false }
        let spending = said.contains("$") || [" spent ", " spend ", " groceries ", " grocery ", " shopping ", " bought ", " paid ", " dollars ", " bucks "]
            .contains { words.contains($0) }
        let trained = [" workout ", " trained ", " training ", " lifted ", " lift ", " sets ", " set ", " reps ", " bench ", " squat ",
                       " squats ", " deadlift ", " deadlifts ", " session ", " gym ", " ran ", " jogged ", " miles "].contains { words.contains($0) }
        // A question isn't a log ("What should I eat tonight?").
        let opening = words.split(separator: " ").first.map(String.init) ?? ""
        if said.contains("?") || ["what", "how", "should", "can", "could", "why", "which", "do", "does"].contains(opening) { return [] }
        let filler: Set<String> = ["felt", "feel", "great", "good", "bad", "slept", "sleep", "hours", "hour", "night", "weighed", "scale", "said",
                                   "weight", "pounds", "today", "morning", "rough", "kind", "workout", "unknown", "breakfast",
                                   "lunch", "dinner", "yesterday", "meal", "food"]
        func named(_ name: String) -> Bool {
            name.lowercased().split { !$0.isLetter }.map(String.init)
                .contains { $0.count >= 3 && !filler.contains($0) && words.contains(" \($0)") }
        }
        var kept: [ParsedLogItem] = []
        for var item in items {
            switch item.kind {
            case .weight: guard wasSaid(item.weightLb) else { continue }
            case .sleep: guard wasSaid(item.hours) else { continue }
            case .grocery: guard spending, wasSaid(item.costUsd), !kept.contains(where: { $0.kind == .grocery }) else { continue }
            case .meal:
                guard named(item.name), !kept.contains(where: { $0.kind == .meal && $0.name.lowercased() == item.name.lowercased() })
                else { continue }
                if !wasSaid(item.kcal) { item.kcal = nil }
                if !wasSaid(item.proteinG) { item.proteinG = nil }
            case .workout: guard trained, !kept.contains(where: { $0.kind == .workout }) else { continue }
            }
            if item.kind == .sleep, let quality = item.quality, !wasSaid(quality) { item.quality = nil }
            kept.append(item)
        }
        // What the words plainly say and the model missed (FIT-26): a weigh-in, hours slept, money spent.
        func has(_ cues: String...) -> Bool { cues.contains { words.contains(" \($0) ") } }
        let used = Set(kept.flatMap { [$0.hours, $0.weightLb, $0.costUsd, $0.kcal, $0.proteinG].compactMap { $0 } })
        if !kept.contains(where: { $0.kind == .weight }), has("weighed", "weigh", "weight", "scale", "pounds", "lbs"),
           let weight = numbers.filter({ (60...600).contains($0) && !used.contains($0) }).max() {
            kept.append(ParsedLogItem(kind: .weight, weightLb: weight, when: has("yesterday", "yesterday's") ? .yesterday : .now))
        }
        if !kept.contains(where: { $0.kind == .sleep }), has("slept", "sleep"),
           let hours = numbers.filter({ (1...14).contains($0) && !used.contains($0) }).max() {
            kept.append(ParsedLogItem(kind: .sleep, hours: hours))
        }
        if !kept.contains(where: { $0.kind == .grocery }), spending,
           let cost = numbers.filter({ value in value >= 1 && !used.contains(value)
               && !kept.contains { $0.hours == value || $0.weightLb == value } }).max() {
            kept.append(ParsedLogItem(kind: .grocery, costUsd: cost))
        }
        // "Yesterday" only when the words say it; sleep is logged for the morning after, so "last night" isn't it.
        let yesterday = has("yesterday", "yesterday's")
        for index in kept.indices where kept[index].kind != .sleep {
            if kept[index].when == .yesterday, !yesterday { kept[index].when = .now }
            if kept[index].when == .now, yesterday { kept[index].when = .yesterday }
        }
        // A meal's time the words name, when the model left it at now.
        let meals = kept.indices.filter { kept[$0].kind == .meal }
        if meals.count == 1, kept[meals[0]].when == .now {
            for when in [ParsedLogItem.When.breakfast, .lunch, .dinner] where has(when.rawValue) { kept[meals[0]].when = when }
        }
        // Macros the words state belong to the meal, when there's one.
        if meals.count == 1 {
            let lower = said.lowercased()
            if kept[meals[0]].proteinG == nil, let grams = firstNumber(before: #/\s*(?:g|grams?)\s+(?:of\s+)?protein/#, in: lower) {
                kept[meals[0]].proteinG = grams
            }
            if kept[meals[0]].kcal == nil, let kcal = firstNumber(before: #/\s*(?:calories|kcal|cals?)\b/#, in: lower) {
                kept[meals[0]].kcal = kcal
            }
        }
        return kept
    }

    /// The number written just before a unit: "40 grams of protein" → 40.
    private static func firstNumber(before unit: Regex<Substring>, in text: String) -> Double? {
        guard let match = text.firstMatch(of: unit) else { return nil }
        let head = text[..<match.range.lowerBound]
        guard let token = head.split(whereSeparator: { !$0.isNumber && $0 != "." }).last, head.hasSuffix(token) else { return nil }
        return Double(token)
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
