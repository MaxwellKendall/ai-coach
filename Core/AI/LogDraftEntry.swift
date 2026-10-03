import Foundation

/// One editable card on the check sheet (FIT-9). Nothing is saved until the user taps Save.
struct LogDraftEntry: Identifiable, Equatable {
    /// One typed number. `inferred` values (a guess from "rough night") and blanks are drawn dashed.
    struct Field: Identifiable, Equatable {
        var metric: String
        var label: String
        var unit: String
        var step: Double
        var value: Double?
        var inferred = false
        var id: String { metric }
    }

    let id = UUID()
    var kind: ActivityKind
    /// What was eaten, or a note.
    var note: String
    var templateRef: UUID?
    var timestamp: Date
    var fields: [Field]

    var measurements: [Measurement] {
        fields.compactMap { field in field.value.map { Measurement(metric: field.metric, value: $0, unit: field.unit) } }
    }

    /// Each kind needs its one main fact; an unknown food saves with just a name and blank macros.
    var isValid: Bool {
        switch kind {
        case .meal, .cook, .workout: !note.trimmingCharacters(in: .whitespaces).isEmpty
        case .sleep: fields.first { $0.metric == "sleep_h" }?.value != nil
        case .bodyweight: fields.first { $0.metric == "weight_lb" }?.value != nil
        case .grocery: fields.first { $0.metric == "cost_usd" }?.value != nil
        }
    }

    /// A blank card for the manual path and the starting point for parsed ones.
    static func blank(_ kind: ActivityKind, at timestamp: Date = .now) -> LogDraftEntry {
        let fields: [Field] = switch kind {
        case .sleep: [Field(metric: "sleep_h", label: "Hours", unit: "h", step: 0.5),
                      Field(metric: "sleep_quality", label: "Quality", unit: "/5", step: 1)]
        case .bodyweight: [Field(metric: "weight_lb", label: "Weight", unit: "lb", step: 0.2)]
        case .grocery: [Field(metric: "cost_usd", label: "Cost", unit: "$", step: 1)]
        default: [Field(metric: "kcal", label: "kcal", unit: "kcal", step: 50),
                  Field(metric: "protein_g", label: "Protein", unit: "g", step: 5)]
        }
        return LogDraftEntry(kind: kind, note: "", timestamp: timestamp, fields: fields)
    }

    mutating func set(_ metric: String, _ value: Double?, inferred: Bool = false) {
        guard let index = fields.firstIndex(where: { $0.metric == metric }) else { return }
        fields[index].value = value
        fields[index].inferred = inferred && value != nil
    }

    func makeEntry() -> LogEntry {
        LogEntry(kind: kind, timestamp: timestamp, templateRef: templateRef, measurements: measurements,
                 note: note.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// What the LLM parsed, before code resolves it: plain values only, no macros it could have invented.
struct ParsedLogItem: Equatable {
    enum Kind: String, Equatable { case meal, sleep, weight, grocery, workout }
    enum When: String, Equatable { case now, breakfast, lunch, dinner, yesterday }
    var kind: Kind
    var name: String = ""
    var servings: Double?
    var hours: Double?
    var quality: Double?
    var weightLb: Double?
    var costUsd: Double?
    var kcal: Double?
    var proteinG: Double?
    var when: When = .now
}

enum LogResolver {
    struct Result: Equatable {
        var entries: [LogDraftEntry]
        /// A workout was mentioned; it makes no entry, because workouts are logged from their card on Today.
        var mentionedWorkout: Bool
    }

    /// Code decides: names are matched to the recipe catalog, times come from the meal, and macros are only
    /// ever what the user said.
    static func resolve(_ items: [ParsedLogItem], recipes: [Template], now: Date = .now,
                        calendar: Calendar = .current) -> Result {
        var result = Result(entries: [], mentionedWorkout: false)
        for item in items {
            let timestamp = time(item.when, now: now, calendar: calendar)
            switch item.kind {
            case .workout:
                result.mentionedWorkout = true
            case .meal:
                var entry = LogDraftEntry.blank(.meal, at: timestamp)
                entry.note = item.name
                if let recipe = match(item.name, in: recipes) {
                    entry.templateRef = recipe.id
                    entry.note = recipe.name
                    entry.fields.insert(.init(metric: "servings", label: "Servings", unit: "servings", step: 0.5,
                                              value: item.servings ?? 1, inferred: item.servings == nil), at: 0)
                }
                entry.set("kcal", item.kcal)
                entry.set("protein_g", item.proteinG)
                result.entries.append(entry)
            case .sleep:
                var entry = LogDraftEntry.blank(.sleep, at: timestamp)
                entry.set("sleep_h", item.hours)
                entry.set("sleep_quality", item.quality.map { min(5, max(1, $0.rounded())) }, inferred: true)
                result.entries.append(entry)
            case .weight:
                var entry = LogDraftEntry.blank(.bodyweight, at: timestamp)
                entry.set("weight_lb", item.weightLb)
                result.entries.append(entry)
            case .grocery:
                var entry = LogDraftEntry.blank(.grocery, at: timestamp)
                entry.set("cost_usd", item.costUsd)
                result.entries.append(entry)
            }
        }
        return result
    }

    private static let filler: Set<String> = ["a", "an", "the", "of", "and", "with", "some", "my", "for", "i", "had", "ate"]

    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// A recipe matches when every meaningful word of the spoken name is in its title; the shortest title wins.
    /// "chicken bowl" finds "Chicken Burrito Bowl", but a lone "burrito" with no such recipe stays unmatched.
    static func match(_ name: String, in recipes: [Template]) -> Template? {
        let wanted = words(name).filter { !filler.contains($0) }
        guard !wanted.isEmpty else { return nil }
        return recipes.filter { $0.kind == .recipe }
            .filter { recipe in
                let title = Set(words(recipe.name))
                return wanted.allSatisfy { title.contains($0) }
            }
            .min { $0.name.count < $1.name.count }
    }

    static func time(_ when: ParsedLogItem.When, now: Date, calendar: Calendar) -> Date {
        func at(_ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
        }
        switch when {
        case .now: return now
        case .breakfast: return min(at(8), now)
        case .lunch: return min(at(12, 30), now)
        case .dinner: return min(at(18, 30), now)
        case .yesterday: return calendar.date(byAdding: .day, value: -1, to: now) ?? now
        }
    }
}
