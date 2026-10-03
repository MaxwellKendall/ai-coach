import Foundation

/// FIT-47: today's workout in the shape the agent's tools change it, and the name matching they share.
enum WorkoutEdit {
    static let patterns = ["squat", "hinge", "push", "pull", "carry", "core"]

    /// One working row's numbers, as `TodayWorkout` changes them.
    struct Item: Codable, Equatable, Sendable {
        var name: String
        var sets: Int
        var reps: Int?
        var seconds: Int?
        var pounds: Double?
    }

    /// "bench" is Bench Press, "rows" Dumbbell Row (Single-Arm).
    static func same(_ said: String, _ name: String) -> Bool {
        let a = Set(key(Slug.make(said)).split(separator: "-")), b = Set(key(Slug.make(name)).split(separator: "-"))
        return !a.isEmpty && (a.isSubset(of: b) || b.isSubset(of: a))
    }

    /// Today's working sets, warm-ups left out, one item per row.
    static func items(_ today: [PlannedWorkout], names: [String: String]) -> [Item] {
        today.filter(working).map { row in
            Item(name: names[row.exercise] ?? row.exercise, sets: Int(row.target("sets") ?? 1),
                 reps: row.target("reps").map { Int($0) }, seconds: row.target("duration_s").map { Int($0) },
                 pounds: row.target("load_lb") ?? row.target("load_lb_hand"))
        }
    }

    /// The library exercise a name means: its name or slug, plural or not, else `closest`.
    static func find(_ name: String, in library: [String: String], taken: Set<String> = []) -> String? {
        let wanted = key(Slug.make(name))
        guard !wanted.isEmpty else { return nil }
        return library.keys.sorted().first { key($0) == wanted || key(Slug.make(library[$0]!)) == wanted }
            ?? closest(name, library: library, taken: taken)
            ?? acronym(wanted, library: library)
    }

    /// "RDL" is (Dumbbell) Romanian Deadlift: each letter in order, every word but the equipment starting with one.
    private static func acronym(_ said: String, library: [String: String]) -> String? {
        guard (2...4).contains(said.count), said.allSatisfy(\.isLetter) else { return nil }
        let equipment: Set<Substring> = ["dumbbell", "barbell", "kettlebell", "cable", "band", "machine"]
        func matches(_ name: String) -> Bool {
            var words = Slug.make(name).split(separator: "-").filter { !equipment.contains($0) }[...]
            var letters = said[...]
            while let word = words.first {
                guard let letter = letters.first, word.first == letter else { return false }
                letters.removeFirst()
                var rest = word.dropFirst()[...]
                // The word's other letters may take the next ones, as Deadlift takes the L.
                while let next = letters.first, words.count == 1 || next != words.dropFirst().first?.first,
                      let at = rest.firstIndex(of: next) {
                    letters.removeFirst()
                    rest = rest[rest.index(after: at)...]
                }
                words.removeFirst()
            }
            return letters.isEmpty
        }
        let found = library.keys.sorted().filter { matches(library[$0]!) }
        return found.count == 1 ? found[0] : nil
    }

    /// A shortened library name ("Squat", "Romanian Deadlift"): the library exercise with all its words and the
    /// fewest others, preferring one not already in the workout.
    private static func closest(_ name: String, library: [String: String], taken: Set<String>) -> String? {
        let words = Set(key(Slug.make(name)).split(separator: "-"))
        return library.filter { words.isSubset(of: Set(key(Slug.make($0.value)).split(separator: "-"))) }
            .min { a, b in
                let order = { (slug: String, name: String) in (taken.contains(slug) ? 1 : 0, Slug.make(name).count, slug) }
                return order(a.key, a.value) < order(b.key, b.value)
            }?.key
    }

    private static func working(_ row: PlannedWorkout) -> Bool { row.note != TrainingGenerator.warmupNote }

    static func changed(_ row: PlannedWorkout, to item: Item) -> PlannedWorkout {
        var row = row
        let perHand = row.target("load_lb_hand") != nil
        let replaced: Set<String> = ["sets", "reps", "duration_s", "load_lb", "load_lb_hand"]
        row.targets = [Measurement(metric: "sets", value: Double(item.sets), unit: "sets")]
            + (item.reps.map { [Measurement(metric: "reps", value: Double($0), unit: "reps")] } ?? [])
            + (item.seconds.map { [Measurement(metric: "duration_s", value: Double($0), unit: "s")] } ?? [])
            + (item.pounds.map { [Measurement(metric: perHand ? "load_lb_hand" : "load_lb", value: $0, unit: "lb")] } ?? [])
            + row.targets.filter { !replaced.contains($0.metric) }
        row.adjustedReason = "asked for"
        return row
    }

    /// "Back Squats" finds back-squat, "pull-ups" pull-up.
    private static func key(_ slug: String) -> String {
        slug.split(separator: "-").map { ($0.count > 3 || $0 == "ups") && $0.hasSuffix("s") && !$0.hasSuffix("ss") ? String($0.dropLast()) : String($0) }
            .joined(separator: "-")
    }
}
