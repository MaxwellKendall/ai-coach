import Foundation
import Synchronization
import SwiftData
import Testing
@testable import AICoach

/// FIT-426: Lifter Pro's next week designed again on request: what's kept, the cap, a coach's week, a fallback and
/// what it all cost.
@MainActor
struct RedesignTests {
    /// The context doesn't retain its container, so the test keeps it.
    private let container = try! AppSchema.container(inMemory: true)
    private let next = Calendar.current.date(byAdding: .day, value: 7, to: .now)!

    /// A complete profile and next week saved as the code plans it.
    private func store() throws -> (ModelContext, Plan) {
        let context = container.mainContext
        try Seeder.seed(context)
        context.insert(Profile(age: 36, weightLb: 200))
        try context.save()
        let plan = try #require(try Planner.generate(weekOf: next, in: context))
        return (context, plan)
    }

    private func workouts(_ plan: Plan) -> [PlannedActivity] { plan.items.filter { $0.kind == .workout } }

    /// Answers every request with text and no answer, using `tokens` in and out each time.
    final class Silent: ClaudeTransport {
        let tokens: (input: Double, output: Double)
        init(_ tokens: (input: Double, output: Double)) { self.tokens = tokens }
        var isAvailable: Bool { true }
        func send(_ body: JSON) async throws -> (status: Int, body: JSON) {
            (200, .object(["content": .array([.object(["type": .string("text"), "text": .string("Hmm.")])]),
                           "stop_reason": .string("end_turn"),
                           "usage": .object(["input_tokens": .number(tokens.input), "output_tokens": .number(tokens.output)])]))
        }
    }

    @Test func aRedesignReplacesOnlyDaysNotDoneAndNotPinned() async throws {
        let (context, plan) = try store()
        #expect(await Planner.design(weekOf: next, in: context, model: StubDesigner.week(of: next, in: context)))
        #expect(plan.designedBy == "model" && plan.designs == 1)
        let days = Set(workouts(plan).map { Calendar.current.startOfDay(for: $0.date) }).sorted()
        #expect(days.count >= 3)
        // The first day pinned, the second done.
        for item in workouts(plan) where Calendar.current.isDate(item.date, inSameDayAs: days[0]) { item.pinned = true }
        context.insert(LogEntry(kind: .workout, timestamp: days[1].addingTimeInterval(18 * 3600)))
        try context.save()
        let kept = Set(workouts(plan).filter { [days[0], days[1]].contains(Calendar.current.startOfDay(for: $0.date)) }.map(\.id))
        let open = Set(workouts(plan).map(\.id)).subtracting(kept)

        #expect(await Planner.design(weekOf: next, in: context, model: StubDesigner.week(of: next, in: context), force: true))
        let ids = Set(workouts(plan).map(\.id))
        #expect(kept.isSubset(of: ids))
        #expect(open.isDisjoint(with: ids))
        #expect(plan.designs == 2)
        // The stub's reason lands on a main lift.
        #expect(workouts(plan).contains { [StubDesigner.changes.squat, StubDesigner.changes.bench].contains($0.adjustedReason) })
    }

    @Test func aWeekIsDesignedAtMostThreeTimes() async throws {
        let (context, plan) = try store()
        let stub = StubDesigner.week(of: next, in: context)
        #expect(await Planner.design(weekOf: next, in: context, model: stub))
        // Without force, a designed week isn't designed again.
        #expect(!(await Planner.design(weekOf: next, in: context, model: stub)))
        for _ in 0..<Planner.redesignsPerWeek {
            #expect(await Planner.design(weekOf: next, in: context, model: stub, force: true))
        }
        #expect(plan.designs == 1 + Planner.redesignsPerWeek)
        #expect(!Planner.canRedesign(plan))
        let calls = stub.calls.count.withLock { $0 }
        #expect(!(await Planner.design(weekOf: next, in: context, model: stub, force: true)))
        #expect(stub.calls.count.withLock { $0 } == calls)
        #expect(plan.designs == 3)
    }

    @Test func aCoachsWeekIsNeverDesigned() async throws {
        let (context, plan) = try store()
        workouts(plan).first?.adjustedReason = "From Sam"
        try context.save()
        let stub = StubDesigner.week(of: next, in: context)
        #expect(!(await Planner.design(weekOf: next, in: context, model: stub)))
        #expect(!(await Planner.design(weekOf: next, in: context, model: stub, force: true)))
        #expect(stub.calls.count.withLock { $0 } == 0)
        #expect(!Planner.canRedesign(plan) && plan.designs == 0)
    }

    @Test func aRedesignThatFallsBackKeepsTheWeekAndCountsItsTokens() async throws {
        let (context, plan) = try store()
        #expect(await Planner.design(weekOf: next, in: context, model: StubDesigner.week(of: next, in: context)))
        let before = Set(workouts(plan).map(\.id))
        let claude = ClaudeModel(model: LanguageModel.cloud, transport: Silent((1000, 100)))
        #expect(!(await Planner.design(weekOf: next, in: context, model: claude, force: true)))
        #expect(Set(workouts(plan).map(\.id)) == before)
        #expect(plan.designedBy == "model" && plan.designs == 1)
        let used = claude.usage.snapshot
        #expect(used.requests > 0 && plan.designTokens == used.input + used.output)
        let cost = try #require(ClaudeModel.cost(model: LanguageModel.cloud, input: used.input, output: used.output))
        #expect(cost > 0 && abs(plan.designCostUSD - cost) < 1e-12)
    }

    @Test func haikusPriceGivesADesignsCost() throws {
        let cost = try #require(ClaudeModel.cost(model: "claude-haiku-5-5", input: 10_000, output: 2_000))
        // $0.10 and $0.50 per million tokens.
        #expect(abs(cost - 0.002) < 1e-12)
        #expect(ClaudeModel.cost(model: "claude-opus-5-5", input: 1, output: 1) == nil)
    }

    @Test func aWeekNotSavedYetCanBeDesigned() {
        #expect(Planner.canRedesign(nil))
    }
}
