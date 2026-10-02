import Foundation

/// Per-week exceptions from fitness-planner's /adjust (adjust.md). Each returns the adjusted week;
/// changed workouts carry `adjustedReason`. Settings are never touched (adjust.md step 7).
enum TrainingAdjuster {
    /// Step 2: swap exercises loading an injured area for an allowed substitute (the card's list first,
    /// then any same-pattern exercise), and cut 25% of sets if more than one pattern is affected.
    static func injury(_ week: TrainingWeek, areas: Set<String>, label: String? = nil, settings: TrainingSettings,
                       catalog: [Exercise]) -> TrainingWeek {
        var settings = settings
        settings.injuredAreas.formUnion(areas)
        let bySlug = Dictionary(catalog.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
        let affected = Set(week.workouts.compactMap { bySlug[$0.exercise] }.filter { !$0.muscles.isDisjoint(with: areas) }.map(\.slug))
        let patterns = Set(affected.compactMap { bySlug[$0]?.pattern })
        let reason = "\(label ?? areas.sorted().joined(separator: ", ")) injury"
        var result = week
        result.workouts = week.workouts.compactMap { workout in
            var workout = workout
            if affected.contains(workout.exercise), let exercise = bySlug[workout.exercise] {
                let sameDay = Set(week.workouts.filter { $0.date == workout.date }.map(\.exercise))
                let options = exercise.substitutes.compactMap { bySlug[$0] }
                    + catalog.filter { $0.pattern == exercise.pattern }
                guard let substitute = options.first(where: {
                    TrainingGenerator.allows($0, settings) && !sameDay.contains($0.slug)
                }) else {
                    result.warnings.append("No safe substitute for \(exercise.slug); dropped it.")
                    return nil
                }
                workout.exercise = substitute.slug
                // The old load doesn't transfer to a different exercise.
                workout.targets.removeAll { ["load_lb", "load_lb_hand"].contains($0.metric) }
                workout.adjustedReason = "\(reason): \(exercise.slug) → \(substitute.slug)"
            }
            if patterns.count > 1, workout.note != TrainingGenerator.warmupNote {
                workout = scaleSets(workout, by: 0.75)
                workout.adjustedReason = workout.adjustedReason ?? "\(reason): volume −25%"
            }
            return workout
        }
        return result
    }

    /// Step 4: fit one session into less time. Sets scale with the time; accessories lose sets (last first)
    /// and drop out entirely before the main lifts are touched.
    static func time(_ week: TrainingWeek, on date: Date, minutes: Int, sessionMinutes: Int,
                     isMain: (PlannedWorkout) -> Bool) -> TrainingWeek {
        guard minutes < sessionMinutes else { return week }
        let reason = "\(minutes) min available"
        let indices = week.workouts.indices.filter {
            week.workouts[$0].date == date && week.workouts[$0].note != TrainingGenerator.warmupNote
        }
        var sets = Dictionary(uniqueKeysWithValues: indices.map { ($0, Int(week.workouts[$0].target("sets") ?? 0)) })
        let target = Int((Double(sets.values.reduce(0, +)) * Double(minutes) / Double(sessionMinutes)).rounded())
        let accessories = indices.filter { !isMain(week.workouts[$0]) }.reversed()
        var dropped: Set<Int> = []
        while sets.values.reduce(0, +) > target {
            if let index = accessories.first(where: { sets[$0]! > 1 }) {
                sets[index]! -= 1
            } else if let index = accessories.first(where: { !dropped.contains($0) }) {
                sets[index] = 0
                dropped.insert(index)
            } else if let index = indices.filter({ sets[$0]! > 1 }).max(by: { sets[$0]! < sets[$1]! }) {
                sets[index]! -= 1
            } else { break }
        }
        var result = week
        for index in indices where sets[index] != Int(week.workouts[index].target("sets") ?? 0) {
            result.workouts[index] = setSets(result.workouts[index], to: sets[index]!)
            result.workouts[index].adjustedReason = reason
        }
        result.workouts = result.workouts.enumerated().filter { !dropped.contains($0.offset) }.map(\.element)
        return result
    }

    /// Step 5: low energy or sore. RPE caps drop by 1 and sets by 20%. Never adds volume.
    static func energy(_ week: TrainingWeek, on date: Date) -> TrainingWeek {
        var result = week
        for index in week.workouts.indices where week.workouts[index].date == date
            && week.workouts[index].note != TrainingGenerator.warmupNote {
            var workout = scaleSets(week.workouts[index], by: 0.8)
            if let rpe = workout.target("rpe") { workout = set(workout, "rpe", to: rpe - 1) }
            workout.adjustedReason = "low energy: RPE −1, sets −20%"
            result.workouts[index] = workout
        }
        return result
    }

    /// Step 3: move a session to another day, keeping at least 48 h between sessions that train the same
    /// pattern. Returns nil when the move would break that.
    static func reschedule(_ week: TrainingWeek, from date: Date, to newDate: Date,
                           patternOf: (String) -> String?) -> TrainingWeek? {
        let moving = Set(week.workouts.filter { $0.date == date }.compactMap { patternOf($0.exercise) })
        let clash = week.workouts.contains { other in
            other.date != date && abs(other.date.timeIntervalSince(newDate)) < 48 * 3600
                && patternOf(other.exercise).map(moving.contains) == true
        }
        guard !clash else { return nil }
        var result = week
        for index in week.workouts.indices where week.workouts[index].date == date {
            result.workouts[index].date = newDate
            result.workouts[index].adjustedReason = "moved from \(date.formatted(.dateTime.weekday(.wide)))"
        }
        result.workouts.sort { $0.date < $1.date }
        return result
    }

    private static func scaleSets(_ workout: PlannedWorkout, by factor: Double) -> PlannedWorkout {
        guard let sets = workout.target("sets") else { return workout }
        return setSets(workout, to: max(1, Int((sets * factor).rounded())))
    }

    private static func setSets(_ workout: PlannedWorkout, to sets: Int) -> PlannedWorkout {
        set(workout, "sets", to: Double(sets))
    }

    private static func set(_ workout: PlannedWorkout, _ metric: String, to value: Double) -> PlannedWorkout {
        var workout = workout
        if let index = workout.targets.firstIndex(where: { $0.metric == metric }) { workout.targets[index].value = value }
        return workout
    }
}
