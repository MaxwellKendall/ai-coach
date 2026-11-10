import Foundation
import Testing
@testable import AICoach

/// FIT-336: a coach's week tools: copied forward with 5 lb a week, a deload, a ready-made program.
@MainActor
struct ClientWeekTests {
    private let calendar = Calendar.current
    private func day(_ d: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: d))! }
    private func row(_ slug: String, on date: Date, sets: Double = 3, load: Double? = nil, rpe: Double? = nil, main: Bool = false,
                     note: String = "") -> SyncUnits.PlanRow {
        var targets = [Measurement(metric: "sets", value: sets, unit: "sets"), Measurement(metric: "reps", value: 5, unit: "reps")]
        if let load { targets.append(Measurement(metric: "load_lb", value: load, unit: "lb")) }
        if let rpe { targets.append(Measurement(metric: "rpe", value: rpe, unit: "RPE")) }
        return SyncUnits.PlanRow(id: UUID(), kind: .workout, at: date + 7 * 3600, slot: "Lower", template: slug, targets: targets,
                                 note: note, adjustedReason: nil, group: nil, main: main, pinned: false)
    }

    @Test func repeatedCopiesEachWeekOnAndAddsFivePoundsAWeekToTheMainLift() {
        let week: ClientWeek.Days = ["2026-11-09": [row("back-squat", on: day(9), load: 225, main: true), row("leg-curl", on: day(9), load: 60)]]
        let three = ClientWeek.repeated(week, weeks: 3, progress: true)
        #expect(three.keys.sorted() == ["2026-11-16", "2026-11-23", "2026-11-30"])
        let squat = { (key: String) in three[key]!.first { $0.template == "back-squat" }!.targets.first { $0.metric == "load_lb" }!.value }
        #expect([squat("2026-11-16"), squat("2026-11-23"), squat("2026-11-30")] == [230, 235, 240])
        #expect(three["2026-11-30"]!.first { $0.template == "leg-curl" }!.targets.first { $0.metric == "load_lb" }!.value == 60)
        #expect(three["2026-11-16"]![0].adjustedReason == "+5 lb")
        let flat = ClientWeek.repeated(week, weeks: 1, progress: false)
        #expect(flat["2026-11-16"]!.first { $0.template == "back-squat" }!.targets.first { $0.metric == "load_lb" }!.value == 225)
    }

    @Test func aDeloadIsFewerSetsLighterAndEasierAndLeavesTheWarmUpAlone() {
        let rows = ClientWeek.deloaded([row("rowing-machine", on: day(12), sets: 1, note: TrainingGenerator.warmupNote),
                                        row("back-squat", on: day(12), sets: 5, load: 225, rpe: 8, main: true)])
        #expect(rows[0].targets == row("rowing-machine", on: day(12), sets: 1).targets)
        let squat = rows[1]
        #expect(squat.targets.first { $0.metric == "sets" }?.value == 3)          // 5 × 0.55, rounded
        #expect(squat.targets.first { $0.metric == "load_lb" }?.value == 195)     // 225 × 0.87, to 5 lb
        #expect(squat.targets.first { $0.metric == "rpe" }?.value == 6)
        #expect(ReadyProgram.Why.explains(squat.adjustedReason))
    }

    @Test func aProgramPlansEveryWeekOnTheClientsDays() throws {
        let templates = try Seeder.decode([TemplateSeed].self, "exercises", .main)
            .map { Template(kind: $0.kind, name: $0.name, slug: $0.slug, attributes: $0.attributes) }
        let ready = try #require(ReadyProgram.all.first { $0.days.contains(3) })
        let profile = SyncUnits.ProfileBody(age: 35, weightLb: 180, targetWeightLb: nil, daysPerWeek: 3, sessionMinutes: 45,
                                            trainingDays: [0, 2, 4], workoutTime: 420, equipment: Profile.allEquipment, injuredAreas: [],
                                            fineAreas: [:], avoidExercises: [], maxWeeklySets: 60, style: .powerbuilding, warmups: true,
                                            deloadEveryWeeks: nil, cookWindows: [], groceryDay: nil, travelWeeks: [], starts: [])
        let plan = ClientWeek.program(ready, from: day(16), profile: profile, logs: [], templates: templates)
        let weekdays = Set(plan.keys.compactMap { SyncUnits.date(ofKey: "plan#\($0)") }.map { calendar.component(.weekday, from: $0) })
        #expect(weekdays == [2, 4, 6])                     // Monday, Wednesday, Friday
        #expect(plan.count == 3 * ready.weeks)
        #expect(plan.values.allSatisfy { $0.allSatisfy { $0.pinned && $0.template != nil } })
    }
}
