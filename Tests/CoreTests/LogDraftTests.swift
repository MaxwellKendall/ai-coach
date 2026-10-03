import Foundation
import Testing
@testable import AICoach

struct LogDraftTests {
    private let squat = SessionPlan.Item(id: UUID(), exercise: "back-squat", targets: [
        Measurement(metric: "sets", value: 3, unit: "sets"), Measurement(metric: "reps", value: 5, unit: "reps"),
        Measurement(metric: "load_lb", value: 165, unit: "lb"), Measurement(metric: "rpe", value: 8, unit: "RPE")], note: "")
    private let warmup = SessionPlan.Item(id: UUID(), exercise: "back-squat", targets: [
        Measurement(metric: "sets", value: 1, unit: "sets"), Measurement(metric: "reps", value: 5, unit: "reps")],
        note: TrainingGenerator.warmupNote)
    private let carry = SessionPlan.Item(id: UUID(), exercise: "farmer-carry", targets: [
        Measurement(metric: "sets", value: 2, unit: "sets"), Measurement(metric: "distance_m", value: 30, unit: "m"),
        Measurement(metric: "load_lb_hand", value: 50, unit: "lb/hand")], note: "")

    @Test func plannedSetsBecomeOneRowEachWithoutWarmups() {
        let draft = WorkoutDraft(session: "Session A", plan: SessionPlan([warmup, squat, carry]))
        #expect(draft.rows.count == 5)
        #expect(Set(draft.rows.map(\.id)).count == 5)
        #expect(draft.rows[0].measurements == [Measurement(metric: "reps", value: 5, unit: "reps"),
                                               Measurement(metric: "load_lb", value: 165, unit: "lb")]) // no RPE cap copied
        #expect(draft.rows[0].plannedRef == squat.id)
        #expect(draft.rows[3].measurements == [Measurement(metric: "distance_m", value: 30, unit: "m"),
                                               Measurement(metric: "load_lb_hand", value: 50, unit: "lb/hand")])
        #expect(draft.rows.allSatisfy { !$0.done })
    }

    @Test func completionIsComputedFromTickedSets() {
        var draft = WorkoutDraft(session: "Session A", plan: SessionPlan([squat, carry]))
        #expect(draft.completion == 0)
        draft.rows[0].done = true
        draft.rows[1].done = true
        draft.rows[2].rpe = 8
        #expect(abs(draft.completion - 0.4) < 0.0001)
        let summary = Dictionary(uniqueKeysWithValues: draft.summary.map { ($0.metric, $0.value) })
        #expect(summary["completion_rate"] == draft.completion)
        #expect(summary["effort"] == nil && summary["energy_level"] == nil) // never rated, so not claimed
        draft.feel = .hard
        #expect(draft.summary.contains(Measurement(metric: "effort", value: 8.5, unit: "/10")))
        #expect(draft.rows[2].measurements.last == Measurement(metric: "rpe", value: 8, unit: "RPE"))
    }

    @Test(arguments: ActivityKind.allCases)
    func everyKindHasPresetMeasurements(kind: ActivityKind) {
        #expect(!LogPresets.measurements(for: kind).isEmpty)
    }

    @Test func ratiosDisplayAsPercent() {
        #expect(Measurement(metric: "completion_rate", value: 0.8, unit: "ratio").display == "80% completion")
    }

    @Test func finishingASetCarriesItsNumbersForwardAndPointsToTheNextSet() {
        var draft = WorkoutDraft(session: "Session A", plan: SessionPlan([squat, carry]))
        draft.rows[0].load = 170
        draft.rows[0].value = 4
        #expect(draft.finish(0) == 1)
        #expect(draft.rows[0].done)
        #expect(draft.rows[1].load == 170 && draft.rows[2].load == 170 && draft.rows[2].value == 4)
        #expect(draft.rows[3].load == 50) // another exercise is untouched
        // Skipping ahead and finishing the last set points back to the first one left.
        #expect(draft.finish(4) == 1)
        draft.rows[1].done = true
        draft.rows[2].done = true
        #expect(draft.finish(3) == nil)
    }

    @Test func carryingForwardKeepsAPlannedRamp() {
        var plan = SessionPlan([squat])
        plan.set("load_lb", to: 175, block: 0, movement: 0, set: 2, remaining: false) // top set planned heavier
        var draft = WorkoutDraft(session: "A", plan: plan)
        draft.rows[0].load = 170
        draft.finish(0)
        #expect(draft.rows.map(\.load) == [170, 170, 175])
    }

    @Test func restDependsOnTheSet() {
        let draft = WorkoutDraft(session: "Session A", plan: SessionPlan([squat, carry]))
        #expect(WorkoutDraft.rest(after: draft.rows[0]) == 180) // 5 reps
        var light = draft.rows[0]
        light.value = 10
        #expect(WorkoutDraft.rest(after: light) == 90)
        #expect(WorkoutDraft.rest(after: draft.rows[3]) == 60) // distance
    }

    @Test func plannedTargetsStepByMetric() {
        #expect(WorkoutDetailView.step("load_lb") == 5)
        #expect(WorkoutDetailView.step("rpe") == 0.5)
        #expect(WorkoutDetailView.step("reps") == 1)
        #expect(WorkoutDetailView.label("load_lb_hand") == "Load per hand")
    }

    @Test func supersetRowsAlternateByRoundWithRestOnlyAfterEachRound() {
        let row = SessionPlan.Item(id: UUID(), exercise: "db-row", targets: [
            Measurement(metric: "sets", value: 3, unit: "sets"), Measurement(metric: "reps", value: 10, unit: "reps")], group: 1)
        var bench = row
        bench.exercise = "db-bench"
        bench.targets[0].value = 2
        let draft = WorkoutDraft(session: "B", plan: SessionPlan([squat, row, bench]))
        #expect(draft.rows.map(\.exercise) == ["back-squat", "back-squat", "back-squat", "db-row", "db-bench", "db-row", "db-bench", "db-row"])
        #expect(draft.rows.map(\.block) == [0, 0, 0, 1, 1, 1, 1, 1])
        #expect(draft.rows.map(\.round) == [0, 1, 2, 0, 0, 1, 1, 2])
        #expect(draft.rest(after: 0) == 180)
        #expect(draft.rest(after: 3) == 0) // db-row → db-bench, same round
        #expect(draft.rest(after: 4) == 90) // end of round 1
        #expect(draft.rest(after: 7) == 90) // last set
    }

    @Test func durationIsSavedWithTheSummaryWhenKnown() {
        var draft = WorkoutDraft(session: "A", plan: SessionPlan([squat]))
        #expect(!draft.summary.contains { $0.metric == "duration_s" })
        draft.duration = 3252.4
        #expect(draft.summary.last == Measurement(metric: "duration_s", value: 3252, unit: "s"))
    }

    // MARK: Workout mode (FIT-28)

    private var superset: [SessionPlan.Item] {
        ["dumbbell-row", "dumbbell-bench"].map {
            SessionPlan.Item(id: UUID(), exercise: $0, targets: [
                Measurement(metric: "sets", value: 2, unit: "sets"), Measurement(metric: "reps", value: 10, unit: "reps"),
                Measurement(metric: "load_lb_hand", value: 50, unit: "lb/hand")], group: 1)
        }
    }

    @Test func aSupersetRoundIsOneLine() {
        let draft = WorkoutDraft(session: "B", plan: SessionPlan([squat] + superset))
        #expect(draft.blocks == [0, 1])
        #expect(draft.lines(block: 0) == [[0], [1], [2]])
        #expect(draft.lines(block: 1) == [[3, 4], [5, 6]])
    }

    @Test func tickingLogsTheLineRestsAndSaysWhenTheExerciseIsDone() {
        var draft = WorkoutDraft(session: "B", plan: SessionPlan([squat] + superset))
        #expect(draft.tick([0]) == (180, false))
        draft.tick([1])
        #expect(draft.tick([2]).blockDone)
        #expect(draft.tick([3, 4]) == (90, false)) // whole round ticked, rest after its last movement
        draft.untick([3, 4])
        #expect(!draft.rows[3].done && !draft.rows[4].done)
    }

    @Test func adjustingALineStepsRepsAndLoadAndClearsHeard() {
        var draft = WorkoutDraft(session: "B", plan: SessionPlan([squat] + superset))
        draft.rows[0].heard = true
        draft.adjust([0], load: false, by: -1)
        draft.adjust([0], load: true, by: 1)
        #expect(draft.rows[0].value == 4 && draft.rows[0].load == 170 && !draft.rows[0].heard)
        draft.adjust([3, 4], load: true, by: -1)
        #expect(draft.rows[3].load == 45 && draft.rows[4].load == 45)
    }

    @Test func volumeCountsDoneSetsAndBothHands() {
        var draft = WorkoutDraft(session: "B", plan: SessionPlan([squat] + superset))
        draft.tick([0])
        draft.tick([3, 4])
        #expect(draft.volume == 5 * 165 + 2 * 10 * 50 * 2)
    }

    @Test func liftsReadTheProgressionRuleWithTheSessionsFeel() {
        var draft = WorkoutDraft(session: "B", plan: SessionPlan([squat]))
        for line in draft.lines(block: 0) { draft.tick(line) }
        let tier = AgeTier.of(age: 38) // top RPE 8: progress at 7 or easier
        draft.feel = .good
        #expect(draft.lifts(main: ["back-squat"], names: ["back-squat": "Squat"], tier: tier)
                == [Coach.Lift(name: "Squat", load: 165, next: 170)])
        draft.feel = .hard
        draft.rows[2].value = 4
        let lift = draft.lifts(main: ["back-squat"], names: [:], tier: tier)[0]
        #expect(lift.next == 165 && lift.short.map(\.set) == [3])
    }
}
