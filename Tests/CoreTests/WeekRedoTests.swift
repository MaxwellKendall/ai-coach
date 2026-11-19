import Foundation
import FoundationModels
import SwiftData
import Testing
@testable import AICoach

/// TKL-846: the AI planning a week again on request, on this week's and next week's cards: what each card offers, its
/// words, and that a redesign of this week without a program keeps the days already logged.
@MainActor
struct WeekRedoTests {
    private let container = try! AppSchema.container(inMemory: true)

    private func plan(designs: Int, coached: Bool = false) -> Plan {
        let plan = Plan(weekContaining: .now)
        plan.designs = designs
        if coached {
            let item = PlannedActivity(kind: .workout, date: .now, adjustedReason: "From Sam")
            plan.items = [item]
        }
        return plan
    }

    @Test func aProLiftersWeekIsPlannedThenRedoneTwiceThenCapped() {
        #expect(WeekRedo.state(plan: nil, lifterPro: true, offered: true) == .plan)
        #expect(WeekRedo.state(plan: plan(designs: 0), lifterPro: true, offered: true) == .plan)
        #expect(WeekRedo.state(plan: plan(designs: 1), lifterPro: true, offered: true) == .redo(left: 2))
        #expect(WeekRedo.state(plan: plan(designs: 2), lifterPro: true, offered: true) == .redo(left: 1))
        #expect(WeekRedo.state(plan: plan(designs: 3), lifterPro: true, offered: true) == .capped)
        #expect(WeekRedo.state(plan: plan(designs: 1), lifterPro: true, offered: true, designing: true) == .designing)
    }

    @Test func aFreeLifterIsSoldLifterProAndACoachsWeekOffersNothing() {
        #expect(WeekRedo.state(plan: plan(designs: 0), lifterPro: false, offered: true) == .upsell(designed: false))
        #expect(WeekRedo.state(plan: plan(designs: 3), lifterPro: false, offered: true) == .upsell(designed: true))
        #expect(WeekRedo.state(plan: plan(designs: 1), lifterPro: true, offered: false) == .hidden)
        #expect(WeekRedo.state(plan: plan(designs: 0, coached: true), lifterPro: true, offered: true) == .hidden)
        #expect(WeekRedo.state(plan: plan(designs: 0, coached: true), lifterPro: false, offered: true) == .hidden)
    }

    @Test func theCardsWords() {
        #expect(WeekRedo.button(.plan, next: false) == "Plan this week with AI")
        #expect(WeekRedo.button(.plan, next: true) == "Plan next week with AI")
        #expect(WeekRedo.caption(.plan, next: false) == "Then 2 redos this week if you want changes")
        #expect(WeekRedo.caption(.plan, next: true) == "Then 2 redos for next week if you want changes")
        #expect(WeekRedo.button(.redo(left: 2), next: false) == "Redo this week with AI")
        #expect(WeekRedo.button(.redo(left: 2), next: true) == "Redo next week with AI")
        #expect(WeekRedo.caption(.redo(left: 2), next: false) == "2 redos left this week · logged days stay")
        #expect(WeekRedo.caption(.redo(left: 1), next: false) == "1 redo left this week · logged days stay")
        #expect(WeekRedo.caption(.redo(left: 1), next: true) == "1 redo left for next week · logged days stay")
        #expect(WeekRedo.button(.capped, next: false) == nil)
        #expect(WeekRedo.caption(.capped, next: false)
                == "No redos left this week. 3 AI designs a week is the most; this one stays as planned.")
        #expect(WeekRedo.button(.upsell(designed: false), next: false) == "Plan this week with AI")
        #expect(WeekRedo.button(.upsell(designed: true), next: true) == "Redo next week with AI")
        #expect(WeekRedo.caption(.upsell(designed: false), next: false) == "Lifter Pro")
        #expect(WeekRedo.button(.designing, next: false) == nil)
        #expect(WeekRedo.caption(.designing, next: false) == "Redesigning this week… days you’ve logged stay as they are.")
        #expect(WeekRedo.caption(.designing, next: true) == "Redesigning next week… days you’ve logged stay as they are.")
        #expect(WeekRedo.failed == "Couldn’t redo the week. It’s as it was.")
    }

    /// A lifter with no program: this week planned by code, designed, a day logged, then redone. The logged day keeps
    /// its sessions; the rest are the redesign's.
    @Test func redoingThisWeekWithoutAProgramKeepsTheLoggedDays() async throws {
        let context = container.mainContext
        try Seeder.seed(context)
        // Every day a training day, so today has a session whatever day it is.
        let profile = Profile(age: 36, weightLb: 200, trainingDays: Array(0...6))
        context.insert(profile)
        try context.save()
        #expect(profile.program == nil)
        let plan = try #require(try Planner.generate(weekOf: .now, in: context))
        #expect(await Planner.design(weekOf: .now, in: context, model: StubDesigner.week(of: .now, in: context), force: true))
        #expect(plan.designs == 1)
        let workouts = { plan.items.filter { $0.kind == .workout } }
        // Today logged; days before it stay as they were anyway, days after it are the redesign's.
        let today = Calendar.current.startOfDay(for: .now)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        context.insert(LogEntry(kind: .workout, timestamp: .now))
        try context.save()
        let logged = Set(workouts().filter { Calendar.current.isDate($0.date, inSameDayAs: today) }.map(\.id))
        #expect(!logged.isEmpty)
        let open = Set(workouts().filter { $0.date >= tomorrow }.map(\.id))

        #expect(await Planner.design(weekOf: .now, in: context, model: StubDesigner.week(of: .now, in: context), force: true))
        let ids = Set(workouts().map(\.id))
        #expect(logged.isSubset(of: ids))
        #expect(open.isDisjoint(with: ids))
        #expect(plan.designs == 2)
        #expect(WeekRedo.state(plan: plan, lifterPro: true, offered: true) == .redo(left: 1))
    }

    /// The model can't answer: the week stays, and no redo is used.
    @Test func aRedoTheModelCantDoLeavesTheWeekAndTheCount() async throws {
        let context = container.mainContext
        try Seeder.seed(context)
        context.insert(Profile(age: 36, weightLb: 200))
        try context.save()
        let plan = try #require(try Planner.generate(weekOf: .now, in: context))
        #expect(await Planner.design(weekOf: .now, in: context, model: StubDesigner.week(of: .now, in: context), force: true))
        let before = Set(plan.items.map(\.id))
        #expect(!(await Planner.design(weekOf: .now, in: context, model: Unavailable(), force: true)))
        #expect(Set(plan.items.map(\.id)) == before)
        #expect(plan.designs == 1)
    }

    struct Unavailable: AIModel {
        var name: String { "none" }
        var isAvailable: Bool { false }
        func session(tools: [any Tool], instructions: String) -> any AISession { fatalError("never asked") }
    }
}
