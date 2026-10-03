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
    /// Set by voice (FIT-31): shown dashed until the user edits it.
    var heard = false
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
    /// Unset until rated, so a session saved without them doesn't claim numbers nobody gave.
    var effort: Double?
    var energy: Double?
    var form: Double?
    /// Workout mode's "How did it feel?" (FIT-28); sets the effort and the RPE of unrated sets on save.
    var feel: Feel? {
        didSet { effort = feel?.effort }
    }
    var note = ""
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
    static func rest(after row: SetRow) -> TimeInterval { rest(metric: row.metric, value: row.value) }

    static func rest(metric: String, value: Double?) -> TimeInterval {
        guard metric == "reps" else { return 60 }
        return (value ?? 0) <= 6 ? 180 : 90
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
        [effort.map { Measurement(metric: "effort", value: $0, unit: "/10") },
         energy.map { Measurement(metric: "energy_level", value: $0, unit: "/5") },
         form.map { Measurement(metric: "form_quality", value: $0, unit: "/5") },
         Measurement(metric: "completion_rate", value: completion, unit: "ratio"),
         duration.map { Measurement(metric: "duration_s", value: $0.rounded(), unit: "s") }].compactMap { $0 }
    }

    // MARK: Workout mode (FIT-28): one card per block, one line per round

    /// Each block's rounds as row indices: a single lift's set, or one of each movement in a superset.
    func lines(block: Int) -> [[Int]] {
        let indices = rows.indices.filter { rows[$0].block == block }
        return Dictionary(grouping: indices) { rows[$0].round }.sorted { $0.key < $1.key }.map(\.value)
    }

    var blocks: [Int] { Array(Set(rows.map(\.block))).sorted() }

    /// Ticks a line; returns the rest after it (none mid-superset) and whether the block is now done.
    @discardableResult
    mutating func tick(_ line: [Int]) -> (rest: TimeInterval, blockDone: Bool) {
        for index in line { finish(index) }
        guard let last = line.last else { return (0, false) }
        return (rest(after: last), lines(block: rows[last].block).joined().allSatisfy { rows[$0].done })
    }

    mutating func untick(_ line: [Int]) { for index in line { rows[index].done = false } }

    /// −/+ on a line: reps by 1 (time and distance by 5), load by 5 lb. Never below zero.
    mutating func adjust(_ line: [Int], load: Bool, by direction: Double) {
        for index in line {
            let step = load || rows[index].metric != "reps" ? 5.0 : 1.0
            if load {
                rows[index].load = rows[index].load.map { max(0, $0 + step * direction) }
            } else {
                rows[index].value = rows[index].value.map { max(0, $0 + step * direction) }
            }
            rows[index].heard = false
        }
    }

    /// Pounds moved in done sets: reps × load, both hands for per-hand loads.
    var volume: Double {
        rows.filter { $0.done && $0.metric == "reps" }.reduce(0) { total, row in
            total + (row.value ?? 0) * (row.load ?? 0) * (row.loadMetric == "load_lb_hand" ? 2 : 1)
        }
    }

    /// The finish card's view of the main lifts: top load done, what the progression rule makes of it with the
    /// session's feel, and sets that came in under the planned reps.
    func lifts(main: Set<String>, names: [String: String], tier: AgeTier) -> [Coach.Lift] {
        var order: [String] = []
        for row in rows where row.done && main.contains(row.exercise) && !order.contains(row.exercise) { order.append(row.exercise) }
        return order.compactMap { exercise in
            let done = rows.filter { $0.done && $0.exercise == exercise }
            guard let load = done.compactMap(\.load).max() else { return nil }
            let rpe = done.compactMap(\.rpe).max() ?? feel?.rpe
            let short = done.enumerated().compactMap { index, row -> (set: Int, done: Double, planned: Double)? in
                guard row.metric == "reps", let value = row.value, let planned = row.plannedValue, value < planned else { return nil }
                return (index + 1, value, planned)
            }
            return Coach.Lift(name: names[exercise] ?? exercise, load: load,
                              next: TrainingGenerator.nextLoad(load, lastRPE: rpe, main: true, tier: tier, deload: false),
                              short: short)
        }
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
