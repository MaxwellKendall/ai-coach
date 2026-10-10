import Foundation
@testable import AICoach

/// FIT-92: scores for a designed program as a whole, read from its planned weeks, so models can be compared on more
/// than one week at a time. Pure; ProgramScoreTests covers each.
enum ProgramScore {
    static func working(_ week: TrainingWeek) -> [PlannedWorkout] {
        week.workouts.filter { $0.note != TrainingGenerator.warmupNote }
    }

    /// Sessions with different names and the same exercises ("Upper Body A = Upper Body B"). A session repeated under
    /// its own name (A, B, A over 3 days) is the split, not a copy.
    static func copiedSessions(_ week: TrainingWeek) -> [String] {
        var seen: [(name: String, exercises: Set<String>)] = [], copies: [String] = []
        for (_, rows) in Dictionary(grouping: working(week), by: \.date).sorted(by: { $0.key < $1.key }) {
            let name = rows[0].session, exercises = Set(rows.map(\.exercise))
            if seen.contains(where: { $0.name == name }) { continue }
            if let earlier = seen.first(where: { $0.exercises == exercises }) { copies.append("\(earlier.name) = \(name)") }
            seen.append((name, exercises))
        }
        return copies
    }

    /// Items no coach would write: a hold or carry of nothing, no reps, a weighted exercise with no load.
    static func oddItems(_ week: TrainingWeek, catalog: [String: Exercise], names: [String: String]) -> [String] {
        var odd: [String] = []
        for row in working(week) {
            let name = names[row.exercise] ?? row.exercise
            if let seconds = row.target("duration_s"), seconds < 5 { odd.append("\(name) \(Coach.number(seconds)) s") }
            if let meters = row.target("distance_m"), meters < 5 { odd.append("\(name) \(Coach.number(meters)) m") }
            if let reps = row.target("reps"), reps < 1 { odd.append("\(name) \(Coach.number(reps)) reps") }
            if let exercise = catalog[row.exercise], !exercise.isTimed, !exercise.equipment.isDisjoint(with: ProgramDesigner.loadBearing),
               row.target("load_lb") == nil, row.target("load_lb_hand") == nil {
                odd.append("\(name) with no load")
            }
        }
        return odd
    }

    /// A lift's best planned set in a week, as an estimated 1RM (Brzycki, fitness-planner CLAUDE.md "1RM").
    static func bestEstimate(_ week: TrainingWeek, exercise: String, mainOnly: Bool = false) -> Double? {
        working(week).filter { $0.exercise == exercise && (!mainOnly || $0.main) }.compactMap { row -> Double? in
            guard let load = row.target("load_lb") ?? row.target("load_lb_hand"), load > 0, let reps = row.target("reps") else { return nil }
            return ProgramPlan.estimatedMax(load: load, reps: reps)
        }.max()
    }

    struct Progression: Equatable {
        var up = 0, held = 0, down = 0
        /// "Bench Press weeks 3→4 +14%".
        var jumps: [String] = []
    }

    /// Each main lift's best planned estimate, from one hard week it's in to the next (light weeks skipped): how often
    /// it went up, held or dropped, and any rise over 10% at once.
    static func progression(_ weeks: [TrainingWeek], light: [Bool], names: [String: String]) -> Progression {
        var result = Progression(), last: [String: (week: Int, estimate: Double)] = [:]
        for (index, week) in weeks.enumerated() where !light[index] {
            let lifts = Set(working(week).filter(\.main).map(\.exercise))
            for lift in lifts.sorted() {
                guard let estimate = bestEstimate(week, exercise: lift, mainOnly: true) else { continue }
                if let before = last[lift] {
                    let change = estimate / before.estimate - 1
                    if change > 0.005 { result.up += 1 } else if change < -0.005 { result.down += 1 } else { result.held += 1 }
                    if change > 0.10 {
                        result.jumps.append("\(names[lift] ?? lift) weeks \(before.week + 1)→\(index + 1) +\(Int((change * 100).rounded()))%")
                    }
                }
                last[lift] = (index, estimate)
            }
        }
        return result
    }

    struct Target: Sendable {
        var exercise: String
        var pounds: Double
    }

    struct Track: Equatable {
        /// The first hard week's estimate, and the best of the last three hard weeks'.
        var start: Double?
        var end: Double?
        var target: Double
        var share: Double? { end.map { $0 / target } }
    }

    /// Where a strength goal's lift is planned to be: its best estimate near the end against the target.
    static func track(_ weeks: [TrainingWeek], light: [Bool], target: Target) -> Track {
        let hard = weeks.indices.filter { !light[$0] }
        let estimates = hard.map { bestEstimate(weeks[$0], exercise: target.exercise) }
        return Track(start: estimates.compactMap { $0 }.first, end: estimates.suffix(3).compactMap { $0 }.max(), target: target.pounds)
    }

    /// Light weeks planned with fewer working sets than the hard weeks either side of them.
    static func deloads(_ weeks: [TrainingWeek], light: [Bool]) -> (lighter: Int, of: Int) {
        var lighter = 0, of = 0
        for index in weeks.indices where light[index] {
            let neighbours = [index - 1, index + 1].filter { weeks.indices.contains($0) && !light[$0] }.map { weeks[$0].totalSets }
            guard !neighbours.isEmpty else { continue }
            of += 1
            if weeks[index].totalSets < neighbours.min()! { lighter += 1 }
        }
        return (lighter, of)
    }

    /// How much the exercises change from one phase to the next, over its hard weeks: 0 all the same, 1 all new
    /// (1 − Jaccard). ("base→build", 0.4)
    static func phaseChanges(_ weeks: [TrainingWeek], phases: [ProgramPhase], light: [Bool]) -> [(String, Double)] {
        let order: [ProgramPhase] = [.base, .build, .peak]
        let used = order.map { phase in
            Set(weeks.indices.filter { phases[$0] == phase && !light[$0] }.flatMap { working(weeks[$0]).map(\.exercise) })
        }
        return zip(order.indices.dropLast(), order.indices.dropFirst()).compactMap { from, to in
            guard !used[from].isEmpty, !used[to].isEmpty else { return nil }
            let shared = Double(used[from].intersection(used[to]).count), all = Double(used[from].union(used[to]).count)
            return ("\(order[from].rawValue)→\(order[to].rawValue)", 1 - shared / all)
        }
    }
}

// MARK: The pass bar (FIT-98)

extension ProgramScore {
    /// What a run must reach for its model to be good enough for the job. Named here, so a model choice can point to
    /// the line it passed or failed.
    enum Bar {
        static let modelShare = 0.95
        static let oddPer10Weeks = 1.0
        static let goalShare = 0.9
        static let dropShare = 0.2
        static let repairsPerWeek = 3.0
    }

    struct Run {
        var weeks: Int
        var byModel: Int
        var repairsPerWeek: Double
        var copies: Int
        var odd: Int
        var progression: Progression
        var goalShares: [Double]
        var deloads: (lighter: Int, of: Int)
    }

    /// Each line of the bar for designing weeks that the run missed, with what it had: empty when it passes.
    static func weekFailures(_ run: Run) -> [String] {
        var failed: [String] = []
        let share = Double(run.byModel) / Double(max(1, run.weeks))
        if share < Bar.modelShare { failed.append("model designed \(percent(share)) of weeks") }
        if run.copies > 0 { failed.append("\(run.copies) copied sessions") }
        let odd = Double(run.odd) / Double(max(1, run.weeks)) * 10
        if odd > Bar.oddPer10Weeks { failed.append(String(format: "%.1f odd items per 10 weeks", odd)) }
        let changes = run.progression.up + run.progression.held + run.progression.down
        if changes > 0, Double(run.progression.down) / Double(changes) > Bar.dropShare {
            failed.append("\(run.progression.down) of \(changes) main-lift changes were drops")
        }
        if run.deloads.lighter < run.deloads.of { failed.append("\(run.deloads.of - run.deloads.lighter) deloads not lighter") }
        if run.repairsPerWeek > Bar.repairsPerWeek { failed.append(String(format: "%.1f repairs a week", run.repairsPerWeek)) }
        if let low = run.goalShares.min(), low < Bar.goalShare { failed.append("a goal planned to end at \(percent(low))") }
        return failed
    }

    /// What's wrong with a brief: a phase the program has that it doesn't plan, a goal lift missing from a phase's main
    /// lifts, a lift the equipment rules out, or peak reps above base reps. Empty when it passes.
    static func briefProblems(_ brief: ProgramBrief?, weeks: [ProgramWeek], goalLifts: [String], catalog: [String: Exercise],
                              names: [String: String], equipment: Set<String>) -> [String] {
        guard let brief else { return ["no brief"] }
        var problems: [String] = []
        let slugs = Dictionary(names.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        for phase in ProgramBrief.phases(weeks) {
            guard let line = brief.phase(phase) else { problems.append("no \(phase.rawValue) phase"); continue }
            for goal in goalLifts where !line.mainLifts.contains(names[goal] ?? goal) {
                problems.append("\(names[goal] ?? goal) not a main lift in \(phase.rawValue)")
            }
            for lift in line.mainLifts {
                guard let exercise = slugs[lift].flatMap({ catalog[$0] }) else { continue }
                if !exercise.equipment.subtracting(["bodyweight"]).isSubset(of: equipment) {
                    problems.append("\(lift) needs equipment they don't have")
                }
            }
        }
        if let base = brief.phase(.base)?.mainReps, let peak = brief.phase(.peak)?.mainReps, peak > base {
            problems.append("peak reps (\(peak)) above base reps (\(base))")
        }
        return problems
    }

    static func percent(_ share: Double) -> String { "\(Int((share * 100).rounded()))%" }
}
