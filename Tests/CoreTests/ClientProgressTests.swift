import Foundation
import Testing
@testable import AICoach

/// FIT-337: a client's progress from their units, and a coach correcting a logged set.
@MainActor
struct ClientProgressTests {
    private let calendar = Calendar.current
    private func day(_ d: Int, hour: Int = 18) -> Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: d, hour: hour))! }
    private func json<T: Encodable>(_ value: T) -> String { SyncUnits.encode(value) }
    private func set(_ slug: String, _ d: Int, load: Double, reps: Double, rpe: Double? = nil) -> SyncUnits.LogRow {
        SyncUnits.LogRow(id: UUID(), kind: .workout, at: day(d), plannedRef: nil, template: slug,
                         measurements: [Measurement(metric: "reps", value: reps, unit: "reps"), Measurement(metric: "load_lb", value: load, unit: "lb")]
                            + (rpe.map { [Measurement(metric: "rpe", value: $0, unit: "RPE")] } ?? []),
                         note: "Lower A")
    }
    private func checkIn(_ d: Int, weight: Double, note: String) -> SyncUnits.LogRow {
        SyncUnits.LogRow(id: UUID(), kind: .bodyweight, at: day(d, hour: 7), plannedRef: nil, template: nil,
                         measurements: [Measurement(metric: "weight_lb", value: weight, unit: "lb")], note: note)
    }

    private var units: [String: String] {
        let goal = SyncUnits.GoalBody(kind: .training, metric: "back-squat.1rm_lb", target: 300, unit: "lb", deadline: nil, baseline: 250, status: .active)
        let done = SyncUnits.GoalBody(kind: .training, metric: "bench-press.1rm_lb", target: 200, unit: "lb", deadline: nil, baseline: nil, status: .achieved)
        return [
            "log#2026-11-02": json([set("back-squat", 2, load: 245, reps: 5), set("back-squat", 2, load: 245, reps: 5), set("bench-press", 2, load: 155, reps: 5)]),
            "log#2026-11-09": json([set("back-squat", 9, load: 250, reps: 5), checkIn(9, weight: 182, note: "Slept badly")]),
            "log#2026-11-10": json([checkIn(10, weight: 181.4, note: "Slept badly")]),
            "plan#2026-11-11": json([SyncUnits.PlanRow(id: UUID(), kind: .workout, at: day(11), slot: "Lower", template: "back-squat", targets: [],
                                                       note: "", adjustedReason: nil, group: nil, main: true, pinned: true)]),
            "goal#a": json(goal), "goal#b": json(done),
        ]
    }

    @Test func setsCheckInsAndGoalsComeFromTheUnits() {
        let sets = ClientProgress.sets(units)
        #expect(sets.count == 4)
        #expect(ClientProgress.mainLifts(sets) == ["back-squat", "bench-press"])
        #expect(ClientProgress.checkIns(units, "weight_lb").map(\.value) == [182, 181.4])
        #expect(ClientProgress.notes(units).map(\.text) == ["Slept badly"])          // the same words once
        #expect(ClientProgress.goals(units).map(\.metric) == ["back-squat.1rm_lb"])   // achieved ones aren't shown
    }

    @Test func weeksCountDaysTrainedOfDaysPlanned() {
        let weeks = ClientProgress.weeks(units, today: day(10), weeks: 2)
        #expect(weeks.map(\.done) == [1, 1])
        #expect(weeks.map(\.planned) == [1, 2])
    }

    @Test func aGoalIsNamedForItsLift() {
        let names = ["back-squat": "Back Squat"]
        #expect(ClientProgressScreen.goalName("back-squat.1rm_lb", names: names) == "Back Squat max")
        #expect(ClientProgressScreen.goalName("weight_lb", names: names) == "Bodyweight")
    }

    @Test func aFixChangesOnlyThatSetsNumbers() {
        let rows = [set("back-squat", 9, load: 250, reps: 5, rpe: 9), set("back-squat", 9, load: 250, reps: 5)]
        let fixed = ClientDay.fixed(rows, id: rows[0].id, ClientDay.SetFix(load: 255, reps: 3, rpe: nil))
        #expect(fixed[0].measurements.first { $0.metric == "load_lb" }?.value == 255)
        #expect(fixed[0].measurements.first { $0.metric == "reps" }?.value == 3)
        #expect(!fixed[0].measurements.contains { $0.metric == "rpe" })
        #expect(fixed[1] == rows[1])
        #expect(fixed[0].note == rows[0].note)
    }
}
