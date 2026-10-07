import Foundation

/// FIT-73: the first week's loads as onboarding's check step shows them, one per weighted exercise, for the user to
/// confirm or change before the program starts.
enum FirstLoads {
    struct Item: Equatable, Identifiable, Sendable {
        var exercise: String
        /// load_lb, or load_lb_hand for each dumbbell or kettlebell.
        var metric: String
        var value: Double
        /// "4 × 5".
        var dose: String
        var id: String { exercise }
    }

    /// Each weighted exercise's first load, in the order the week first has it.
    static func items(_ workouts: [PlannedWorkout]) -> [Item] {
        var items: [Item] = []
        for row in workouts where row.note != TrainingGenerator.warmupNote && !items.contains(where: { $0.exercise == row.exercise }) {
            guard let metric = ["load_lb", "load_lb_hand"].first(where: { row.target($0) != nil }) else { continue }
            let sets = Int(row.target("sets") ?? 0)
            let dose = row.target("reps").map { "\(sets) × \(Coach.number($0))" }
                ?? row.target("distance_m").map { "\(sets) × \(Coach.number($0)) m" } ?? "\(sets) sets"
            items.append(Item(exercise: row.exercise, metric: metric, value: row.target(metric)!, dose: dose))
        }
        return items
    }

    /// The week at the loads the user set: every working set of that exercise, and its warm-up at 60% (plan.md's
    /// warm-up, as TrainingGenerator writes it).
    static func applying(_ loads: [String: Double], to workouts: [PlannedWorkout]) -> [PlannedWorkout] {
        workouts.map { row in
            guard let load = loads[row.exercise] else { return row }
            var row = row
            for index in row.targets.indices where ["load_lb", "load_lb_hand"].contains(row.targets[index].metric) {
                row.targets[index].value = row.note == TrainingGenerator.warmupNote ? max(45, TrainingGenerator.roundTo5(load * 0.6)) : load
            }
            return row
        }
    }
}
