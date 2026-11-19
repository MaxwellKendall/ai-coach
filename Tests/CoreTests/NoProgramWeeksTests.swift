import Foundation
import SwiftData
import Testing
@testable import AICoach

/// TKL-845: the Program tab without a program. A lifter on their own sees this week and next as the deck, planned or
/// not; a coach's client keeps every week the coach planned. "Set a goal" with a date makes it the program.
@MainActor
struct NoProgramWeeksTests {
    private let calendar = Calendar.current
    private func date(_ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }
    private var this: Date { Week.start(of: date(11, 18)) }
    private func weeks(_ count: Int, from monday: Date) -> Date { calendar.date(byAdding: .day, value: 7 * count, to: monday)! }

    @Test func onTheirOwnTheDeckIsThisWeekAndNextWhateverIsPlanned() {
        let expected = [this, weeks(1, from: this)]
        #expect(PlannedDeck.mondays(planned: [], this: this, coached: false) == expected)
        #expect(PlannedDeck.mondays(planned: [date(11, 18)], this: this, coached: false) == expected)
        // Weeks planned long ago or far ahead don't widen it.
        #expect(PlannedDeck.mondays(planned: [date(10, 1), date(12, 20)], this: this, coached: false) == expected)
    }

    @Test func aCoachsClientKeepsEveryPlannedWeek() {
        #expect(PlannedDeck.mondays(planned: [], this: this, coached: true).isEmpty)
        let deck = PlannedDeck.mondays(planned: [date(11, 4), date(11, 26)], this: this, coached: true)
        #expect(deck == [weeks(-2, from: this), weeks(-1, from: this), this, weeks(1, from: this)])
    }

    @Test func theSuggestedDateIsTwelveWeeksOn() {
        let by = NewGoal.suggestedDate(now: date(11, 18))
        #expect(ProgramPlan.weekCount(start: this, target: by) == 12)
    }

    @Test func aGoalWithADateStartsTheProgramThisWeekKeepingWhatsPlanned() throws {
        let container = try AppSchema.container(inMemory: true)
        let context = container.mainContext
        let profile = Profile(age: 34, weightLb: 180)
        profile.programSlug = "full-body-3"
        context.insert(profile)
        let goal = Goal(kind: .training, metric: "back-squat.1rm_lb", target: 315, unit: "lb")
        context.insert(goal)
        let session = PlannedActivity(kind: .workout, date: date(11, 18), slot: "Lower A")
        context.insert(session)
        try context.save()
        #expect(profile.program == nil)

        let by = date(2027, 3, 1)
        try Planner.startProgram(by: by, goal: goal, profile: profile, in: context, now: date(11, 18))

        #expect(profile.programStart == this)
        #expect(profile.targetDate == calendar.startOfDay(for: by))
        #expect(profile.programSlug == nil)
        #expect(goal.deadline == calendar.startOfDay(for: by))
        #expect((profile.program?.count ?? 0) > 1)
        #expect(try context.fetch(FetchDescriptor<PlannedActivity>()).count == 1)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }
}
