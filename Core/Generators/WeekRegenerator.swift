import Foundation

/// FIT-40: another version of a session when the week is regenerated. Code picks it; the user sees from → to and why,
/// can try another, and applies it. Only the session's first lift changes, so the rest of the week still fits.
enum WeekRegenerator {
    struct Alternative: Equatable, Sendable {
        var workouts: [PlannedWorkout]
        /// The lift before and after.
        var from: PlannedWorkout
        var to: PlannedWorkout
        var why: String
    }

    /// Even variants swap the first lift for another allowed exercise of its pattern (each in turn); odd ones, or
    /// when there's no other, step it up: +5 lb, else +1 rep, else +5 s. nil for a session with nothing to change.
    static func alternative(_ session: [PlannedWorkout], variant: Int, catalog: [Exercise], settings: TrainingSettings,
                            history: [LoggedSet]) -> Alternative? {
        guard let index = session.firstIndex(where: { $0.note != TrainingGenerator.warmupNote }) else { return nil }
        let first = session[index]
        let used = Set(session.map(\.exercise))
        let pattern = catalog.first { $0.slug == first.exercise }?.pattern
        let others = catalog.filter { $0.pattern == pattern && !used.contains($0.slug) && TrainingGenerator.allows($0, settings) }
        var workouts = session
        if variant % 2 == 0, !others.isEmpty {
            let other = others[(variant / 2) % others.count]
            var swapped = first
            swapped.exercise = other.slug
            swapped.targets = first.targets.filter { !["load_lb", "load_lb_hand"].contains($0.metric) }
            if let load = lastLoad(other.slug, history) {
                swapped.targets.append(Measurement(metric: "load_lb", value: load, unit: "lb"))
            } else if let start = settings.starts.first(where: { $0.exercise == other.slug }),
                      let load = ProgramPlan.firstTargets(start, reps: first.target("reps") ?? 5).load {
                swapped.targets.append(Measurement(metric: "load_lb", value: load, unit: "lb"))
            }
            workouts[index] = swapped
            // The warm-up was for the old lift.
            workouts.removeAll { $0.note == TrainingGenerator.warmupNote && $0.exercise == first.exercise }
            return Alternative(workouts: workouts, from: first, to: swapped, why: "Same movement, a different exercise for a change of stimulus.")
        }
        var stepped = first
        let why: String
        if let load = first.target("load_lb") {
            set(&stepped, "load_lb", load + 5)
            why = "A small step up in weight: 5 lb."
        } else if let reps = first.target("reps") {
            set(&stepped, "reps", reps + 1)
            why = "One more rep a set."
        } else if let seconds = first.target("duration_s") {
            set(&stepped, "duration_s", seconds + 5)
            why = "Five seconds longer a set."
        } else {
            return nil
        }
        workouts[index] = stepped
        return Alternative(workouts: workouts, from: first, to: stepped, why: why)
    }

    private static func set(_ workout: inout PlannedWorkout, _ metric: String, _ value: Double) {
        if let i = workout.targets.firstIndex(where: { $0.metric == metric }) { workout.targets[i].value = value }
    }

    /// The heaviest load of the last session of an exercise.
    private static func lastLoad(_ slug: String, _ history: [LoggedSet]) -> Double? {
        let sets = history.filter { $0.exercise == slug }
        guard let last = sets.map(\.date).max() else { return nil }
        return sets.filter { Calendar.current.isDate($0.date, inSameDayAs: last) }.compactMap { $0.value("load_lb") }.max()
    }
}
