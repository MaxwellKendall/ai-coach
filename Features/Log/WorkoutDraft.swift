import Foundation

/// One set to confirm: pre-filled from the plan, edited by the user, saved only if marked done.
struct SetRow: Identifiable, Equatable {
    let id = UUID()
    var exercise: String
    var plannedRef: UUID?
    /// "reps", "duration_s" or "distance_m".
    var metric: String
    var value: Double?
    /// "load_lb" or "load_lb_hand"; nil for bodyweight.
    var loadMetric: String?
    var load: Double?
    var rpe: Double?
    var done = false

    var measurements: [Measurement] {
        var result: [Measurement] = []
        if let value { result.append(Measurement(metric: metric, value: value, unit: Self.units[metric] ?? "")) }
        if let loadMetric, let load { result.append(Measurement(metric: loadMetric, value: load, unit: Self.units[loadMetric] ?? "")) }
        if let rpe { result.append(Measurement(metric: "rpe", value: rpe, unit: "RPE")) }
        return result
    }

    static let units = ["reps": "reps", "duration_s": "s", "distance_m": "m", "load_lb": "lb", "load_lb_hand": "lb/hand"]
}

/// A planned session turned into set rows plus the session ratings fitness-planner's logs keep
/// (log.md: effort 1–10, energy and form 1–5; completion is computed, never typed).
struct WorkoutDraft: Equatable {
    var session: String
    var rows: [SetRow]
    var effort = 7.0
    var energy = 3.0
    var form = 3.0

    struct Planned {
        var id: UUID
        var exercise: String
        var targets: [Measurement]
        var note: String
    }

    /// One row per planned working set. Warm-ups aren't logged (fitness-planner's logs skip them too),
    /// and RPE is left for the user since it's what they felt, not the cap.
    init(session: String, planned: [Planned]) {
        self.session = session
        rows = planned.filter { $0.note != TrainingGenerator.warmupNote }.flatMap { item -> [SetRow] in
            func target(_ metric: String) -> Double? { item.targets.first { $0.metric == metric }?.value }
            let metric = ["duration_s", "distance_m"].first { target($0) != nil } ?? "reps"
            let loadMetric = ["load_lb", "load_lb_hand"].first { target($0) != nil }
            // Each set gets its own row (and id).
            return (0..<max(1, Int(target("sets") ?? 1))).map { _ in
                SetRow(exercise: item.exercise, plannedRef: item.id, metric: metric, value: target(metric),
                       loadMetric: loadMetric, load: loadMetric.flatMap(target))
            }
        }
    }

    /// Workout mode's "Done": ticks the set and carries its numbers to the exercise's remaining sets,
    /// so a load bumped on set 1 doesn't have to be re-entered. Returns the next set still to do, if any.
    @discardableResult
    mutating func finish(_ index: Int) -> Int? {
        rows[index].done = true
        let row = rows[index]
        for later in rows.indices where later > index && !rows[later].done && rows[later].exercise == row.exercise {
            rows[later].value = row.value
            rows[later].load = row.load
        }
        return rows.indices.first { $0 > index && !rows[$0].done } ?? rows.indices.first { !rows[$0].done }
    }

    /// Rest after a set. Not in fitness-planner's spec; FIT-20 decision: heavy sets (≤ 6 reps) 3:00,
    /// other rep sets 1:30, timed or distance sets 1:00.
    static func rest(after row: SetRow) -> TimeInterval {
        guard row.metric == "reps" else { return 60 }
        return (row.value ?? 0) <= 6 ? 180 : 90
    }

    var completion: Double { rows.isEmpty ? 0 : Double(rows.filter(\.done).count) / Double(rows.count) }

    /// The session's own entry: ratings and completion. It has no exercise, so set-based rules skip it.
    var summary: [Measurement] {
        [Measurement(metric: "effort", value: effort, unit: "/10"),
         Measurement(metric: "energy_level", value: energy, unit: "/5"),
         Measurement(metric: "form_quality", value: form, unit: "/5"),
         Measurement(metric: "completion_rate", value: completion, unit: "ratio")]
    }
}

/// Starting measurements for an unplanned entry of each kind.
enum LogPresets {
    static func measurements(for kind: ActivityKind) -> [Measurement] {
        let presets: [(String, String)] = switch kind {
        case .workout: [("reps", "reps"), ("load_lb", "lb"), ("rpe", "RPE")]
        case .meal: [("kcal", "kcal"), ("protein_g", "g"), ("carbs_g", "g"), ("fat_g", "g")]
        case .sleep: [("sleep_h", "h"), ("sleep_quality", "/5")]
        case .bodyweight: [("weight_lb", "lb")]
        case .grocery: [("cost_usd", "$")]
        case .cook: [("duration_h", "h")]
        }
        return presets.map { Measurement(metric: $0.0, value: 0, unit: $0.1) }
    }
}
