import Foundation
import SwiftData
import Testing
@testable import AICoach

/// FIT-126: units from the store, and the merge rules: the newest change wins per unit, deletes are tombstones,
/// and what the server sent back is never pushed again.
@MainActor
struct SyncTests {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func store() throws -> ModelContext {
        let context = ModelContext(try AppSchema.container(inMemory: true))
        context.insert(Template(kind: .exercise, name: "Bench Press", slug: "bench-press"))
        try context.save()
        return context
    }

    private func bench(_ context: ModelContext) throws -> Template {
        try #require(try context.fetch(FetchDescriptor<Template>()).first)
    }

    // MARK: State

    @Test func aLocalChangeIsPendingUntilPushed() {
        var state = SyncState()
        state.notice(["plan#2026-10-16": "[1]"], now: t0)
        #expect(state.outgoing(["plan#2026-10-16": "[1]"]) == [.init(key: "plan#2026-10-16", updatedAt: t0, body: "[1]")])
        state.pushed(state.outgoing(["plan#2026-10-16": "[1]"]))
        #expect(state.pending.isEmpty)
        state.notice(["plan#2026-10-16": "[1]"], now: t0 + 60)
        #expect(state.pending.isEmpty)
    }

    @Test func aRemovedUnitIsPushedAsATombstone() {
        var state = SyncState(synced: ["log#2026-10-16": SyncUnits.hash("[1]")])
        state.notice([:], now: t0)
        #expect(state.outgoing([:]) == [.init(key: "log#2026-10-16", updatedAt: t0, body: nil)])
        state.pushed(state.outgoing([:]))
        #expect(state.synced.isEmpty && state.pending.isEmpty)
    }

    @Test func aChangeKeepsItsTimeUntilItChangesAgain() {
        var state = SyncState()
        state.notice(["profile": "a"], now: t0)
        state.notice(["profile": "a"], now: t0 + 10)
        #expect(state.pending["profile"]?.at == t0)
        state.notice(["profile": "b"], now: t0 + 20)
        #expect(state.pending["profile"]?.at == t0 + 20)
    }

    @Test func aChangeUndoneIsNoLongerPending() {
        var state = SyncState(synced: ["profile": SyncUnits.hash("a")])
        state.notice(["profile": "b"], now: t0)
        state.notice(["profile": "a"], now: t0 + 5)
        #expect(state.pending.isEmpty)
    }

    @Test func theNewestChangeWins() {
        var state = SyncState(synced: ["plan#2026-10-16": SyncUnits.hash("old")], pulledOnce: true)
        state.notice(["plan#2026-10-16": "phone"], now: t0)
        #expect(state.shouldApply(.init(key: "plan#2026-10-16", updatedAt: t0 + 30, body: "web")))
        #expect(!state.shouldApply(.init(key: "plan#2026-10-16", updatedAt: t0 - 30, body: "web")))
    }

    @Test func whatIsAlreadyHereIsntAppliedAgain() {
        let state = SyncState(synced: ["profile": SyncUnits.hash("a")], pulledOnce: true)
        #expect(!state.shouldApply(.init(key: "profile", updatedAt: t0, body: "a")))
        #expect(state.shouldApply(.init(key: "profile", updatedAt: t0, body: "b")))
        #expect(state.shouldApply(.init(key: "profile", updatedAt: t0, body: nil)))
    }

    @Test func onTheFirstSyncTheServerWins() {
        var state = SyncState()
        state.notice(["profile": "new phone"], now: t0 + 100)
        #expect(state.shouldApply(.init(key: "profile", updatedAt: t0, body: "account")))
    }

    @Test func aCursorIsRewoundAMinute() {
        #expect(SyncEngine.rewound("2026-10-16T12:00:30.500Z#plan#2026-10-16") == "2026-10-16T11:59:30.500Z")
        #expect(SyncEngine.rewound("junk") == "junk")
    }

    // MARK: Store

    @Test func unitsAreOnePerDayGoalAndProfile() throws {
        let context = try store()
        let plan = Plan(weekContaining: t0, now: t0)
        context.insert(plan)
        let set = PlannedActivity(kind: .workout, date: t0, slot: "Upper", templateRef: try bench(context).id,
                                  targets: [Measurement(metric: "reps", value: 5, unit: "reps")], now: t0)
        plan.items.append(set)
        context.insert(LogEntry(kind: .workout, timestamp: t0 + 600, plannedRef: set.id, templateRef: try bench(context).id,
                                measurements: [Measurement(metric: "load_lb", value: 185, unit: "lb")], now: t0))
        let goal = Goal(kind: .training, metric: "bench_1rm", target: 225, unit: "lb", now: t0)
        context.insert(goal)
        try context.save()

        let day = SyncUnits.day(t0)
        let units = try SyncUnits.all(in: context)
        #expect(Set(units.keys) == ["plan#\(day)", "log#\(day)", "goal#\(goal.id.uuidString)"])
        let rows = try SyncUnits.decode([SyncUnits.PlanRow].self, try #require(units["plan#\(day)"]))
        #expect(rows.map(\.template) == ["bench-press"])
        #expect(rows.map(\.at) == [t0])
        #expect(try SyncUnits.all(in: context) == units, "the same data is the same bytes")
    }

    @Test func applyingAUnitReadsBackTheSame() throws {
        let phone = try store(), web = try store()
        let plan = Plan(weekContaining: t0, now: t0)
        phone.insert(plan)
        for (i, reps) in [5.0, 5, 5].enumerated() {
            plan.items.append(PlannedActivity(kind: .workout, date: t0 + TimeInterval(i), slot: "Upper", templateRef: try bench(phone).id,
                                              targets: [Measurement(metric: "reps", value: reps, unit: "reps")], now: t0))
        }
        phone.insert(Goal(kind: .training, metric: "bench_1rm", target: 225, unit: "lb", now: t0))
        phone.insert(Profile(age: 42, weightLb: 190, now: t0))
        try phone.save()

        let units = try SyncUnits.all(in: phone)
        for (key, body) in units { try SyncUnits.apply(key, body: body, in: web) }
        try web.save()
        #expect(try SyncUnits.all(in: web) == units)
        #expect(try web.fetch(FetchDescriptor<PlannedActivity>()).allSatisfy { $0.plan?.weekStart == Week.start(of: t0) })
    }

    @Test func anEditedDayReplacesItsRowsAndKeepsLogPhotos() throws {
        let context = try store()
        let entry = LogEntry(kind: .workout, timestamp: t0, templateRef: try bench(context).id,
                             measurements: [Measurement(metric: "reps", value: 5, unit: "reps")], photo: Data([1, 2]), now: t0)
        context.insert(entry)
        context.insert(LogEntry(kind: .workout, timestamp: t0 + 60, now: t0))
        try context.save()

        let key = "log#\(SyncUnits.day(t0))"
        var rows = try SyncUnits.decode([SyncUnits.LogRow].self, try #require(try SyncUnits.all(in: context)[key]))
        rows = [rows[0]]
        rows[0].measurements = [Measurement(metric: "reps", value: 6, unit: "reps")]
        try SyncUnits.apply(key, body: SyncUnits.encode(rows), in: context)
        try context.save()

        let left = try context.fetch(FetchDescriptor<LogEntry>())
        #expect(left.count == 1)
        #expect(left.first?.measurements.first?.value == 6)
        #expect(left.first?.photo == Data([1, 2]))
    }

    @Test func aSessionMovedToAnotherDayKeepsItsIds() throws {
        let context = try store()
        let plan = Plan(weekContaining: t0, now: t0)
        context.insert(plan)
        let item = PlannedActivity(kind: .workout, date: t0, slot: "Upper", now: t0)
        plan.items.append(item)
        try context.save()

        let from = "plan#\(SyncUnits.day(t0))", tomorrow = t0 + 86_400
        var rows = try SyncUnits.decode([SyncUnits.PlanRow].self, try #require(try SyncUnits.all(in: context)[from]))
        rows[0].at = tomorrow
        // The two units can arrive in either order.
        try SyncUnits.apply("plan#\(SyncUnits.day(tomorrow))", body: SyncUnits.encode(rows), in: context)
        try SyncUnits.apply(from, body: nil, in: context)
        try context.save()

        let items = try context.fetch(FetchDescriptor<PlannedActivity>())
        #expect(items.map(\.id) == [item.id])
        #expect(items.map(\.date) == [tomorrow])
    }

    @Test func aDeletedGoalIsRemoved() throws {
        let context = try store()
        let goal = Goal(kind: .training, metric: "bench_1rm", target: 225, unit: "lb", now: t0)
        context.insert(goal)
        try context.save()
        try SyncUnits.apply("goal#\(goal.id.uuidString)", body: nil, in: context)
        try context.save()
        #expect(try context.fetch(FetchDescriptor<Goal>()).isEmpty)
    }
}
