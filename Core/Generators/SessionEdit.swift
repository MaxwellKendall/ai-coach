import Foundation

/// FIT-46: "give me squats and split squats today", "swap deadlifts for RDLs", "just pull-ups and rows".
/// The model names exercises; code finds them in the library, checks they were said, and rebuilds the day.
enum SessionEdit {
    /// Name words too common to tell exercises apart by.
    private static let generic: Set<String> = ["dumbbell", "barbell", "single", "arm", "forearm", "up", "the"]
    /// Short words that are never an exercise's initials.
    private static let filler: Set<String> = ["a", "i", "me", "my", "to", "do", "and", "for", "the", "can", "no", "day",
                                              "just", "only", "give", "want", "some", "with", "lets", "let", "us", "it", "of"]

    struct Resolved: Equatable {
        /// Library exercises, by slug, in the order asked for.
        var slugs: [String] = []
        /// Names not in the library, as said.
        var unknown: [String] = []
    }

    /// Each name the model returned, matched to the library or kept as a new exercise, only if it was said.
    /// A plain name ("squats") that fits several prefers one already in today's session, then a goal lift.
    static func resolve(_ names: [String], said: String, library: [String: String], catalog: [Exercise],
                        today: Set<String>) -> Resolved {
        let saidWords = words(said)
        let goal = Set(catalog.filter(\.isGoalLift).map(\.slug))
        var result = Resolved()
        func best(_ asked: Set<String>) -> String? {
            library.filter { asked.isSubset(of: words($0.value)) }.map(\.key).min { a, b in
                func key(_ slug: String) -> [Int] {
                    [words(library[slug]!).subtracting(generic).count - asked.count,
                     today.contains(slug) ? 0 : 1, goal.contains(slug) ? 0 : 1]
                }
                return key(a).lexicographicallyPrecedes(key(b)) || (key(a) == key(b) && a < b)
            }
        }
        for name in names {
            let asked = words(name).subtracting(generic)
            var slug = best(asked).flatMap { heard(library[$0]!, in: saidWords) ? $0 : nil }
            var unknown: String?
            if slug == nil {
                // The model sometimes embellishes ("Bent-over Row" for "rows"): keep only the words that were said.
                let said = asked.filter { spoken($0, in: saidWords) }
                guard !said.isEmpty else { continue }
                slug = best(said)
                if slug == nil {
                    unknown = said == asked ? name : name.split { !$0.isLetter && $0 != "-" }
                        .filter { said.contains(singular($0.lowercased())) }.joined(separator: " ").capitalized
                }
            }
            if let slug, !result.slugs.contains(slug) { result.slugs.append(slug) }
            if let unknown, !result.unknown.contains(unknown) { result.unknown.append(unknown) }
        }
        return result
    }

    /// The model sometimes leaves out an exercise that was plainly said ("just pull-ups and rows" → only Pull-up).
    /// Code reads the words too: each said word that's in a library name, and not already in a name the model
    /// listed (`covered`, added or removed), adds that exercise.
    static func mentioned(_ said: String, library: [String: String], catalog: [Exercise], today: Set<String>,
                          covered: [String]) -> [String] {
        let taken = covered.reduce(into: Set<String>()) { $0.formUnion(words(library[$1] ?? $1)) }
        var seen = Set<String>(), slugs: [String] = []
        for word in said.lowercased().split(whereSeparator: { !$0.isLetter }).map({ singular(String($0)) })
        where !generic.contains(word) && !filler.contains(word) && !taken.contains(word) && seen.insert(word).inserted {
            if let slug = resolve([word], said: said, library: library, catalog: catalog, today: today).slugs.first,
               !slugs.contains(slug), !covered.contains(slug) { slugs.append(slug) }
        }
        return slugs
    }

    /// What a swap takes out, as said: "swap deadlifts for RDLs", "replace bench with push-ups", "RDLs instead of
    /// deadlifts". The model sometimes adds the new one and forgets to remove the old.
    static func swappedOut(_ said: String) -> String? {
        let text = said.lowercased()
        let patterns = [#"\b(?:swap|replace|switch|trade|sub)\s+(?:out\s+)?(?:the\s+|my\s+)?(.+?)\s+(?:for|with|to)\s"#,
                        #"\binstead\s+of\s+(?:the\s+|my\s+)?([a-z\- ]+?)(?:\s+today|\s*$|[,.])"#]
        for pattern in patterns {
            if let match = text.firstMatch(of: try! Regex<(Substring, Substring)>(pattern)) { return String(match.1) }
        }
        return nil
    }

    /// The model often lists an exercise both ways. With "just" or "only" nothing needs removing (`rebuild` drops the
    /// rest); otherwise a "no", "skip" or "without" makes it a removal, and anything else an addition.
    static func settle(add: [String], remove: [String], only: Bool, said: String) -> (add: [String], remove: [String]) {
        if only { return (add, []) }
        let negated = !words(said).isDisjoint(with: ["no", "not", "skip", "without", "drop", "remove", "ditch", "don", "dont", "lose"])
        return negated ? (add.filter { !remove.contains($0) }, remove) : (add, remove.filter { !add.contains($0) })
    }

    /// The new day: each exercise asked for takes the place of today's exercise with the same pattern (a removed one
    /// first), keeping its set count, or is added with 3 sets. Removed exercises go, and with `only` everything else.
    /// Targets come from the generator's rules and history, as if the plan had picked it.
    static func rebuild(_ today: [PlannedWorkout], add: [String], remove: Set<String>, only: Bool, date: Date,
                        session: String, catalog: [Exercise], settings: TrainingSettings, history: [LoggedSet],
                        calendar: Calendar = .current) -> [PlannedWorkout] {
        let bySlug = Dictionary(catalog.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
        let tier = AgeTier.of(age: settings.age)
        let deload = today.contains { $0.target("rpe") == TrainingGenerator.deloadRPE }
        let past = history.filter { $0.date < calendar.startOfDay(for: date) }
        func working(_ row: PlannedWorkout) -> Bool { row.note != TrainingGenerator.warmupNote }
        var rows = today
        for slug in add where !rows.contains(where: { $0.exercise == slug && working($0) }) {
            guard let exercise = bySlug[slug] else { continue }
            let candidates = rows.filter { working($0) && !add.contains($0.exercise) && bySlug[$0.exercise]?.pattern == exercise.pattern }
            let old = candidates.first { remove.contains($0.exercise) } ?? candidates.first
            let sets = old.map { old in rows.filter { $0.exercise == old.exercise && working($0) }.reduce(0) { $0 + Int($1.target("sets") ?? 1) } } ?? 3
            var item = TrainingGenerator.workout(exercise, main: exercise.isGoalLift, sets: max(1, sets), date: date, session: session,
                                                 settings: settings, tier: tier, deload: deload, history: past, calendar: calendar)
            item.adjustedReason = "asked for \(slug)"
            if let old, let index = rows.firstIndex(where: { $0.exercise == old.exercise }) {
                rows.removeAll { $0.exercise == old.exercise }
                rows.insert(item, at: min(index, rows.count))
            } else {
                rows.append(item)
            }
        }
        rows.removeAll { remove.contains($0.exercise) && !add.contains($0.exercise) }
        if only { rows.removeAll { !add.contains($0.exercise) } }
        return rows
    }

    private static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter }.map { singular(String($0)) })
    }

    /// A library name counts as said when one of its words was ("squats", "deadlift"), or a short word is its
    /// initials ("RDL" for Romanian Deadlift).
    private static func heard(_ name: String, in said: Set<String>) -> Bool {
        let named = words(name).subtracting(generic)
        if named.contains(where: { spoken($0, in: said) }) { return true }
        let letters = Array(name.lowercased().split { !$0.isLetter }.filter { !generic.contains(String($0)) }.joined())
        let starts = Set(named.compactMap(\.first))
        return said.contains { word in
            guard (2...4).contains(word.count), !filler.contains(word), let first = word.first, starts.contains(first) else { return false }
            var rest = letters[...]
            return word.allSatisfy { char in
                guard let index = rest.firstIndex(of: char) else { return false }
                rest = rest[(index + 1)...]
                return true
            }
        }
    }

    /// "split" for "splits", and long enough words by their stem ("deadlifting" for "deadlift").
    private static func spoken(_ word: String, in said: Set<String>) -> Bool {
        said.contains(word) || (word.count >= 5 && said.contains { $0.count >= 5 && ($0.hasPrefix(word) || word.hasPrefix($0)) })
    }

    private static func singular(_ word: String) -> String {
        word.count > 3 && word.hasSuffix("s") && !word.hasSuffix("ss") ? String(word.dropLast()) : word
    }
}
