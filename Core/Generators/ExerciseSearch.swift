import Foundation

/// FIT-70: the catalog searched the way the program designer's find_exercises tool asks (FIT-72): by a movement
/// ("squat", "vertical pull", "lunge"), a muscle or body part ("hamstrings", "chest", "shoulders") or words of a name
/// ("curl"). Only exercises the user can do: their equipment, no injured areas, nothing avoided.
enum ExerciseSearch {
    static let movements = ["squat", "hinge", "lunge", "push", "pull", "carry", "core", "arms", "shoulders", "legs",
                            "calves", "conditioning", "olympic"]

    /// Everyday words for muscle groups, as the cards' and free-exercise-db's muscle names.
    static let muscleWords: [String: Set<String>] = [
        "chest": ["pectorals"], "pecs": ["pectorals"], "back": ["lats", "rhomboids", "mid_trapezius", "middle_back"],
        "lats": ["lats"], "biceps": ["biceps"], "triceps": ["triceps"], "delts": ["deltoids", "anterior_deltoids", "rear_deltoids"],
        "shoulders": ["deltoids", "anterior_deltoids", "rear_deltoids"], "quads": ["quads"], "quadriceps": ["quads"],
        "hamstrings": ["hamstrings"], "glutes": ["glutes"], "calves": ["calves"], "abs": ["rectus_abdominis", "core"],
        "core": ["rectus_abdominis", "transverse_abdominis", "obliques", "core"], "obliques": ["obliques"],
        "forearms": ["forearms"], "grip": ["forearms"], "traps": ["traps"], "lower back": ["spinal_erectors"],
        "adductors": ["adductors"], "abductors": ["abductors"],
    ]

    /// What to swap an exercise for: the same movement, what the user can do, the same plane first (a row for a row),
    /// then the author's cards, the staples, the same kind (compound or isolation), plain names before variations.
    /// A short list, not the whole catalog (the author: "the library is way too excessive").
    static func alternatives(to exercise: Exercise, in catalog: [Exercise], names: [String: String], settings: TrainingSettings,
                             excluding: Set<String> = [], limit: Int = 12) -> [String] {
        let planes: Set<String> = ["vertical_push", "horizontal_push", "vertical_pull", "horizontal_pull"]
        let plane = exercise.tags.intersection(planes)
        return catalog
            .filter { $0.pattern == exercise.pattern && $0.slug != exercise.slug && !excluding.contains($0.slug)
                && TrainingGenerator.allows($0, settings) }
            .sorted { a, b in
                func key(_ e: Exercise) -> [String] {
                    let name = names[e.slug] ?? e.slug
                    return [e.tags.intersection(planes) == plane ? "0" : "1", e.isCurated ? "0" : e.tags.contains("staple") ? "1" : "2",
                            e.tags.contains("isolation") == exercise.tags.contains("isolation") ? "0" : "1",
                            e.level == "expert" ? "1" : "0", String(format: "%02d", name.split { !$0.isLetter }.count), name]
                }
                return key(a).lexicographicallyPrecedes(key(b))
            }
            .prefix(limit).map(\.slug)
    }

    /// The exercises to offer before anything's typed: the author's cards and the staples the user can do.
    static func suggestions(in catalog: [Exercise], names: [String: String], settings: TrainingSettings,
                            excluding: Set<String> = []) -> [String] {
        catalog.filter { ($0.isCurated || $0.tags.contains("staple")) && !excluding.contains($0.slug) && TrainingGenerator.allows($0, settings) }
            .sorted { (names[$0.slug] ?? $0.slug) < (names[$1.slug] ?? $1.slug) }
            .map(\.slug)
    }

    /// Slugs, best first: what the user can do that matches, the author's cards first, then compound before isolation,
    /// then the staples (the well-known lifts), then the plainest: expert lifts last, and short names ("Barbell Squat") before variations ("Barbell Guillotine
    /// Bench Press") (FIT-72: the model takes what's listed first). `excluding` leaves out exercises already chosen.
    static func find(_ query: String, in catalog: [Exercise], names: [String: String], settings: TrainingSettings,
                     excluding: Set<String> = [], limit: Int = 12) -> [String] {
        let query = query.lowercased().split { !$0.isLetter }.joined(separator: " ")
        let plane = query.replacingOccurrences(of: " ", with: "_")
        let muscles = muscleWords[query] ?? (muscleWords.keys.contains { query.hasSuffix($0) }
            ? muscleWords.first { query.hasSuffix($0.key) }!.value : [])
        let words = Set(query.split(separator: " ").map { String($0.hasSuffix("s") && $0.count > 3 ? $0.dropLast() : $0) })
        func matches(_ exercise: Exercise) -> Bool {
            if exercise.pattern == query || exercise.tags.contains(plane) { return true }
            if !exercise.primaryMuscles.isDisjoint(with: muscles) { return true }
            // Its own name or another it goes by: "barbell bench press" is the Bench Press card.
            return !words.isEmpty && ([names[exercise.slug] ?? exercise.slug] + exercise.aliases).contains { name in
                words.isSubset(of: Set(name.lowercased().split { !$0.isLetter }
                    .map { String($0.hasSuffix("s") && $0.count > 3 ? $0.dropLast() : $0) }))
            }
        }
        return catalog
            .filter { !excluding.contains($0.slug) && TrainingGenerator.allows($0, settings) && matches($0) }
            .sorted { a, b in
                func key(_ e: Exercise) -> [String] {
                    let name = names[e.slug] ?? e.slug
                    return [e.isCurated ? "0" : e.tags.contains("staple") ? "1" : "2", e.tags.contains("isolation") ? "1" : "0",
                            e.level == "expert" ? "1" : "0", String(format: "%02d", name.split { !$0.isLetter }.count), name]
                }
                return key(a).lexicographicallyPrecedes(key(b))
            }
            .prefix(limit).map(\.slug)
    }
}
