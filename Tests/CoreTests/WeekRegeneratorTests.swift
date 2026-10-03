import Foundation
import Testing
import SwiftData
@testable import AICoach

private func exercise(_ slug: String, _ pattern: String, _ equipment: [String] = []) -> Exercise {
    Exercise(slug: slug, attributes: [
        TemplateAttribute(key: "movement_pattern", values: [pattern]),
        TemplateAttribute(key: "equipment", values: equipment),
    ])!
}

private let catalog = [exercise("back-squat", "squat", ["barbell"]), exercise("goblet-squat", "squat", ["dumbbells"]),
                       exercise("front-squat", "squat", ["barbell"]), exercise("pull-up", "pull", ["pull_up_bar"]),
                       exercise("plank", "core")]
private let settings = TrainingSettings(
    age: 36, daysPerWeek: 3, sessionMinutes: 45, trainingDays: [0, 2, 4], workoutTime: 420,
    equipment: ["barbell", "dumbbells", "pull_up_bar"], maxWeeklySets: 60,
    starts: [StartingSet(exercise: "goblet-squat", measurements: [Measurement(metric: "load_lb", value: 50, unit: "lb"),
                                                                  Measurement(metric: "reps", value: 10, unit: "reps")])])

private func workout(_ exercise: String, _ targets: [(String, Double)], note: String? = nil) -> PlannedWorkout {
    PlannedWorkout(date: .distantPast, session: "Session A", exercise: exercise,
                   targets: targets.map { Measurement(metric: $0.0, value: $0.1, unit: "") }, note: note)
}

private let session = [
    workout("back-squat", [("sets", 1), ("reps", 5), ("load_lb", 90)], note: TrainingGenerator.warmupNote),
    workout("back-squat", [("sets", 3), ("reps", 5), ("load_lb", 150), ("rpe", 8)]),
    workout("pull-up", [("sets", 3), ("reps", 5)]),
]

struct WeekRegeneratorTests {
    @Test func swapsTheFirstLiftForAnotherOfItsPattern() throws {
        let first = try #require(WeekRegenerator.alternative(session, variant: 0, catalog: catalog, settings: settings, history: []))
        #expect(first.from.exercise == "back-squat")
        #expect(first.to.exercise == "goblet-squat")
        // From the starting point: 50 × 10 → Brzycki 66.7, 5 reps → 60 × 0.9 → 55.
        #expect(first.to.target("load_lb") == 55)
        #expect(first.to.target("sets") == 3)
        #expect(first.workouts.map(\.exercise) == ["goblet-squat", "pull-up"])
        // The next even variant takes the next one, with its last load from history.
        let history = [LoggedSet(date: .now, exercise: "front-squat", pattern: "squat",
                                 measurements: [Measurement(metric: "load_lb", value: 115, unit: "lb")])]
        let second = try #require(WeekRegenerator.alternative(session, variant: 2, catalog: catalog, settings: settings, history: history))
        #expect(second.to.exercise == "front-squat")
        #expect(second.to.target("load_lb") == 115)
    }

    @Test func stepsUpWhenOddOrNothingElseFits() throws {
        let odd = try #require(WeekRegenerator.alternative(session, variant: 1, catalog: catalog, settings: settings, history: []))
        #expect(odd.to.exercise == "back-squat")
        #expect(odd.to.target("load_lb") == 155)
        #expect(odd.workouts.count == 3)
        // Pull-ups have no other pull exercise here and no load: one more rep.
        let pull = try #require(WeekRegenerator.alternative([session[2]], variant: 0, catalog: catalog, settings: settings, history: []))
        #expect(pull.to.target("reps") == 6)
        let plank = try #require(WeekRegenerator.alternative([workout("plank", [("sets", 3), ("duration_s", 45)])], variant: 0,
                                                             catalog: catalog, settings: settings, history: []))
        #expect(plank.to.target("duration_s") == 50)
        #expect(WeekRegenerator.alternative([], variant: 0, catalog: catalog, settings: settings, history: []) == nil)
    }
}

@MainActor
struct RegenerateStoreTests {
    @Test func replacingADayLeavesOnlyTheNewRows() throws {
        let context = ModelContext(try AppSchema.container(inMemory: true))
        let squat = Template(kind: .exercise, name: "Back Squat", slug: "back-squat", attributes: [])
        let goblet = Template(kind: .exercise, name: "Goblet Squat", slug: "goblet-squat", attributes: [])
        context.insert(squat)
        context.insert(goblet)
        let plan = Plan(weekContaining: .now)
        context.insert(plan)
        let monday = PlannedActivity(kind: .workout, date: plan.weekStart, templateRef: squat.id)
        let wednesday = PlannedActivity(kind: .workout, date: plan.weekStart + 2 * 86_400, templateRef: squat.id)
        plan.items = [monday, wednesday]
        try context.save()

        let new = try Planner.replace([monday], with: [workout("goblet-squat", [("sets", 3)])], templates: [squat, goblet], in: context)
        #expect(plan.items.count == 2)
        #expect(try context.fetchCount(FetchDescriptor<PlannedActivity>()) == 2)
        #expect(new.first?.templateRef == goblet.id)
        // Undo: the old rows back, nothing doubled.
        try Planner.replace(new, with: [workout("back-squat", [("sets", 3)])], templates: [squat, goblet], in: context)
        #expect(try context.fetchCount(FetchDescriptor<PlannedActivity>()) == 2)
        #expect(try context.fetch(FetchDescriptor<PlannedActivity>()).allSatisfy { $0.templateRef == squat.id })
    }
}

@MainActor
struct ApplyStoreTests {
    @Test func applyingAnAdjustedWeekLeavesOnlyTheNewWorkouts() throws {
        let context = ModelContext(try AppSchema.container(inMemory: true))
        let squat = Template(kind: .exercise, name: "Back Squat", slug: "back-squat", attributes: [])
        context.insert(squat)
        let plan = Plan(weekContaining: .now)
        context.insert(plan)
        plan.items = [PlannedActivity(kind: .workout, date: plan.weekStart, templateRef: squat.id),
                      PlannedActivity(kind: .cook, date: plan.weekStart)]
        try context.save()
        try Planner.apply([workout("back-squat", [("sets", 2)])], to: plan, templates: [squat], in: context)
        #expect(try context.fetchCount(FetchDescriptor<PlannedActivity>()) == 2)
        #expect(plan.items.filter { $0.kind == .workout }.map { $0.targets.first?.value } == [2])
    }
}
