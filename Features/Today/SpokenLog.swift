import Foundation

/// "Did it. Last bench set was only four." (FIT-30): every planned set is logged as planned, then each spoken
/// difference is matched to the plan by code. Changed values are marked heard so the check sheet shows them.
enum SpokenLog {
    /// Returns the rows that changed, in plan order.
    @discardableResult
    static func apply(_ differences: [SpokenRequest.Difference], to draft: inout WorkoutDraft, names: [String: String]) -> [Int] {
        for index in draft.rows.indices { draft.rows[index].done = true }
        let exercises = unique(draft.rows.map(\.exercise))
        var changed: Set<Int> = []
        for difference in differences {
            guard let exercise = match(difference.exercise, in: exercises, names: names) else { continue }
            let rows = draft.rows.indices.filter { draft.rows[$0].exercise == exercise }
            let picked: [Int] = switch difference.set {
            case nil: rows
            case .max?: rows.suffix(1)
            case let number?: rows.indices.contains(number - 1) ? [rows[number - 1]] : []
            }
            changed.formUnion(set(difference, on: picked, in: &draft))
        }
        return changed.sorted()
    }

    /// FIT-32: talking about one card mid-workout ("only got four on that one"). The card's sets are logged,
    /// and what was said changes them, or the set it names of the same exercise ("set two was six").
    @discardableResult
    static func apply(_ differences: [SpokenRequest.Difference], to draft: inout WorkoutDraft, names: [String: String],
                      line: [Int]) -> [Int] {
        guard let first = line.first else { return [] }
        for index in line { draft.rows[index].done = true }
        let exercises = unique(line.map { draft.rows[$0].exercise })
        var changed: Set<Int> = []
        for difference in differences {
            guard let exercise = match(difference.exercise, in: exercises, names: names)
                ?? (exercises.count == 1 ? exercises[0] : nil) else { continue }
            let picked: [Int]
            if let number = difference.set, number != .max {
                let rows = draft.rows.indices.filter { draft.rows[$0].block == draft.rows[first].block && draft.rows[$0].exercise == exercise }
                picked = rows.indices.contains(number - 1) ? [rows[number - 1]] : []
            } else {
                picked = line.filter { draft.rows[$0].exercise == exercise }
            }
            for index in picked { draft.rows[index].done = true }
            changed.formUnion(set(difference, on: picked, in: &draft))
        }
        return changed.sorted()
    }

    private static func set(_ difference: SpokenRequest.Difference, on picked: [Int], in draft: inout WorkoutDraft) -> [Int] {
        var changed: [Int] = []
        for index in picked {
            if let reps = difference.reps, draft.rows[index].metric == "reps", draft.rows[index].value != reps {
                draft.rows[index].value = reps
                draft.rows[index].heard = true
                changed.append(index)
            }
            if let pounds = difference.pounds, draft.rows[index].loadMetric != nil, draft.rows[index].load != pounds {
                draft.rows[index].load = pounds
                draft.rows[index].heard = true
                changed.append(index)
            }
        }
        return changed
    }

    private static func unique(_ exercises: [String]) -> [String] {
        exercises.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    /// The planned exercise whose name shares the most words with what was said ("bench" → Bench Press).
    /// Ties go to the shorter name, then to the plan's order, so "bench" is the barbell lift, not the dumbbell one.
    static func match(_ said: String, in exercises: [String], names: [String: String]) -> String? {
        func words(_ text: String) -> Set<String> {
            Set(text.lowercased().split { !$0.isLetter }.map { $0.hasSuffix("s") && $0.count > 3 ? String($0.dropLast()) : String($0) })
        }
        let spoken = words(said)
        let scored = exercises.enumerated().map { offset, slug -> (slug: String, score: Int, length: Int, offset: Int) in
            let name = words(names[slug] ?? slug.replacingOccurrences(of: "-", with: " "))
            return (slug, spoken.intersection(name).count, name.count, offset)
        }
        return scored.filter { $0.score > 0 }
            .min { ($1.score, $0.length, $0.offset) < ($0.score, $1.length, $1.offset) }?.slug
    }
}
