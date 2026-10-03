import Foundation
import Testing
import SwiftData
@testable import AICoach

private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}

private func date(_ month: Int, _ day: Int, hour: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
}

private func sets(_ count: Int, on day: Date) -> [LoggedSet] {
    (0..<count).map { _ in LoggedSet(date: day, exercise: "x", pattern: "push", measurements: []) }
}

struct PlanRulesTests {
    @Test func weeksSinceDeloadCountsFullWeeksBackToALightOne() {
        // Weeks of Jun 1, 8 (light), 15, 22, 29: 15 sets except the light week.
        let history = sets(15, on: date(6, 1, hour: 12)) + sets(4, on: date(6, 8, hour: 12))
            + sets(15, on: date(6, 15, hour: 12)) + sets(15, on: date(6, 22, hour: 12)) + sets(15, on: date(6, 29, hour: 12))
        #expect(Training.weeksSinceDeload(history, before: date(7, 6), calendar: calendar) == 3)
        // A missed week counts as rest.
        #expect(Training.weeksSinceDeload(history, before: date(7, 13), calendar: calendar) == 0)
        #expect(Training.weeksSinceDeload([], before: date(7, 6), calendar: calendar) == 0)
    }

    @Test(arguments: [(10, 170.0), (20, 165), (90, 150)])
    func timeOffHoldsThenDropsLoads(daysOff: Int, expected: Double) {
        #expect(TrainingGenerator.nextLoad(165, lastRPE: 7, main: true, tier: AgeTier.of(age: 36), deload: false,
                                           daysOff: daysOff) == expected)
    }

    @Test func kitchenBlocksFollowTheGroceryRun() {
        let blocks = KitchenSchedule.week(
            startingOn: date(7, 20), cookWindows: [CookWindow(day: 5, hours: 2, label: "Bulk cook"),
                                                   CookWindow(day: 2, hours: 1, label: "Midweek refresh")],
            groceryDay: 5, calendar: calendar)
        #expect(blocks.map(\.label) == ["Midweek refresh", "Grocery run", "Bulk cook"])
        #expect(blocks.map(\.date) == [date(7, 22, hour: 18), date(7, 25, hour: 9), date(7, 25, hour: 13)])
        #expect(blocks.map(\.kind) == [.cook, .grocery, .cook])
    }
}

@MainActor
struct PlannerTests {
    /// The context doesn't retain its container, so the test keeps it.
    private let container = try! AppSchema.container(inMemory: true)

    private func store() throws -> ModelContext {
        let context = container.mainContext
        try Seeder.seedIfEmpty(context)
        return context
    }

    @Test func noPlanUntilTheProfileIsComplete() throws {
        let context = try store()
        context.insert(Profile(age: 0, weightLb: 0))
        try Planner.ensureWeek(of: date(10, 5), in: context)
        #expect(try context.fetchCount(FetchDescriptor<Plan>()) == 0)
    }

    @Test func generatesWorkoutsAndKitchenAndRegeneratesIdempotently() throws {
        let context = try store()
        context.insert(Profile(age: 36, weightLb: 200, cookWindows: [CookWindow(day: 5, hours: 2, label: "Bulk cook")],
                               groceryDay: 5))
        try Planner.ensureWeek(of: date(10, 7), in: context)
        let plan = try #require(try Planner.plan(weekOf: date(10, 5), in: context))
        let workouts = plan.items.filter { $0.kind == .workout }
        #expect(Set(workouts.map { Calendar.current.component(.weekday, from: $0.date) }) == [2, 4, 6])
        #expect(workouts.allSatisfy { $0.templateRef != nil })
        #expect(plan.items.filter { $0.kind != .workout }.map(\.kind).sorted { $0.rawValue < $1.rawValue } == [.cook, .grocery])
        // Exercises keep the generator's order.
        #expect(workouts.sorted { $0.date < $1.date }.map(\.date) == workouts.map(\.date).sorted())

        let count = plan.items.count
        try Planner.generate(weekOf: date(10, 9), in: context)
        #expect(try context.fetchCount(FetchDescriptor<Plan>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<PlannedActivity>()) == count)
        try Planner.ensureWeek(of: date(10, 5), in: context) // already planned: untouched
        #expect(try context.fetchCount(FetchDescriptor<PlannedActivity>()) == count)
    }

    @Test func adjustOnlyTouchesRemainingDaysAndRoundTrips() throws {
        let context = try store()
        context.insert(Profile(age: 36, weightLb: 200))
        let plan = try #require(try Planner.generate(weekOf: date(10, 5), in: context))
        let templates = try context.fetch(FetchDescriptor<Template>())
        let before = Planner.workouts(plan, templates: templates)
        #expect(before.allSatisfy { calendar.component(.second, from: $0.date) == 0 && !$0.exercise.isEmpty })

        // Wednesday morning: Monday is past; low energy for Friday.
        let friday = try #require(before.last?.date)
        let result = try #require(Planner.adjust(plan, templates: templates, today: date(10, 7, hour: 6)) {
            TrainingAdjuster.energy($0, on: friday)
        })
        #expect(result.past.allSatisfy { calendar.component(.weekday, from: $0.date) == 2 })
        #expect(result.after.filter { $0.date == friday && $0.note == nil }.allSatisfy { $0.adjustedReason != nil })

        try Planner.apply(result.past + result.after, to: plan, templates: templates, in: context)
        let after = Planner.workouts(plan, templates: templates)
        #expect(after.count == before.count)
        #expect(Array(after.prefix(result.past.count)) == result.past)
        #expect(try context.fetchCount(FetchDescriptor<PlannedActivity>()) == before.count)
    }

    /// FIT-44: a changed program re-plans the rest of the week; past and kept days stay, and Undo puts it back.
    @Test func replanKeepsPastAndKeptDaysAndUndoes() throws {
        let context = try store()
        let profile = Profile(age: 36, weightLb: 200)
        context.insert(profile)
        let plan = try #require(try Planner.generate(weekOf: date(10, 5), in: context, calendar: calendar))
        let templates = try context.fetch(FetchDescriptor<Template>())
        let before = Planner.workouts(plan, templates: templates)
        func on(_ day: Int, _ workouts: [PlannedWorkout]) -> [PlannedWorkout] {
            workouts.filter { calendar.isDate($0.date, inSameDayAs: date(10, day)) }
        }
        #expect(!on(5, before).isEmpty && !on(7, before).isEmpty && !on(9, before).isEmpty)

        // Wednesday morning, Friday pinned; training moves to Tuesday, Thursday and Saturday.
        profile.trainingDays = [1, 3, 5]
        let new = try Planner.preview(weekOf: date(10, 5), in: context, calendar: calendar)
        let keep: Set<Date> = [date(10, 9)]
        let removed = try Planner.replan(plan, with: new, keep: keep, today: date(10, 7, hour: 6), templates: templates,
                                         in: context, calendar: calendar)
        let after = Planner.workouts(plan, templates: templates)
        #expect(removed == on(7, before))
        #expect(on(5, after) == on(5, before))
        #expect(on(9, after) == on(9, before))
        #expect(on(6, after).isEmpty && on(7, after).isEmpty)
        #expect(on(8, after) == on(8, new) && !on(8, after).isEmpty)
        #expect(on(10, after) == on(10, new) && !on(10, after).isEmpty)

        try Planner.replan(plan, with: removed, keep: keep, today: date(10, 7, hour: 6), templates: templates,
                           in: context, calendar: calendar)
        #expect(Planner.workouts(plan, templates: templates).sorted { $0.date < $1.date } == before)
        #expect(try context.fetchCount(FetchDescriptor<PlannedActivity>()) == plan.items.count)
    }

    /// FIT-45: a week saved before it began is planned again when it starts; its pinned days stay.
    @Test func aWeekSavedEarlyIsPlannedAgainExceptPinnedDays() throws {
        let context = try store()
        let profile = Profile(age: 36, weightLb: 200)
        context.insert(profile)
        let plan = try #require(try Planner.generate(weekOf: date(10, 5), in: context, calendar: calendar))
        plan.updatedAt = date(10, 1)
        for item in plan.items where calendar.isDate(item.date, inSameDayAs: date(10, 7)) { item.pinned = true }
        let templates = try context.fetch(FetchDescriptor<Template>())
        let before = Planner.workouts(plan, templates: templates)
        func on(_ day: Int, _ workouts: [PlannedWorkout]) -> [PlannedWorkout] {
            workouts.filter { calendar.isDate($0.date, inSameDayAs: date(10, day)) }
        }

        profile.trainingDays = [1, 3, 5]
        try Planner.ensureWeek(of: date(10, 5), in: context, calendar: calendar)
        let after = Planner.workouts(plan, templates: templates)
        #expect(on(7, after) == on(7, before) && !on(7, after).isEmpty)
        #expect(on(5, after).isEmpty && on(9, after).isEmpty)
        #expect(!on(6, after).isEmpty && !on(8, after).isEmpty && !on(10, after).isEmpty)
        #expect(try context.fetchCount(FetchDescriptor<Plan>()) == 1)
    }

    /// FIT-29: Undo writes the week back as it was.
    @Test func applyingTheOldWorkoutsUndoesAChange() throws {
        let context = try store()
        context.insert(Profile(age: 36, weightLb: 200))
        let plan = try #require(try Planner.generate(weekOf: date(10, 5), in: context))
        let templates = try context.fetch(FetchDescriptor<Template>())
        let before = Planner.workouts(plan, templates: templates)
        let friday = try #require(before.last?.date)
        let result = try #require(Planner.adjust(plan, templates: templates, today: date(10, 7, hour: 6)) {
            TrainingAdjuster.energy($0, on: friday)
        })
        try Planner.apply(result.past + result.after, to: plan, templates: templates, in: context)
        #expect(Planner.workouts(plan, templates: templates) != before)
        try Planner.apply(before, to: plan, templates: templates, in: context)
        #expect(Planner.workouts(plan, templates: templates) == before)
        #expect(try context.fetch(FetchDescriptor<PlannedActivity>()).filter { $0.kind == .workout }.count == before.count)
    }
}
