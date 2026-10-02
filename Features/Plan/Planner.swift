import Foundation
import SwiftData

/// Builds a week's Plan from the profile, catalog and log history by running the domain generators,
/// and writes adjustments back. The generators decide; this only reads and writes the store.
@MainActor
enum Planner {
    static func plan(weekOf date: Date, in context: ModelContext, calendar: Calendar = .current) throws -> Plan? {
        let monday = Week.monday(of: date, calendar: calendar)
        return try context.fetch(FetchDescriptor<Plan>(predicate: #Predicate { $0.weekStart == monday })).first
    }

    /// Generates the current week once a profile is complete and nothing is planned yet.
    static func ensureWeek(of date: Date = .now, in context: ModelContext) throws {
        guard try plan(weekOf: date, in: context) == nil else { return }
        try generate(weekOf: date, in: context)
    }

    /// Idempotent: replaces whatever was planned for that week.
    @discardableResult
    static func generate(weekOf date: Date, in context: ModelContext, calendar: Calendar = .current) throws -> Plan? {
        guard let profile = try context.fetch(FetchDescriptor<Profile>()).first, profile.isComplete else { return nil }
        let monday = Week.monday(of: date, calendar: calendar)
        let templates = try context.fetch(FetchDescriptor<Template>())
        let history = loggedSets(try context.fetch(FetchDescriptor<LogEntry>()), templates: templates)
        let week = TrainingGenerator.week(
            startingOn: monday, settings: profile.trainingSettings, catalog: catalog(templates), history: history,
            weeksSinceDeload: Training.weeksSinceDeload(history, before: monday, calendar: calendar), calendar: calendar)
        let kitchen = KitchenSchedule.week(startingOn: monday, cookWindows: profile.cookWindows,
                                           groceryDay: profile.groceryDay, calendar: calendar)

        if let existing = try plan(weekOf: monday, in: context) { context.delete(existing) }
        let plan = Plan(weekContaining: monday, calendar: calendar)
        plan.warnings = week.warnings
        context.insert(plan)
        let ids = Dictionary(templates.map { ($0.slug, $0.id) }, uniquingKeysWith: { first, _ in first })
        plan.items = week.workouts.enumerated().map { activity($0.element, order: $0.offset, ids: ids) } + kitchen.map {
            PlannedActivity(kind: $0.kind, date: $0.date, slot: $0.label,
                            targets: [Measurement(metric: "duration_h", value: $0.hours, unit: "h")])
        }
        try context.save()
        return plan
    }

    /// Exercises in a session share a start time; `order` seconds keep them in the generator's order.
    static func activity(_ workout: PlannedWorkout, order: Int, ids: [String: UUID]) -> PlannedActivity {
        PlannedActivity(kind: .workout, date: workout.date + TimeInterval(order), slot: workout.session,
                        templateRef: ids[workout.exercise],
                        targets: workout.targets, note: workout.note ?? "", adjustedReason: workout.adjustedReason)
    }

    /// The plan's workouts as the adjust rules see them. Timestamps drop the ordering seconds.
    static func workouts(_ plan: Plan, templates: [Template]) -> [PlannedWorkout] {
        let slugs = Dictionary(templates.map { ($0.id, $0.slug) }, uniquingKeysWith: { first, _ in first })
        return plan.items.filter { $0.kind == .workout }.sorted { $0.date < $1.date }.map {
            PlannedWorkout(date: Date(timeIntervalSinceReferenceDate: ($0.date.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60),
                           session: $0.slot ?? "", exercise: $0.templateRef.flatMap { slugs[$0] } ?? "",
                           targets: $0.targets, note: $0.note.isEmpty ? nil : $0.note, adjustedReason: $0.adjustedReason)
        }
    }

    /// Re-plan with a constraint: only workouts from `today` on change, and kitchen items stay.
    static func adjust(_ plan: Plan, templates: [Template], today: Date = .now, calendar: Calendar = .current,
                       _ rule: (TrainingWeek) -> TrainingWeek?) -> (past: [PlannedWorkout], before: [PlannedWorkout], after: [PlannedWorkout])? {
        let start = calendar.startOfDay(for: today)
        let all = workouts(plan, templates: templates)
        let past = all.filter { $0.date < start }, remaining = all.filter { $0.date >= start }
        guard let adjusted = rule(TrainingWeek(workouts: remaining, deload: false, warnings: [])) else { return nil }
        return (past, remaining, adjusted.workouts)
    }

    static func apply(_ workouts: [PlannedWorkout], to plan: Plan, templates: [Template], in context: ModelContext) throws {
        for item in plan.items where item.kind == .workout { context.delete(item) }
        let ids = Dictionary(templates.map { ($0.slug, $0.id) }, uniquingKeysWith: { first, _ in first })
        plan.items.append(contentsOf: workouts.enumerated().map { activity($0.element, order: $0.offset, ids: ids) })
        plan.updatedAt = .now
        try context.save()
    }

    static func catalog(_ templates: [Template]) -> [Exercise] {
        templates.filter { $0.kind == .exercise }.compactMap { Exercise(slug: $0.slug, attributes: $0.attributes) }
    }

    /// Workout log entries as the pure training rules see them.
    static func loggedSets(_ entries: [LogEntry], templates: [Template]) -> [LoggedSet] {
        let byID = Dictionary(templates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return entries.filter { $0.kind == .workout }.compactMap { entry in
            guard let template = entry.templateRef.flatMap({ byID[$0] }) else { return nil }
            return LoggedSet(date: entry.timestamp, exercise: template.slug,
                             pattern: template.values("movement_pattern").first, measurements: entry.measurements)
        }
        .sorted { $0.date < $1.date }
    }
}
