import Foundation
import Testing
@testable import AICoach

/// FIT-326: a lift swapped mid-workout moves only its sets still to do; what was logged stays as it was done.
struct MidWorkoutSwapTests {
    private func plan() -> SessionPlan {
        func set(_ load: Double) -> SessionPlan.PlannedSet {
            SessionPlan.PlannedSet(targets: [Measurement(metric: "reps", value: 5, unit: "reps"), Measurement(metric: "load_lb", value: load, unit: "lb")])
        }
        let squat = SessionPlan.Movement(exercise: "back-squat", sets: [set(185), set(185), set(185)])
        let row = SessionPlan.Movement(exercise: "bent-over-barbell-row", sets: [set(95), set(95)])
        return SessionPlan(blocks: [SessionPlan.Block(movements: [squat]), SessionPlan.Block(movements: [row])])
    }

    @Test func onlyTheSetsStillToDoMove() {
        var draft = WorkoutDraft(session: "Lower", plan: plan())
        draft.finish(0)
        draft.swap(block: 0, from: "back-squat", to: "leg-press", loadMetric: "load_lb", load: 270)
        let squat = draft.rows.filter { $0.block == 0 }
        #expect(squat.map(\.exercise) == ["back-squat", "leg-press", "leg-press"])
        #expect(squat[0].done && squat[0].load == 185)
        #expect(squat.dropFirst().allSatisfy { $0.load == 270 && $0.value == 5 && !$0.done })
        // The other lift is untouched; swapping back undoes it.
        #expect(draft.rows.filter { $0.block == 1 }.allSatisfy { $0.exercise == "bent-over-barbell-row" })
        draft.swap(block: 0, from: "leg-press", to: "back-squat", loadMetric: "load_lb", load: 185)
        #expect(draft.rows.filter { $0.block == 0 }.allSatisfy { $0.exercise == "back-squat" })
    }

    @Test func noLastTimeLeavesTheLoadEmptyToSet() {
        var draft = WorkoutDraft(session: "Lower", plan: plan())
        draft.swap(block: 0, from: "back-squat", to: "goblet-squat", loadMetric: "load_lb_hand", load: nil)
        #expect(draft.rows.filter { $0.block == 0 }.allSatisfy { $0.load == nil && $0.loadMetric == "load_lb_hand" })
        draft.adjust([0], load: true, by: 1)
        #expect(draft.rows[0].load == 5)
        // A lift with no load has none.
        draft.swap(block: 0, from: "goblet-squat", to: "bodyweight-squat", loadMetric: nil, load: 100)
        #expect(draft.rows.filter { $0.block == 0 }.allSatisfy { $0.load == nil && $0.loadMetric == nil })
    }

    @Test func thePlanKeepsTheLoggedSetsUnderTheOldLift() {
        var session = plan()
        session.swap(block: 0, movement: 0, to: "leg-press", after: 1, loadMetric: "load_lb", load: 270)
        #expect(session.blocks.map { $0.movements.map(\.exercise) } == [["back-squat"], ["leg-press"], ["bent-over-barbell-row"]])
        #expect(session.blocks[0].movements[0].working.count == 1)
        #expect(session.blocks[1].movements[0].working.map { $0.value("load_lb") } == [270, 270])
        // Nothing logged yet: the movement is swapped whole, its load empty when there's no last time.
        var fresh = plan()
        fresh.swap(block: 0, movement: 0, to: "leg-press", after: 0, loadMetric: "load_lb", load: nil)
        #expect(fresh.blocks.count == 2 && fresh.blocks[0].movements[0].exercise == "leg-press")
        #expect(fresh.blocks[0].movements[0].working.allSatisfy { $0.value("load_lb") == nil && $0.value("reps") == 5 })
    }
}
