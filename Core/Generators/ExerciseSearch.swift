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
    /// FIT-300: what a warm-up is usually made of, easy cardio first, then mobility and activation. FIT-306: not
    /// "air-bike", which in free-exercise-db is the bicycle crunch on the floor (core), not a fan bike.
    static let warmupSlugs = [
        "rowing-stationary", "bicycling-stationary", "elliptical-trainer", "jogging-treadmill", "rope-jumping", "star-jump",
        "bodyweight-squat", "bodyweight-walking-lunge", "butt-lift-bridge", "dead-bug", "band-pull-apart", "external-rotation-with-band",
        "monster-walk", "scapular-pull-up",
    ]

    /// The warm-up picker's list: `warmupSlugs` the catalog has and the equipment allows, in that order.
    static func warmups(in catalog: [Exercise], settings: TrainingSettings, excluding: Set<String> = []) -> [String] {
        let bySlug = Dictionary(catalog.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
        return warmupSlugs.filter { slug in
            guard let exercise = bySlug[slug] else { return false }
            return !excluding.contains(slug) && TrainingGenerator.allows(exercise, settings)
        }
    }

    /// FIT-347: main lifts first (`mainFirst`), for the picker to show in sections by `Area`.
    static func suggestions(in catalog: [Exercise], names: [String: String], settings: TrainingSettings,
                            excluding: Set<String> = []) -> [String] {
        mainFirst(catalog.filter { ($0.isCurated || $0.tags.contains("staple")) && !excluding.contains($0.slug)
            && TrainingGenerator.allows($0, settings) }, names: names).map(\.slug)
    }

    /// FIT-347: the picker's body areas, as fitness apps' filter chips. Code over the catalog's movement pattern, no new model.
    enum Area: String, CaseIterable, Sendable {
        case legs = "Legs", push = "Push", pull = "Pull", shoulders = "Shoulders", arms = "Arms", core = "Core", cardio = "Cardio"

        /// Olympic lifts have no area: they're listed only under All.
        static func of(_ pattern: String) -> Area? {
            switch pattern {
            case "squat", "lunge", "hinge", "legs", "calves": .legs
            case "push": .push
            case "pull": .pull
            case "shoulders": .shoulders
            case "arms": .arms
            case "core", "carry": .core
            case "conditioning": .cardio
            default: nil
            }
        }
    }

    /// FIT-347: up to `limit` exercises used (logged or planned) in the 4 weeks before `now`, on the most days first
    /// (a logged set and its planned row are one day), then the latest. Only what the catalog has and the user can do.
    static func recent(_ uses: [(slug: String, at: Date)], now: Date = .now, in catalog: [Exercise], settings: TrainingSettings,
                       excluding: Set<String> = [], limit: Int = 6, calendar: Calendar = .current) -> [String] {
        let since = now.addingTimeInterval(-28 * 86_400)
        let bySlug = Dictionary(catalog.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
        var days: [String: Set<Date>] = [:], latest: [String: Date] = [:]
        for use in uses where use.at >= since && use.at <= now {
            guard let exercise = bySlug[use.slug], !excluding.contains(use.slug), TrainingGenerator.allows(exercise, settings) else { continue }
            days[use.slug, default: []].insert(calendar.startOfDay(for: use.at))
            latest[use.slug] = max(latest[use.slug] ?? .distantPast, use.at)
        }
        let count = days.mapValues(\.count)
        return count.keys.sorted { a, b in count[a]! != count[b]! ? count[a]! > count[b]! : latest[a]! > latest[b]! }
            .prefix(limit).map { $0 }
    }

    /// The author's cards first, then the staples (the well-known lifts), then the rest; within each, compound before
    /// isolation, expert lifts last, and short names ("Barbell Squat") before variations ("Barbell Guillotine Bench Press").
    static func mainFirst(_ exercises: [Exercise], names: [String: String]) -> [Exercise] {
        exercises.sorted { a, b in
            func key(_ e: Exercise) -> [String] {
                let name = names[e.slug] ?? e.slug
                return [e.isCurated ? "0" : e.tags.contains("staple") ? "1" : "2", e.tags.contains("isolation") ? "1" : "0",
                        e.level == "expert" ? "1" : "0", String(format: "%02d", name.split { !$0.isLetter }.count), name]
            }
            return key(a).lexicographicallyPrecedes(key(b))
        }
    }

    /// Slugs, best first (`mainFirst`): what the user can do that matches (FIT-72: the model takes what's listed first). `excluding` leaves out exercises already chosen.
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
        return mainFirst(catalog.filter { !excluding.contains($0.slug) && TrainingGenerator.allows($0, settings) && matches($0) },
                         names: names)
            .prefix(limit).map(\.slug)
    }
}
