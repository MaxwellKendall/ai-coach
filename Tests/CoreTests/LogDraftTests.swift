import Foundation
import Testing
@testable import AICoach

struct LogDraftTests {
    private let squat = WorkoutDraft.Planned(id: UUID(), exercise: "back-squat", targets: [
        Measurement(metric: "sets", value: 3, unit: "sets"), Measurement(metric: "reps", value: 5, unit: "reps"),
        Measurement(metric: "load_lb", value: 165, unit: "lb"), Measurement(metric: "rpe", value: 8, unit: "RPE")], note: "")
    private let warmup = WorkoutDraft.Planned(id: UUID(), exercise: "back-squat", targets: [
        Measurement(metric: "sets", value: 1, unit: "sets"), Measurement(metric: "reps", value: 5, unit: "reps")],
        note: TrainingGenerator.warmupNote)
    private let carry = WorkoutDraft.Planned(id: UUID(), exercise: "farmer-carry", targets: [
        Measurement(metric: "sets", value: 2, unit: "sets"), Measurement(metric: "distance_m", value: 30, unit: "m"),
        Measurement(metric: "load_lb_hand", value: 50, unit: "lb/hand")], note: "")

    @Test func plannedSetsBecomeOneRowEachWithoutWarmups() {
        let draft = WorkoutDraft(session: "Session A", planned: [warmup, squat, carry])
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
        var draft = WorkoutDraft(session: "Session A", planned: [squat, carry])
        #expect(draft.completion == 0)
        draft.rows[0].done = true
        draft.rows[1].done = true
        draft.rows[2].rpe = 8
        #expect(abs(draft.completion - 0.4) < 0.0001)
        let summary = Dictionary(uniqueKeysWithValues: draft.summary.map { ($0.metric, $0.value) })
        #expect(summary["completion_rate"] == draft.completion)
        #expect(summary["effort"] == 7 && summary["energy_level"] == 3 && summary["form_quality"] == 3)
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
        var draft = WorkoutDraft(session: "Session A", planned: [squat, carry])
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

    @Test func restDependsOnTheSet() {
        let draft = WorkoutDraft(session: "Session A", planned: [squat, carry])
        #expect(WorkoutDraft.rest(after: draft.rows[0]) == 180) // 5 reps
        var light = draft.rows[0]
        light.value = 10
        #expect(WorkoutDraft.rest(after: light) == 90)
        #expect(WorkoutDraft.rest(after: draft.rows[3]) == 60) // distance
    }

    @Test func plannedTargetsStepByMetric() {
        #expect(WorkoutEditor.step("load_lb") == 5)
        #expect(WorkoutEditor.step("rpe") == 0.5)
        #expect(WorkoutEditor.step("reps") == 1)
        #expect(WorkoutEditor.label("load_lb_hand") == "Load per hand")
    }
}
