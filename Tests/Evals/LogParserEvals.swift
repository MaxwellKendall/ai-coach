import Foundation
import FoundationModels
import Testing
@testable import AICoach

/// FIT-26: spoken logs scored on the real on-device model through `LogParser.parse`, the path Today's mic and the coach
/// take for "log" requests. Phrasings are written in the style of the author's daily logs (fitness-planner, read-only)
/// with nothing personal in them. Run with `scripts/log-eval.sh`; a score, not a gate.
struct LogParserEvals {
    /// What one item must be; nil fields aren't checked. `name` passes when the parsed name contains it.
    struct Item: Sendable {
        var kind: ParsedLogItem.Kind
        var name: String? = nil
        var hours: Double? = nil
        var quality: Double? = nil
        var weight: Double? = nil
        var cost: Double? = nil
        var kcal: Double? = nil
        var protein: Double? = nil
        var when: ParsedLogItem.When? = nil
        /// Macros must be blank: the user didn't say them, so they're never estimated (FIT-9).
        var noMacros = false
    }

    struct Case: Sendable {
        var said: String
        var items: [Item]
    }

    static let cases: [Case] = [
        // Meals, as said.
        Case(said: "Had 3 eggs and toast", items: [Item(kind: .meal, name: "egg", noMacros: true)]),
        Case(said: "Breakfast was oatmeal with blueberries", items: [Item(kind: .meal, name: "oatmeal", when: .breakfast, noMacros: true)]),
        Case(said: "Chicken and rice for lunch", items: [Item(kind: .meal, name: "chicken", when: .lunch, noMacros: true)]),
        Case(said: "For dinner I had salmon, potatoes and broccoli", items: [Item(kind: .meal, name: "salmon", when: .dinner, noMacros: true)]),
        Case(said: "Protein shake", items: [Item(kind: .meal, name: "shake", noMacros: true)]),
        Case(said: "Had a protein shake with 40 grams of protein", items: [Item(kind: .meal, name: "shake", protein: 40)]),
        Case(said: "Ate a burrito bowl, about 750 calories", items: [Item(kind: .meal, name: "burrito", kcal: 750)]),
        Case(said: "Greek yogurt with granola, 25 g protein", items: [Item(kind: .meal, name: "yogurt", protein: 25)]),
        Case(said: "Two servings of the chili", items: [Item(kind: .meal, name: "chili", noMacros: true)]),
        Case(said: "Ground beef and potatoes again", items: [Item(kind: .meal, name: "beef", noMacros: true)]),
        Case(said: "Steak and a baked potato for dinner, 60 grams protein", items: [Item(kind: .meal, name: "steak", protein: 60, when: .dinner)]),
        Case(said: "Turkey sandwich and an apple for lunch", items: [Item(kind: .meal, name: "sandwich", when: .lunch, noMacros: true)]),
        Case(said: "Snacked on a handful of almonds", items: [Item(kind: .meal, name: "almond", noMacros: true)]),
        Case(said: "Pasta with meat sauce last night", items: [Item(kind: .meal, name: "pasta", noMacros: true)]),
        Case(said: "Cottage cheese and pineapple, 28 grams of protein and 250 calories",
             items: [Item(kind: .meal, name: "cottage", kcal: 250, protein: 28)]),
        // Several in one go.
        Case(said: "Eggs for breakfast and a chicken wrap for lunch",
             items: [Item(kind: .meal, name: "egg", when: .breakfast), Item(kind: .meal, name: "wrap", when: .lunch)]),
        Case(said: "Oatmeal this morning, then a salad and later a steak",
             items: [Item(kind: .meal, name: "oat"), Item(kind: .meal, name: "salad"), Item(kind: .meal, name: "steak")]),
        // Sleep.
        Case(said: "Slept 7 hours", items: [Item(kind: .sleep, hours: 7)]),
        Case(said: "Got about six and a half hours of sleep", items: [Item(kind: .sleep, hours: 6.5)]),
        Case(said: "Slept 8 hours, felt great", items: [Item(kind: .sleep, hours: 8)]),
        Case(said: "Rough night, maybe 5 hours", items: [Item(kind: .sleep, hours: 5)]),
        Case(said: "Slept 7.5 hours, quality was a 4 out of 5", items: [Item(kind: .sleep, hours: 7.5, quality: 4)]),
        Case(said: "Only 4 hours of sleep last night", items: [Item(kind: .sleep, hours: 4)]),
        // Weight.
        Case(said: "Weighed 203.4", items: [Item(kind: .weight, weight: 203.4)]),
        Case(said: "Weight this morning was 198", items: [Item(kind: .weight, weight: 198)]),
        Case(said: "I'm 201.6 pounds today", items: [Item(kind: .weight, weight: 201.6)]),
        Case(said: "Scale said one ninety-five", items: [Item(kind: .weight, weight: 195)]),
        Case(said: "Weighed in at 187 point 2", items: [Item(kind: .weight, weight: 187.2)]),
        // Groceries.
        Case(said: "Spent 84 dollars on groceries", items: [Item(kind: .grocery, cost: 84)]),
        Case(said: "Grocery run was $112.50", items: [Item(kind: .grocery, cost: 112.5)]),
        Case(said: "Paid 63 bucks at the store for food this week", items: [Item(kind: .grocery, cost: 63)]),
        // Mixed.
        Case(said: "Slept 7 hours and weighed 200.2", items: [Item(kind: .sleep, hours: 7), Item(kind: .weight, weight: 200.2)]),
        Case(said: "Weighed 199, had eggs for breakfast",
             items: [Item(kind: .weight, weight: 199), Item(kind: .meal, name: "egg", when: .breakfast)]),
        Case(said: "Slept 6 hours, spent 45 on groceries and had a burger for lunch",
             items: [Item(kind: .sleep, hours: 6), Item(kind: .grocery, cost: 45), Item(kind: .meal, name: "burger", when: .lunch)]),
        // Yesterday.
        Case(said: "Yesterday I had pizza for dinner", items: [Item(kind: .meal, name: "pizza", noMacros: true)]),
        Case(said: "Forgot to log yesterday's weight, it was 202", items: [Item(kind: .weight, weight: 202, when: .yesterday)]),
        // A workout said here makes no entry: it's logged from today's session card.
        Case(said: "Did bench 3 sets of 5 at 165", items: [Item(kind: .workout)]),
        Case(said: "Finished my workout", items: [Item(kind: .workout)]),
        // Things that aren't logs: nothing comes back.
        Case(said: "What should I eat tonight?", items: []),
        Case(said: "Thanks", items: []),
        Case(said: "Hmm never mind", items: []),
    ]

    // MARK: Scoring

    /// Why a parse fails its case; empty when it passes. Items are matched in order of kind, then name.
    static func failures(_ parsed: [ParsedLogItem], for test: Case) -> [String] {
        var failures: [String] = []
        var left = parsed
        for want in test.items {
            guard let index = left.firstIndex(where: { item in
                item.kind == want.kind && (want.name.map { item.name.lowercased().contains($0) } ?? true)
            }) ?? left.firstIndex(where: { $0.kind == want.kind }) else {
                failures.append("missing \(want.kind.rawValue)\(want.name.map { " \"\($0)\"" } ?? "")")
                continue
            }
            let item = left.remove(at: index)
            func check(_ label: String, _ got: Double?, _ wanted: Double?) {
                if let wanted, got.map({ abs($0 - wanted) < 0.05 }) != true {
                    failures.append("\(want.kind.rawValue) \(label) \(got.map(Coach.number) ?? "none"), wanted \(Coach.number(wanted))")
                }
            }
            if let name = want.name, !item.name.lowercased().contains(name) { failures.append("meal named \"\(item.name)\", wanted \(name)") }
            check("hours", item.hours, want.hours)
            check("quality", item.quality, want.quality)
            check("weight", item.weightLb, want.weight)
            check("cost", item.costUsd, want.cost)
            check("kcal", item.kcal, want.kcal)
            check("protein", item.proteinG, want.protein)
            if let when = want.when, item.when != when { failures.append("\(want.kind.rawValue) when \(item.when.rawValue), wanted \(when.rawValue)") }
            if want.noMacros, item.kcal != nil || item.proteinG != nil {
                failures.append("made up macros: \(item.kcal.map(Coach.number) ?? "–") kcal, \(item.proteinG.map(Coach.number) ?? "–") g")
            }
        }
        for extra in left { failures.append("extra \(extra.kind.rawValue)\(extra.name.isEmpty ? "" : " \"\(extra.name)\"")") }
        return failures
    }

    @Test func spokenLogs() async throws {
        try #require(SystemLanguageModel.default.isAvailable, "Apple Intelligence is off on this Mac")
        let environment = ProcessInfo.processInfo.environment
        let runs = Int(environment["EVAL_RUNS"] ?? "") ?? 3
        let filter = environment["EVAL_FILTER"].map { $0.lowercased() } ?? ""
        let selected = Self.cases.filter { filter.isEmpty || $0.said.lowercased().contains(filter) }
        var report: [String] = [], passed = 0, total = 0, seconds = 0.0
        for test in selected {
            var failed: [(Int, String)] = []
            for run in 0..<runs {
                let start = Date.now
                let failures: [String]
                var output = ""
                do {
                    let parsed = try await LogParser.parse(test.said)
                    output = parsed.map { "\($0.kind.rawValue)\($0.name.isEmpty ? "" : " \($0.name)")" }.joined(separator: ", ")
                    failures = Self.failures(parsed, for: test)
                } catch {
                    failures = ["error: \(error)"]
                }
                seconds += Date.now.timeIntervalSince(start)
                total += 1
                if failures.isEmpty { passed += 1 } else { failed.append((run + 1, failures.joined(separator: "; ") + " — `\(output)`")) }
            }
            let good = runs - failed.count
            report.append("| \(good == runs ? "✅" : good == 0 ? "❌" : "🟡") \(good)/\(runs) | \(test.said) |")
            for (run, why) in failed { report.append("|  | run \(run): \(why.replacingOccurrences(of: "|", with: "/")) |") }
        }
        let header = ["# Spoken log evals", "",
                      "**\(passed)/\(total) runs pass (\(total == 0 ? 0 : passed * 100 / total)%)** · \(selected.count) cases × \(runs) runs · "
                          + "\(String(format: "%.1f", total == 0 ? 0 : seconds / Double(total))) s per run", "",
                      "| Pass | Said / why it failed |", "|---|---|"]
        for line in header + report { print("LOG§ " + line) }
    }
}
