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
            weeksSinceDeload: Training.weeksSinceDeload(history, before: monday, calendar: calendar),
            program: profile.programWeek(of: monday, calendar: calendar)?.week, calendar: calendar)
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

    /// A week's sessions as they'd be planned now, from the history so far (FIT-39). Next week is shown this way and
    /// never saved: it's planned for real when it starts, from how this week went.
    static func preview(weekOf date: Date, in context: ModelContext, calendar: Calendar = .current) throws -> [PlannedWorkout] {
        guard let profile = try context.fetch(FetchDescriptor<Profile>()).first, profile.isComplete else { return [] }
        let monday = Week.monday(of: date, calendar: calendar)
        let templates = try context.fetch(FetchDescriptor<Template>())
        let history = loggedSets(try context.fetch(FetchDescriptor<LogEntry>()), templates: templates)
        return TrainingGenerator.week(
            startingOn: monday, settings: profile.trainingSettings, catalog: catalog(templates), history: history,
            weeksSinceDeload: Training.weeksSinceDeload(history, before: monday, calendar: calendar),
            program: profile.programWeek(of: monday, calendar: calendar)?.week, calendar: calendar).workouts
    }

    /// FIT-33: a session for a day with nothing planned, with an exercise asked for (TrainingGenerator.session).
    static func extraSession(on date: Date, wanting wanted: Set<String>, in context: ModelContext,
                             calendar: Calendar = .current) throws -> [PlannedWorkout]? {
        guard let profile = try context.fetch(FetchDescriptor<Profile>()).first, profile.isComplete else { return nil }
        let templates = try context.fetch(FetchDescriptor<Template>())
        let history = loggedSets(try context.fetch(FetchDescriptor<LogEntry>()), templates: templates)
        let monday = Week.monday(of: date, calendar: calendar)
        return TrainingGenerator.session(on: date, wanting: wanted, settings: profile.trainingSettings, catalog: catalog(templates),
                                         history: history, weeksSinceDeload: Training.weeksSinceDeload(history, before: monday, calendar: calendar),
                                         calendar: calendar)
    }

    /// Exercises in a session share a start time; `order` seconds keep them in the generator's order.
    static func activity(_ workout: PlannedWorkout, order: Int, ids: [String: UUID]) -> PlannedActivity {
        PlannedActivity(kind: .workout, date: workout.date + TimeInterval(order), slot: workout.session,
                        templateRef: ids[workout.exercise],
                        targets: workout.targets, note: workout.note ?? "", adjustedReason: workout.adjustedReason,
                        group: workout.group)
    }

    /// The plan's workouts as the adjust rules see them. Timestamps drop the ordering seconds.
    static func workouts(_ plan: Plan, templates: [Template]) -> [PlannedWorkout] {
        let slugs = Dictionary(templates.map { ($0.id, $0.slug) }, uniquingKeysWith: { first, _ in first })
        return plan.items.filter { $0.kind == .workout }.sorted { $0.date < $1.date }.map {
            PlannedWorkout(date: Date(timeIntervalSinceReferenceDate: ($0.date.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60),
                           session: $0.slot ?? "", exercise: $0.templateRef.flatMap { slugs[$0] } ?? "",
                           targets: $0.targets, note: $0.note.isEmpty ? nil : $0.note, adjustedReason: $0.adjustedReason,
                           group: $0.group)
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

    /// A day's workout rows as blocks.
    static func session(_ items: [PlannedActivity], templates: [Template]) -> SessionPlan {
        let slugs = Dictionary(templates.map { ($0.id, $0.slug) }, uniquingKeysWith: { first, _ in first })
        return SessionPlan(items.sorted { $0.date < $1.date }.map {
            SessionPlan.Item(id: $0.id, exercise: $0.templateRef.flatMap { slugs[$0] } ?? "", targets: $0.targets,
                             note: $0.note, adjustedReason: $0.adjustedReason, group: $0.group)
        })
    }

    /// Writes an edited session back over its rows. Rows keep their ids where they can; split-off and new
    /// rows are inserted, and rows no longer used are deleted. Second offsets keep the order.
    @discardableResult
    static func save(_ session: SessionPlan, over items: [PlannedActivity], templates: [Template],
                     in context: ModelContext) -> [PlannedActivity] {
        guard let first = items.min(by: { $0.date < $1.date }) else { return [] }
        let ids = Dictionary(templates.map { ($0.slug, $0.id) }, uniquingKeysWith: { first, _ in first })
        let start = Date(timeIntervalSinceReferenceDate: (first.date.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
        var unused = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var written: [PlannedActivity] = []
        for (order, row) in session.items.enumerated() {
            let item = row.id.flatMap { unused.removeValue(forKey: $0) } ?? {
                let item = PlannedActivity(kind: .workout, date: start, slot: first.slot)
                item.plan = first.plan
                context.insert(item)
                return item
            }()
            item.date = start + TimeInterval(order)
            item.templateRef = ids[row.exercise]
            item.targets = row.targets
            item.note = row.note
            item.adjustedReason = row.adjustedReason
            item.group = row.group
            item.updatedAt = .now
            written.append(item)
        }
        for item in unused.values { context.delete(item) }
        return written
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
