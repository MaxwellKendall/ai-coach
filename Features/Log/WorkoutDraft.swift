import Foundation

/// One set to confirm: pre-filled from the plan, edited by the user, saved only if marked done.
struct SetRow: Identifiable, Equatable {
    let id = UUID()
    var exercise: String
    var plannedRef: UUID?
    /// Index of the block in the session, and the set's round within it.
    var block = 0
    var round = 0
    /// "reps", "duration_s" or "distance_m".
    var metric: String
    var value: Double?
    /// "load_lb" or "load_lb_hand"; nil for bodyweight.
    var loadMetric: String?
    var load: Double?
    var rpe: Double?
    var done = false
    /// What the plan said, so a change can be carried only to sets that were planned the same.
    var plannedValue: Double?
    var plannedLoad: Double?

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
    /// Set by workout mode when the session ends.
    var duration: TimeInterval?

    /// One row per planned working set, block by block. A superset's movements alternate round by round
    /// (C1, C2, C1, C2…). Warm-ups aren't logged (fitness-planner's logs skip them too), and RPE is left
    /// for the user since it's what they felt, not the cap.
    init(session: String, plan: SessionPlan) {
        self.session = session
        rows = plan.blocks.enumerated().flatMap { index, block in
            (0..<block.rounds).flatMap { round in
                block.movements.compactMap { movement -> SetRow? in
                    let working = movement.working
                    guard working.indices.contains(round) else { return nil }
                    let set = working[round]
                    let metric = ["duration_s", "distance_m"].first { set.value($0) != nil } ?? "reps"
                    let loadMetric = ["load_lb", "load_lb_hand"].first { set.value($0) != nil }
                    let value = set.value(metric), load = loadMetric.flatMap(set.value)
                    return SetRow(exercise: movement.exercise, plannedRef: set.plannedRef, block: index, round: round,
                                  metric: metric, value: value, loadMetric: loadMetric, load: load,
                                  plannedValue: value, plannedLoad: load)
                }
            }
        }
    }

    /// Workout mode's "Done": ticks the set and carries its numbers to the exercise's remaining sets that were
    /// planned the same, so a load bumped on set 1 doesn't have to be re-entered but a planned ramp survives.
    /// Returns the next set still to do, if any.
    @discardableResult
    mutating func finish(_ index: Int) -> Int? {
        rows[index].done = true
        let row = rows[index]
        for later in rows.indices where later > index && !rows[later].done && rows[later].exercise == row.exercise {
            if rows[later].plannedValue == row.plannedValue { rows[later].value = row.value }
            if rows[later].plannedLoad == row.plannedLoad { rows[later].load = row.load }
        }
        return rows.indices.first { $0 > index && !rows[$0].done } ?? rows.indices.first { !rows[$0].done }
    }

    /// Rest after a set. Not in fitness-planner's spec; FIT-20 decision: heavy sets (≤ 6 reps) 3:00,
    /// other rep sets 1:30, timed or distance sets 1:00.
    static func rest(after row: SetRow) -> TimeInterval {
        guard row.metric == "reps" else { return 60 }
        return (row.value ?? 0) <= 6 ? 180 : 90
    }

    /// No rest between the movements of a superset round (FIT-21); the round's last set gets the usual rest.
    func rest(after index: Int) -> TimeInterval {
        let row = rows[index]
        if rows.indices.contains(index + 1), rows[index + 1].block == row.block, rows[index + 1].round == row.round { return 0 }
        return Self.rest(after: row)
    }

    var completion: Double { rows.isEmpty ? 0 : Double(rows.filter(\.done).count) / Double(rows.count) }

    /// The session's own entry: ratings and completion. It has no exercise, so set-based rules skip it.
    var summary: [Measurement] {
        [Measurement(metric: "effort", value: effort, unit: "/10"),
         Measurement(metric: "energy_level", value: energy, unit: "/5"),
         Measurement(metric: "form_quality", value: form, unit: "/5"),
         Measurement(metric: "completion_rate", value: completion, unit: "ratio")]
            + (duration.map { [Measurement(metric: "duration_s", value: $0.rounded(), unit: "s")] } ?? [])
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
