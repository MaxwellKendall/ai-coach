import Foundation
import SwiftData
import Testing
@testable import AICoach

/// FIT-82: the week runs Sunday to Saturday; day numbers stay 0 = Monday.
@MainActor
struct WeekStartTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }
    private func date(_ month: Int, _ day: Int, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    @Test func weeksStartOnSunday() {
        // Wed Oct 7 2026 is in the week of Sun Oct 4; Sun Oct 11 starts the next.
        #expect(Week.start(of: date(10, 7, hour: 9), calendar: calendar) == date(10, 4))
        #expect(Week.start(of: date(10, 11, hour: 9), calendar: calendar) == date(10, 11))
        #expect(Week.start(of: date(10, 10, hour: 23), calendar: calendar) == date(10, 4))
        // Monday is still day 0, the second day of the week; Sunday, day 6, the first.
        #expect(Week.date(0, in: date(10, 4), calendar: calendar) == date(10, 5))
        #expect(Week.date(6, in: date(10, 4), calendar: calendar) == date(10, 4))
        #expect(Week.day(of: date(10, 11), calendar: calendar) == 6)
        #expect(Week.ordered([0, 2, 6]) == [6, 0, 2])
    }

    @Test func aWeekIsPlannedSundayToSaturday() {
        let settings = TrainingSettings(age: 36, daysPerWeek: 3, sessionMinutes: 45, trainingDays: Week.ordered([6, 2, 4]),
                                        workoutTime: 420, equipment: ["barbell", "rack", "dumbbells", "bench", "pull_up_bar"],
                                        maxWeeklySets: 60)
        let catalog = [("back-squat", "squat"), ("bench-press", "push"), ("pull-up", "pull"), ("deadlift", "hinge"), ("plank", "core")]
            .compactMap { Exercise(slug: $0.0, attributes: [TemplateAttribute(key: "movement_pattern", values: [$0.1])]) }
        let week = TrainingGenerator.week(startingOn: date(10, 4), settings: settings, catalog: catalog, history: [],
                                          weeksSinceDeload: 0, calendar: calendar)
        let days = Set(week.workouts.map { calendar.startOfDay(for: $0.date) })
        // Sunday Oct 4, Wednesday Oct 7, Friday Oct 9: all inside the week.
        #expect(days == [date(10, 4), date(10, 7), date(10, 9)])
    }

    /// Plans made when weeks began on Monday: keyed by the Sunday before, and a Sunday's items move to the next week.
    @Test func mondayPlansAreRekeyed() throws {
        let context = ModelContext(try AppSchema.container(inMemory: true))
        let plan = Plan(weekContaining: date(10, 7), calendar: calendar)
        plan.weekStart = date(10, 5)   // as saved before
        context.insert(plan)
        plan.items = [PlannedActivity(kind: .workout, date: date(10, 5, hour: 7), slot: "Upper"),
                      PlannedActivity(kind: .workout, date: date(10, 11, hour: 7), slot: "Lower")]
        let profile = Profile(age: 36, weightLb: 200)
        profile.programStart = date(10, 5)
        profile.targetDate = date(12, 6)
        context.insert(profile)
        try context.save()

        try Planner.rekeyWeeks(in: context, calendar: calendar)
        let plans = try context.fetch(FetchDescriptor<Plan>()).sorted { $0.weekStart < $1.weekStart }
        #expect(plans.map(\.weekStart) == [date(10, 4), date(10, 11)])
        #expect(plans[0].items.map(\.slot) == ["Upper"])
        #expect(plans[1].items.map(\.slot) == ["Lower"])
        #expect(plans[1].updatedAt < plans[1].weekStart)   // planned again when its week starts
        #expect(profile.programStart == date(10, 4) && profile.targetDate == date(12, 5))
        // Once: nothing changes the second time.
        try Planner.rekeyWeeks(in: context, calendar: calendar)
        #expect(try context.fetchCount(FetchDescriptor<Plan>()) == 2)
    }
}
