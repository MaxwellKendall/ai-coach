import Foundation

/// One planned session as blocks (FIT-21). A block is one movement with all its sets, warm-up included,
/// or several movements done together in rounds (a superset or circuit). Stored as plain PlannedActivity
/// rows: consecutive rows of one exercise form a block, and rows sharing a `group` form a superset.
struct SessionPlan: Equatable, Sendable {
    var blocks: [Block]

    struct Block: Equatable, Identifiable, Sendable {
        var id = UUID()
        var movements: [Movement]
        var isGroup: Bool { movements.count > 1 }
        /// Rounds of a superset, or working sets of a single movement.
        var rounds: Int { movements.map { $0.working.count }.max() ?? 0 }
    }

    struct Movement: Equatable, Identifiable, Sendable {
        var id = UUID()
        var exercise: String
        var sets: [PlannedSet]
        var working: [PlannedSet] { sets.filter { !$0.isWarmup } }
    }

    /// One set's targets (no "sets" count; that's how many of these there are).
    struct PlannedSet: Equatable, Identifiable, Sendable {
        var id = UUID()
        var plannedRef: UUID?
        var targets: [Measurement]
        var note = ""
        var adjustedReason: String?
        var isWarmup: Bool { note == TrainingGenerator.warmupNote }

        func value(_ metric: String) -> Double? { targets.first { $0.metric == metric }?.value }

        /// The same set with one target changed, so it no longer merges with untouched neighbours.
        func with(_ metric: String, _ value: Double) -> PlannedSet {
            var set = self
            guard let index = set.targets.firstIndex(where: { $0.metric == metric }), set.targets[index].value != value
            else { return set }
            set.targets[index].value = value
            set.adjustedReason = "edited"
            return set
        }
    }

    /// A PlannedActivity row as these rules see it, in planned order.
    struct Item: Equatable, Sendable {
        var id: UUID?
        var exercise: String
        var targets: [Measurement]
        var note = ""
        var adjustedReason: String?
        var group: Int?
    }

    init(blocks: [Block]) { self.blocks = blocks }

    init(_ items: [Item]) {
        func key(_ item: Item) -> String { item.group.map { "group \($0)" } ?? "exercise \(item.exercise)" }
        var blocks: [Block] = []
        var lastKey: String?
        for item in items {
            let count = max(1, Int(item.targets.first { $0.metric == "sets" }?.value ?? 1))
            let sets = (0..<count).map { _ in
                PlannedSet(plannedRef: item.id, targets: item.targets.filter { $0.metric != "sets" },
                           note: item.note, adjustedReason: item.adjustedReason)
            }
            if key(item) != lastKey {
                blocks.append(Block(movements: []))
                lastKey = key(item)
            }
            if blocks[blocks.count - 1].movements.last?.exercise == item.exercise {
                blocks[blocks.count - 1].movements[blocks[blocks.count - 1].movements.count - 1].sets += sets
            } else {
                blocks[blocks.count - 1].movements.append(Movement(exercise: item.exercise, sets: sets))
            }
        }
        self.blocks = blocks
    }

    /// Back to rows: runs of identical sets collapse into one row with a "sets" count, and every
    /// superset gets its own group number.
    var items: [Item] {
        blocks.enumerated().flatMap { index, block in
            block.movements.flatMap { movement -> [Item] in
                var items: [Item] = []
                for set in movement.sets {
                    if let last = items.last, last.targets.dropFirst() == set.targets[...], last.note == set.note,
                       last.adjustedReason == set.adjustedReason {
                        items[items.count - 1].targets[0].value += 1
                        continue
                    }
                    items.append(Item(id: set.plannedRef, exercise: movement.exercise,
                                      targets: [Measurement(metric: "sets", value: 1, unit: "sets")] + set.targets,
                                      note: set.note, adjustedReason: set.adjustedReason,
                                      group: block.isGroup ? index : nil))
                }
                return items
            }
        }
    }

    static func letter(_ index: Int) -> String { String(UnicodeScalar(UInt8(65 + index % 26))) }

    /// Set a target on one set, and on the movement's later sets of the same kind when `remaining` is on.
    mutating func set(_ metric: String, to value: Double, block: Int, movement: Int, set: Int, remaining: Bool) {
        let sets = blocks[block].movements[movement].sets
        for index in sets.indices where index == set || (remaining && index > set && sets[index].isWarmup == sets[set].isWarmup) {
            blocks[block].movements[movement].sets[index] = sets[index].with(metric, value)
        }
    }

    /// Joins a block with the next one into a superset or circuit.
    mutating func group(_ block: Int) {
        guard blocks.indices.contains(block + 1) else { return }
        blocks[block].movements += blocks.remove(at: block + 1).movements
    }

    /// Splits a superset back into one block per movement.
    mutating func ungroup(_ block: Int) {
        let movements = blocks.remove(at: block).movements
        blocks.insert(contentsOf: movements.map { Block(movements: [$0]) }, at: block)
    }

    mutating func remove(block: Int, movement: Int) {
        blocks[block].movements.remove(at: movement)
        if blocks[block].movements.isEmpty { blocks.remove(at: block) }
    }

    mutating func swap(block: Int, movement: Int, to exercise: String) {
        guard blocks[block].movements[movement].exercise != exercise else { return }
        blocks[block].movements[movement].exercise = exercise
        for index in blocks[block].movements[movement].sets.indices {
            blocks[block].movements[movement].sets[index].adjustedReason = "edited"
        }
    }

    /// New exercises start at 3×10 with the session's RPE cap.
    mutating func add(_ exercise: String) {
        let rpe = blocks.lazy.flatMap(\.movements).flatMap(\.sets).compactMap { $0.value("rpe") }.first
        let targets = [Measurement(metric: "reps", value: 10, unit: "reps")]
            + (rpe.map { [Measurement(metric: "rpe", value: $0, unit: "RPE")] } ?? [])
        let sets = (0..<3).map { _ in PlannedSet(targets: targets, adjustedReason: "edited") }
        blocks.append(Block(movements: [Movement(exercise: exercise, sets: sets)]))
    }
}
