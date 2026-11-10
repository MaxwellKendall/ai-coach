import Foundation
import SwiftData
import Testing
@testable import AICoach

/// FIT-342: a coach's client has no program of the app's, so each goal card runs from the day the goal was set to its
/// own date, and where it stands comes from their logs: the coach's planned sessions and anything logged by hand.
@MainActor
struct GoalWithoutProgramTests {
    private let calendar = Calendar.current
    private func date(_ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    @Test func aGoalRunsFromTheDayItWasSetToItsOwnDate() {
        let span = GoalProgress.span(created: date(9, 1, hour: 18), deadline: date(12, 1), today: date(10, 16))
        #expect(span.start == calendar.startOfDay(for: date(9, 1)))
        #expect(span.end == date(12, 1))
        // No date: to today, and at least a week, so a goal set today still has a chart.
        #expect(GoalProgress.span(created: date(9, 1), deadline: nil, today: date(10, 16)).end == date(10, 16))
        let fresh = GoalProgress.span(created: date(10, 16), deadline: nil, today: date(10, 16))
        #expect(fresh.end == calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: date(10, 16))))
    }

    @Test func paceIsAgainstTheGoalsDateAndThereIsNoneWithoutOne() {
        let start = date(9, 1), due = date(12, 1), half = date(10, 16)
        #expect(GoalProgress.pace("bench-press.1rm_lb", from: 200, now: 215, target: 250, started: start, today: half, by: due) == .behind)
        #expect(GoalProgress.pace("bench-press.1rm_lb", from: 200, now: 225, target: 250, started: start, today: half, by: due) == .onPace)
        #expect(GoalProgress.pace("bench-press.1rm_lb", from: 200, now: 235, target: 250, started: start, today: half, by: due) == .ahead)
        #expect(GoalProgress.pace("bench-press.1rm_lb", from: 200, now: 235, target: 250, started: start, today: half, by: nil) == nil)
        // A race time and a weight to lose go down.
        #expect(GoalProgress.pace(Running.metric(meters: 5000), from: 1680, now: 1600, target: 1560, started: start, today: half, by: due) == .ahead)
        #expect(GoalProgress.pace("weight_lb", from: 180, now: 179.5, target: 172, started: start, today: half, by: due) == .behind)
    }

    /// The current value counts a coach's planned session and a set logged by hand alike, from the goal's start on.
    @Test func progressComesFromTheirLogsSinceTheGoalWasSet() throws {
        let context = ModelContext(try AppSchema.container(inMemory: true))
        let squat = Template(kind: .exercise, name: "Back Squat", slug: "back-squat")
        let pullup = Template(kind: .exercise, name: "Pull-up", slug: "pull-up")
        let run = Template(kind: .exercise, name: "Trail Running/Walking", slug: Running.outdoor)
        [squat, pullup, run].forEach(context.insert)
        let coachWrote = PlannedActivity(kind: .workout, date: date(10, 5))
        context.insert(coachWrote)
        func set(_ template: Template, _ day: Date, planned: UUID? = nil, _ values: [(String, Double, String)]) {
            context.insert(LogEntry(kind: .workout, timestamp: day, plannedRef: planned, templateRef: template.id,
                                    measurements: values.map { Measurement(metric: $0.0, value: $0.1, unit: $0.2) }))
        }
        // Before the goal was set: not counted.
        set(squat, date(9, 20), [("load_lb", 245), ("reps", 3)])
        set(squat, date(10, 5), planned: coachWrote.id, [("load_lb", 205), ("reps", 5)])
        set(squat, date(10, 9), [("load_lb", 225), ("reps", 3)])
        set(pullup, date(10, 9), [("reps", 9)])
        set(run, date(10, 10), [("distance_m", 5000), ("duration_s", 1590)])
        try context.save()

        let entries = try context.fetch(FetchDescriptor<LogEntry>())
        let sets = Planner.loggedSets(entries, templates: [squat, pullup, run])
        let start = GoalProgress.span(created: date(10, 1), deadline: nil, today: date(10, 16)).start
        // 225 × 3, logged by hand, beats the coach’s 205 × 5 (238 against 231).
        #expect(GoalProgress.current("back-squat.1rm_lb", sets: sets, weighIns: [], since: start) == 238)
        #expect(GoalProgress.current("pull-up.reps", sets: sets, weighIns: [], since: start) == 9)
        #expect(GoalProgress.current(Running.metric(meters: 5000), sets: sets, weighIns: [], since: start) == 1590)
        let weighIns = [DatedValue(date: date(9, 28), value: 181), DatedValue(date: date(10, 12), value: 178.4)]
        #expect(GoalProgress.current("weight_lb", sets: sets, weighIns: weighIns, since: start) == 178.4)
    }
}
