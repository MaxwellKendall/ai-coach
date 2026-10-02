import Foundation

/// A finished session grouped the way it was trained (FIT-21): one block per movement, or per superset
/// or circuit with its sets read as rounds. Derived from log entries, so imported history works too.
struct SessionRecord: Sendable {
    struct Block: Sendable {
        var exercises: [String]
        var sets: [LoggedSet]
        var isGroup: Bool { exercises.count > 1 }

        /// Round n holds each movement's n-th set.
        var rounds: [[LoggedSet]] {
            var rounds: [[LoggedSet]] = []
            var seen: [String: Int] = [:]
            for set in sets {
                let round = seen[set.exercise, default: 0]
                seen[set.exercise] = round + 1
                if rounds.count <= round { rounds.append([]) }
                rounds[round].append(set)
            }
            return rounds
        }

        func sets(of exercise: String) -> [LoggedSet] { sets.filter { $0.exercise == exercise } }
    }

    var blocks: [Block]

    /// `groups` gives each set's superset group, when its planned row still exists. Without one,
    /// consecutive sets of the same exercise are one block.
    init(_ sets: [LoggedSet], groups: [Int?]) {
        var blocks: [Block] = []
        var lastKey: String?
        for (set, group) in zip(sets, groups + Array(repeating: nil, count: max(0, sets.count - groups.count))) {
            let key = group.map { "group \($0)" } ?? "exercise \(set.exercise)"
            if key != lastKey { blocks.append(Block(exercises: [], sets: [])) }
            lastKey = key
            if !blocks[blocks.count - 1].exercises.contains(set.exercise) { blocks[blocks.count - 1].exercises.append(set.exercise) }
            blocks[blocks.count - 1].sets.append(set)
        }
        self.blocks = blocks
    }

    /// The last logged session among a day's entries: each save ends with its summary entry (the one
    /// without an exercise), so it's everything after the previous summary up to the last one.
    static func lastSession<T>(_ entries: [T], isSummary: (T) -> Bool) -> ArraySlice<T> {
        guard let end = entries.lastIndex(where: isSummary) else { return entries[...] }
        let start = entries[..<end].lastIndex(where: isSummary).map { $0 + 1 } ?? entries.startIndex
        return entries[start...end]
    }

    var setCount: Int { blocks.reduce(0) { $0 + $1.sets.count } }

    /// Pounds moved: reps × load, both hands for per-hand loads.
    var volume: Double {
        blocks.flatMap(\.sets).reduce(0) { total, set in
            guard let reps = set.value("reps") else { return total }
            return total + reps * (set.value("load_lb") ?? (set.value("load_lb_hand") ?? 0) * 2)
        }
    }

    /// The best Brzycki estimate in these sets (`Training.estimated1RM`), if any set qualifies.
    static func estimated1RM(_ sets: [LoggedSet]) -> Double? {
        sets.compactMap { set in
            guard let load = set.value("load_lb"), let reps = set.value("reps") else { return nil }
            return Training.estimated1RM(loadLb: load, reps: reps, rpe: set.value("rpe"))
        }.max()
    }

    /// What the generator's progression rule plans next time from this session's top load and RPE.
    static func nextLoad(_ sets: [LoggedSet], main: Bool, tier: AgeTier) -> (from: Double, to: Double)? {
        guard let load = sets.compactMap({ $0.value("load_lb") }).max() else { return nil }
        let rpe = sets.compactMap { $0.value("rpe") }.max()
        return (load, TrainingGenerator.nextLoad(load, lastRPE: rpe, main: main, tier: tier, deload: false))
    }
}
