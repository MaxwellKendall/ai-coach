import Foundation
import Testing
@testable import AICoach

struct SessionPlanTests {
    private func item(_ exercise: String, sets: Double, reps: Double = 5, load: Double? = nil, note: String = "",
                      group: Int? = nil) -> SessionPlan.Item {
        SessionPlan.Item(id: UUID(), exercise: exercise,
                         targets: [Measurement(metric: "sets", value: sets, unit: "sets"), Measurement(metric: "reps", value: reps, unit: "reps")]
                            + (load.map { [Measurement(metric: "load_lb", value: $0, unit: "lb")] } ?? []),
                         note: note, group: group)
    }

    /// The generator's shape: warm-up then working sets of each main lift, then accessories.
    private var generated: [SessionPlan.Item] {
        [item("bench", sets: 1, load: 85, note: TrainingGenerator.warmupNote), item("bench", sets: 3, load: 140),
         item("deadlift", sets: 3, load: 200), item("db-row", sets: 3, reps: 10)]
    }

    @Test func warmupAndWorkingSetsOfOneExerciseAreOneBlock() {
        let plan = SessionPlan(generated)
        #expect(plan.blocks.count == 3)
        #expect(plan.blocks[0].movements.map(\.exercise) == ["bench"])
        #expect(plan.blocks[0].movements[0].sets.count == 4)
        #expect(plan.blocks[0].rounds == 3) // warm-up isn't a working set
        #expect(plan.blocks.allSatisfy { !$0.isGroup })
        #expect(SessionPlan.letter(2) == "C")
    }

    /// FIT-300: a coach's warm-up is its own exercises marked warm-up; a lift's ramp sets stay the lift's.
    @Test func writtenWarmupIsTheBlocksWithNoWorkingSets() {
        let warm = TrainingGenerator.warmupNote
        let plan = SessionPlan([item("rowing-machine", sets: 1, note: warm), item("band-pull-apart", sets: 2, reps: 15, note: warm)] + generated)
        #expect(plan.warmup.map(\.exercise) == ["rowing-machine", "band-pull-apart"])
        #expect(plan.warmup[1].sets.count == 2)
        #expect(plan.blocks.filter { $0.rounds > 0 }.map { $0.movements[0].exercise } == ["bench", "deadlift", "db-row"])
        #expect(SessionPlan(generated).warmup.isEmpty)
    }

    /// FIT-301: the live workout's warm-up: the written items, else easy cardio, then the ramp to the first lift.
    @Test func workoutWarmupSteps() {
        let warm = TrainingGenerator.warmupNote
        let written = SessionPlan([SessionPlan.Item(id: UUID(), exercise: "rowing-machine",
                                                    targets: [Measurement(metric: "sets", value: 1, unit: "sets"), Measurement(metric: "duration_s", value: 300, unit: "s")],
                                                    note: warm),
                                   item("band-pull-apart", sets: 2, reps: 15, note: warm)] + generated)
        let steps = WorkoutDraft.warmups(written)
        #expect(steps.prefix(2).map(\.dose) == ["5 min", "2 × 15"])
        #expect(steps.dropFirst(2).allSatisfy { $0.ramp && $0.exercise == "bench" })
        #expect(steps.dropFirst(2).map(\.dose) == ["Bar × 10", "75 × 5", "105 × 3", "125 × 2"])
        let plain = WorkoutDraft.warmups(SessionPlan(generated))
        #expect(plain.first == WorkoutDraft.Warmup(exercise: nil, dose: "5 min"))
        #expect(WorkoutDraft.warmups(SessionPlan([item("db-row", sets: 3, reps: 10)])).isEmpty)
        // Warm-ups aren't logged.
        #expect(WorkoutDraft(session: "A", plan: written).rows.count == 9)
    }

    /// FIT-300: a lifter adds a warm-up item; it goes before the lifts, after any others, and its sets come and go.
    @Test func addingAWarmupItem() {
        var plan = SessionPlan(generated)
        plan.addWarmup("rowing-stationary")
        plan.addWarmup("band-pull-apart")
        #expect(plan.warmup.map(\.exercise) == ["rowing-stationary", "band-pull-apart"])
        #expect(plan.warmup[0].sets.first?.value("duration_s") == 300)
        #expect(plan.blocks[2].movements[0].exercise == "bench")
        plan.addSet(block: 1)
        #expect(plan.warmup[1].sets.count == 2)
        #expect(plan.warmup[1].sets.allSatisfy { $0.isWarmup })
        plan.removeSet(block: 1)
        plan.removeSet(block: 1)
        #expect(plan.warmup[1].sets.count == 1)
        // Back to rows and in again, it's still the warm-up.
        #expect(SessionPlan(plan.items).warmup.map(\.exercise) == ["rowing-stationary", "band-pull-apart"])
    }

    @Test func rowsSharingAGroupAreASuperset() {
        let plan = SessionPlan([item("bench", sets: 3), item("db-row", sets: 3, group: 4), item("db-bench", sets: 2, group: 4),
                                item("plank", sets: 2, group: 5), item("dead-bug", sets: 2, group: 5)])
        #expect(plan.blocks.count == 3)
        #expect(plan.blocks[1].movements.map(\.exercise) == ["db-row", "db-bench"])
        #expect(plan.blocks[1].rounds == 3)
        #expect(plan.blocks[2].isGroup)
    }

    @Test func roundTripCollapsesIdenticalSetsAndKeepsIds() {
        let items = generated
        let back = SessionPlan(items).items
        #expect(back.map(\.id) == items.map(\.id))
        #expect(back.map(\.targets) == items.map(\.targets))
        #expect(back.allSatisfy { $0.group == nil })
    }

    @Test func editingOneSetSplitsItsRowAndApplyToRemainingCarriesOn() {
        var plan = SessionPlan(generated)
        plan.set("load_lb", to: 145, block: 0, movement: 0, set: 2, remaining: true) // working set 2 of 3
        var rows = plan.items.filter { $0.exercise == "bench" }
        #expect(rows.map { $0.targets[0].value } == [1, 1, 2])
        #expect(rows.map { $0.targets.last!.value } == [85, 140, 145])
        #expect(rows[2].adjustedReason == "edited" && rows[1].adjustedReason == nil)
        #expect(rows[0].note == TrainingGenerator.warmupNote) // warm-up untouched

        plan.set("reps", to: 3, block: 0, movement: 0, set: 2, remaining: false) // only that set
        rows = plan.items.filter { $0.exercise == "bench" }
        #expect(rows.map { $0.targets[0].value } == [1, 1, 1, 1])
    }

    @Test func groupUngroupRemoveAndAdd() {
        var plan = SessionPlan(generated)
        plan.group(1)
        #expect(plan.blocks.count == 2)
        #expect(plan.blocks[1].movements.map(\.exercise) == ["deadlift", "db-row"])
        #expect(Set(plan.items.suffix(2).map(\.group)) == [1])

        plan.ungroup(1)
        #expect(plan.blocks.count == 3 && plan.items.allSatisfy { $0.group == nil })

        plan.swap(block: 2, movement: 0, to: "cable-row")
        #expect(plan.items.last?.exercise == "cable-row" && plan.items.last?.adjustedReason == "edited")
        // FIT-81: the old load doesn't carry over to the new exercise; the main lift's warm-up goes too.
        #expect(plan.blocks[2].movements[0].sets.allSatisfy { $0.value("load_lb") == nil && $0.value("load_lb_hand") == nil })
        var main = SessionPlan(generated)
        main.swap(block: 0, movement: 0, to: "goblet-squat")
        #expect(main.blocks[0].movements[0].sets.allSatisfy { !$0.isWarmup && $0.value("load_lb") == nil })

        plan.remove(block: 2, movement: 0)
        #expect(plan.blocks.count == 2)

        plan.add("plank")
        #expect(plan.items.last?.targets.first == Measurement(metric: "sets", value: 3, unit: "sets"))
        #expect(plan.items.last?.id == nil)
    }

    @Test func compactSummaryShowsRanges() {
        var plan = SessionPlan(generated)
        #expect(WorkoutDetailView.compact(plan.blocks[0].movements[0]) == "3×5 · 140") // warm-up left out
        plan.set("load_lb", to: 150, block: 0, movement: 0, set: 3, remaining: false)
        #expect(WorkoutDetailView.compact(plan.blocks[0].movements[0]) == "3×5 · 140–150")
    }

    @Test func addAndRemoveSetsAndMoveBlocks() {
        var plan = SessionPlan(generated)
        plan.addSet(block: 0)
        #expect(plan.blocks[0].rounds == 4)
        #expect(plan.items.filter { $0.exercise == "bench" }.map { $0.targets[0].value } == [1, 3, 1]) // new set is "edited"
        plan.removeSet(block: 0)
        plan.removeSet(block: 0)
        #expect(plan.blocks[0].rounds == 2)
        #expect(plan.blocks[0].movements[0].sets.first?.isWarmup == true) // warm-up kept

        plan.group(1) // deadlift + db-row: 3 rounds each
        plan.addSet(block: 1)
        #expect(plan.blocks[1].movements.map { $0.working.count } == [4, 4])

        plan.move(block: 1, by: -1)
        #expect(plan.blocks[0].isGroup)
        plan.move(block: 0, by: -1) // already first: no-op
        #expect(plan.blocks[0].isGroup)
    }
}

/// FIT-81: a bodyweight set can take a load, and give it back.
struct BodyweightLoadTests {
    @Test func aLoadIsAddedAndRemoved() {
        let set = SessionPlan.PlannedSet(targets: [Measurement(metric: "reps", value: 12, unit: "reps")])
        let loaded = set.with("load_lb_hand", 5)
        #expect(loaded.value("load_lb_hand") == 5 && loaded.adjustedReason == "edited")
        #expect(loaded.with("load_lb_hand", 0).value("load_lb_hand") == nil)
        #expect(set.with("load_lb", 0) == set)
    }
}
