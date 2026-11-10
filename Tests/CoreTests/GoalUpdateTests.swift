import Foundation
import SwiftData
import Testing
@testable import AICoach

/// FIT-343: Update on a goal records a test as an ordinary log row its progress reads; FIT-346: a goal's target and
/// date change, and the change is in its `goal#` unit.
@MainActor
struct GoalUpdateTests {
    private let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 18))!

    private func store() throws -> ModelContext {
        let context = ModelContext(try AppSchema.container(inMemory: true))
        for (name, slug) in [("Back Squat", "back-squat"), ("Pull-up", "pull-up"), ("Trail Running/Walking", Running.outdoor)] {
            context.insert(Template(kind: .exercise, name: name, slug: slug))
        }
        try context.save()
        return context
    }

    private func current(_ metric: String, in context: ModelContext) throws -> Double? {
        let entries = try context.fetch(FetchDescriptor<LogEntry>())
        let sets = Planner.loggedSets(entries, templates: try context.fetch(FetchDescriptor<Template>()))
        let weighIns = entries.filter { $0.kind == .bodyweight }.compactMap { entry in
            entry.measurements.first { $0.metric == "weight_lb" }.map { DatedValue(date: entry.timestamp, value: $0.value) }
        }
        return GoalProgress.current(metric, sets: sets, weighIns: weighIns, since: .distantPast)
    }

    private func synced(_ context: ModelContext) throws -> [SyncUnits.LogRow] {
        try SyncUnits.decode([SyncUnits.LogRow].self, try #require(try SyncUnits.all(in: context)["log#2026-11-10"]))
    }

    @Test func aSingleIsAWorkoutRowOnTheLiftAndMovesItsMax() throws {
        let context = try store()
        let squat = GoalOption.with(id: "squat")!
        #expect(try current(squat.metric, in: context) == nil)
        try GoalUpdate.save(squat, .lift(load: 315, reps: 1), note: " Felt fast ", in: context, now: now)
        let rows = try synced(context)
        #expect(rows.count == 1)
        #expect(rows[0].kind == .workout && rows[0].template == "back-squat" && rows[0].note == "Felt fast")
        #expect(rows[0].measurements == [Measurement(metric: "load_lb", value: 315, unit: "lb"), Measurement(metric: "reps", value: 1, unit: "reps"),
                                         GoalUpdate.marker])
        #expect(try current(squat.metric, in: context) == 315)
        // A rep max counts by Brzycki: 285 × 3 is 302, under the single.
        try GoalUpdate.save(squat, .lift(load: 285, reps: 3), note: "", in: context, now: now)
        #expect(try current(squat.metric, in: context) == 315)
    }

    @Test func repsAreAnUnloadedSet() throws {
        let context = try store()
        let pullups = GoalOption.with(id: "pullups")!
        try GoalUpdate.save(pullups, .reps(12), note: "", in: context, now: now)
        let row = try #require(try synced(context).first)
        #expect(row.template == "pull-up" && row.measurements == [Measurement(metric: "reps", value: 12, unit: "reps"), GoalUpdate.marker])
        #expect(try current(pullups.metric, in: context) == 12)
    }

    @Test func aRaceTimeIsARun() throws {
        let context = try store()
        let fiveK = GoalOption.with(id: "5k")!
        try GoalUpdate.save(fiveK, .run(meters: 5000, seconds: 24 * 60 + 10), note: "Parkrun", in: context, now: now)
        let row = try #require(try synced(context).first)
        #expect(row.template == Running.outdoor)
        #expect(row.measurements == [Measurement(metric: "distance_m", value: 5000, unit: "m"), Measurement(metric: "duration_s", value: 1450, unit: "s"),
                                     GoalUpdate.marker])
        #expect(try current(fiveK.metric, in: context) == 1450)
    }

    @Test func bodyWeightIsCheckInsRow() throws {
        let context = try store()
        try GoalUpdate.save(GoalOption.with(id: "weight")!, .weight(176.4), note: "", in: context, now: now)
        let rows = try synced(context)
        #expect(rows.count == 1 && rows[0].kind == .bodyweight && rows[0].measurements == [Measurement(metric: "weight_lb", value: 176.4, unit: "lb")])
        #expect(try current("weight_lb", in: context) == 176.4)
    }

    /// A test isn't the day's session: a day with only a test is still a rest day, or still its planned session.
    @Test func aTestIsntTheDaysSession() throws {
        let context = try store()
        try GoalUpdate.save(GoalOption.with(id: "squat")!, .lift(load: 315, reps: 1), note: "", in: context, now: now)
        let entries = try context.fetch(FetchDescriptor<LogEntry>())
        let card = DayCard.make(day: now, planned: [], entries: entries, next: nil,
                                context: DayCard.Context(templates: try context.fetch(FetchDescriptor<Template>()), sessionMinutes: 45,
                                                         deload: false, tier: .of(age: 32)))
        guard case .rest = card else { Issue.record("A test made the day a session"); return }
    }

    @Test func aGoalsTargetAndDateChangeInItsUnit() throws {
        let context = try store()
        let goal = Goal(kind: .training, metric: "back-squat.1rm_lb", target: 265, unit: "lb", deadline: now)
        context.insert(goal)
        try context.save()
        let due = Calendar.current.date(from: DateComponents(year: 2027, month: 3, day: 1, hour: 15))!
        try GoalChange.apply(goal, target: 275, deadline: due, in: context, now: now)
        var body = try SyncUnits.decode(SyncUnits.GoalBody.self, try #require(try SyncUnits.all(in: context)["goal#\(goal.id.uuidString)"]))
        #expect(body.target == 275 && body.deadline == Calendar.current.startOfDay(for: due))
        // The date can be cleared.
        try GoalChange.apply(goal, target: 275, deadline: nil, in: context, now: now)
        body = try SyncUnits.decode(SyncUnits.GoalBody.self, try #require(try SyncUnits.all(in: context)["goal#\(goal.id.uuidString)"]))
        #expect(body.deadline == nil && goal.updatedAt == now)
    }
}
