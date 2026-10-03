import Foundation

/// FIT-33: "make today a squat day". Code reads which exercises were asked for and finds them in this week's
/// plan; today trades places with the nearest day that has them. If no day does, today's main lift is swapped.
enum FocusSwap {
    /// Words that ask for a different session, as opposed to saying what was done.
    private static let asks = ["day", "switch", "swap", "instead", "rather", "do", "train", "make", "want", "change", "can"]
    /// Name words too common to pick an exercise by.
    private static let generic: Set<String> = ["dumbbell", "barbell", "single", "arm", "forearm", "up", "press"]
    /// Plain words for movement patterns.
    private static let groups: [String: Set<String>] = [
        "leg": ["squat", "hinge"], "lower": ["squat", "hinge"], "upper": ["push", "pull"],
        "chest": ["push"], "push": ["push"], "back": ["pull"], "pull": ["pull"], "core": ["core"], "abs": ["core"],
        "squat": ["squat"], "hinge": ["hinge"], "carry": ["carry"],
    ]

    /// FIT-46: a different kind of day ("make today a squat day", "can I do legs") trades days; naming exercises
    /// ("swap deadlifts for RDLs") rebuilds today instead (SessionEdit).
    static func asksForADay(_ text: String) -> Bool {
        let words = Set(text.lowercased().split { !$0.isLetter }.map { singular(String($0)) })
        return words.contains("day") || !words.isDisjoint(with: ["leg", "lower", "upper", "chest", "push", "back", "pull", "core", "abs"])
            && words.isDisjoint(with: ["up", "row", "press", "squat", "deadlift", "bench"])
    }

    /// The exercises asked for, by slug, or nil when the words don't ask for a session or name none.
    static func wanted(_ text: String, catalog: [Exercise], names: [String: String]) -> Set<String>? {
        let words = Set(text.lowercased().split { !$0.isLetter }.map { singular(String($0)) })
        guard !words.isDisjoint(with: asks), !words.contains("did") else { return nil }
        let patterns = words.reduce(into: Set<String>()) { $0.formUnion(groups[$1] ?? []) }
        let slugs = catalog.filter { exercise in
            let name = Set((names[exercise.slug] ?? exercise.slug).lowercased().split { !$0.isLetter }.map { singular(String($0)) })
            return patterns.contains(exercise.pattern) || !name.subtracting(generic).isDisjoint(with: words)
        }.map(\.slug)
        return slugs.isEmpty ? nil : Set(slugs)
    }

    enum Result: Equatable {
        /// Today already has one of them.
        case already
        /// Today and that day trade places.
        case swapped(TrainingWeek, with: Date)
        /// No day has them: today's main lift becomes this exercise.
        case replaced(TrainingWeek, by: String)
        case none
    }

    /// `week` holds today's and later workouts. A day's rows share one date (Planner.workouts rounds to the minute).
    static func swap(_ week: TrainingWeek, on day: Date, wanted: Set<String>, catalog: [Exercise],
                     calendar: Calendar = .current) -> Result {
        let today = week.workouts.filter { calendar.isDate($0.date, inSameDayAs: day) }
        guard today.allSatisfy({ !wanted.contains($0.exercise) }) else { return .already }
        if let other = week.workouts.first(where: { !calendar.isDate($0.date, inSameDayAs: day) && wanted.contains($0.exercise) })?.date {
            let todayDate = today.first?.date ?? day
            var result = week
            for index in result.workouts.indices {
                if calendar.isDate(week.workouts[index].date, inSameDayAs: todayDate) {
                    result.workouts[index].date = other
                    result.workouts[index].adjustedReason = "swapped with \(todayDate.formatted(.dateTime.weekday(.wide)))"
                } else if calendar.isDate(week.workouts[index].date, inSameDayAs: other) {
                    result.workouts[index].date = todayDate
                    result.workouts[index].adjustedReason = "swapped with \(other.formatted(.dateTime.weekday(.wide)))"
                }
            }
            result.workouts.sort { $0.date < $1.date }
            return .swapped(result, with: other)
        }
        // Nobody has it this week: the first working exercise of today becomes the wanted goal lift (else any).
        let bySlug = Dictionary(catalog.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
        guard let pick = wanted.compactMap({ bySlug[$0] }).sorted(by: { ($0.isGoalLift ? 0 : 1, $0.slug) < ($1.isGoalLift ? 0 : 1, $1.slug) }).first,
              let index = week.workouts.firstIndex(where: {
                  calendar.isDate($0.date, inSameDayAs: day) && $0.note != TrainingGenerator.warmupNote
              }) else { return .none }
        var result = week
        let old = result.workouts[index].exercise
        for i in result.workouts.indices where calendar.isDate(result.workouts[i].date, inSameDayAs: day) && result.workouts[i].exercise == old {
            result.workouts[i].exercise = pick.slug
            // The old load doesn't transfer to a different exercise (as for injuries, adjust.md step 2).
            result.workouts[i].targets.removeAll { ["load_lb", "load_lb_hand"].contains($0.metric) }
            result.workouts[i].adjustedReason = "asked for \(pick.slug)"
        }
        return .replaced(result, by: pick.slug)
    }

    private static func singular(_ word: String) -> String {
        word.count > 3 && word.hasSuffix("s") && !word.hasSuffix("ss") ? String(word.dropLast()) : word
    }
}
