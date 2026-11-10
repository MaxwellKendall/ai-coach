import Foundation
import Testing
@testable import AICoach

/// FIT-335: a coach programming a client's days: rows moved, copied, added after what's there, a new exercise, a run.
@MainActor
struct ClientDayTests {
    private let calendar = Calendar.current
    private func day(_ d: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: d))! }
    private func row(_ slug: String, at date: Date, pinned: Bool = false) -> SyncUnits.PlanRow {
        SyncUnits.PlanRow(id: UUID(), kind: .workout, at: date, slot: "Lower", template: slug,
                          targets: [Measurement(metric: "sets", value: 3, unit: "sets")], note: "", adjustedReason: nil, group: nil,
                          main: true, pinned: pinned)
    }

    @Test func shiftKeepsTheTimeOfDayAndPinsAndACopyGetsNewIds() {
        let rows = [row("back-squat", at: day(10) + 7 * 3600), row("romanian-deadlift", at: day(10) + 7 * 3600 + 1)]
        let moved = ClientDay.shifted(rows, to: day(12))
        #expect(moved.map(\.at) == [day(12) + 7 * 3600, day(12) + 7 * 3600 + 1])
        #expect(!moved.contains { !$0.pinned })
        #expect(moved.map(\.id) == rows.map(\.id))
        let copied = ClientDay.shifted(rows, to: day(12), fresh: true)
        let ids = Set(rows.map(\.id))
        #expect(!copied.contains { ids.contains($0.id) })
    }

    @Test func appendedGoesAfterWhatsThereInOrder() {
        let there = [row("bench-press", at: day(12) + 9 * 3600)]
        let coming = [row("back-squat", at: day(12) + 7 * 3600 + 1), row("deadlift", at: day(12) + 7 * 3600)]
        let all = ClientDay.appended(coming, to: there)
        #expect(all.compactMap(\.template) == ["bench-press", "deadlift", "back-squat"])
        #expect(all.map(\.at) == [day(12) + 9 * 3600, day(12) + 9 * 3600 + 1, day(12) + 9 * 3600 + 2])
        #expect(ClientDay.appended(coming, to: []) == coming)
    }

    @Test func aNewExerciseStartsAtThreeByTenAndIsTheMainLiftOfAnEmptyDay() {
        let first = ClientDay.exercise("back-squat", on: day(12), after: [])
        #expect(first.count == 1)
        #expect(first[0].at == day(12) + 9 * 3600)
        #expect(first[0].targets == [Measurement(metric: "sets", value: 3, unit: "sets"), Measurement(metric: "reps", value: 10, unit: "reps")])
        #expect(first[0].main && first[0].pinned)
        let second = ClientDay.exercise("pull-up", on: day(12), after: first)
        #expect(second.compactMap(\.template) == ["back-squat", "pull-up"])
        #expect(!second[1].main)
    }

    @Test func aRunIsTheOutdoorRunWithItsDistanceAndKind() {
        let run = ClientDay.run("long", miles: 6, on: day(14), after: [])[0]
        #expect(run.template == Running.outdoor)
        #expect(run.note == "long")
        #expect(run.targets.first { $0.metric == "distance_m" }?.value == (6 * Running.mile).rounded())
    }

    /// FIT-347: the picker on a coach's phone uses the client's equipment and what they've planned and logged.
    @Test func thePickerUsesTheClientsProfileAndUnits() {
        let log = SyncUnits.LogRow(id: UUID(), kind: .workout, at: day(9) + 3600, plannedRef: nil, template: "pull-up",
                                   measurements: [], note: "", route: nil)
        var units = ["plan#2026-11-10": SyncUnits.encode([row("back-squat", at: day(10))]), "log#2026-11-09": SyncUnits.encode([log])]
        let uses = ClientDay.uses(units)
        #expect(Set(uses.map(\.slug)) == ["back-squat", "pull-up"])
        #expect(uses.contains { $0.slug == "pull-up" && $0.at == day(9) + 3600 })
        #expect(ClientDay.settings(units).equipment == Set(Profile.allEquipment))
        let profile = SyncUnits.ProfileBody(
            age: 40, weightLb: 180, targetWeightLb: nil, daysPerWeek: 3, sessionMinutes: 45, trainingDays: [1, 3, 5], workoutTime: 420,
            equipment: ["dumbbells"], injuredAreas: [], fineAreas: [:], avoidExercises: ["goblet-squat"], maxWeeklySets: 60,
            style: .powerbuilding, warmups: true, deloadEveryWeeks: nil, cookWindows: [], groceryDay: nil, weeklyBudgetUSD: nil,
            programStart: nil, targetDate: nil, travelWeeks: [], starts: [], brief: nil, programSlug: nil)
        units["profile"] = SyncUnits.encode(profile)
        #expect(ClientDay.settings(units).equipment == ["dumbbells"])
        #expect(ClientDay.settings(units).avoidExercises == ["goblet-squat"])
    }
}
