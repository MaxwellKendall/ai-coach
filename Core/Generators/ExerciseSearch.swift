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

    /// Slugs, best first: what the user can do that matches, the author's cards first, then compound before isolation,
    /// then by name. `excluding` leaves out exercises already chosen.
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
            let name = Set((names[exercise.slug] ?? exercise.slug).lowercased().split { !$0.isLetter }
                .map { String($0.hasSuffix("s") && $0.count > 3 ? $0.dropLast() : $0) })
            return !words.isEmpty && words.isSubset(of: name)
        }
        return catalog
            .filter { !excluding.contains($0.slug) && TrainingGenerator.allows($0, settings) && matches($0) }
            .sorted { a, b in
                (a.isCurated ? 0 : 1, a.tags.contains("isolation") ? 1 : 0, names[a.slug] ?? a.slug)
                    < (b.isCurated ? 0 : 1, b.tags.contains("isolation") ? 1 : 0, names[b.slug] ?? b.slug)
            }
            .prefix(limit).map(\.slug)
    }
}
