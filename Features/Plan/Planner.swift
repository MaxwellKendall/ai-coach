import Foundation
import SwiftData

/// Builds a week's Plan from the profile, catalog and log history by running the domain generators,
/// and writes adjustments back. The generators decide; this only reads and writes the store.
@MainActor
enum Planner {
    /// FIT-74: the Mondays whose week the model is designing right now, for Today to say so.
    @Observable final class Designing {
        var weeks: Set<Date> = []
    }
    static let designing = Designing()

    /// FIT-74: the on-device model designs the week (ProgramDesigner), off the main thread; TrainingGenerator's week
    /// stands meanwhile, and when the model can't. Days done, pinned or past keep what they have. Once per week.
    static func design(weekOf date: Date = .now, in context: ModelContext, calendar: Calendar = .current) async {
        let monday = Week.start(of: date, calendar: calendar)
        guard LanguageModel.isAvailable, !designing.weeks.contains(monday),
              let plan = try? plan(weekOf: monday, in: context), plan.designedBy == nil,
              let profile = try? context.fetch(FetchDescriptor<Profile>()).first, profile.isComplete,
              let templates = try? context.fetch(FetchDescriptor<Template>()),
              let entries = try? context.fetch(FetchDescriptor<LogEntry>()) else { return }
        let history = loggedSets(entries, templates: templates)
        let names = Dictionary(templates.map { ($0.slug, $0.name) }, uniquingKeysWith: { first, _ in first })
        let goals = ((try? context.fetch(FetchDescriptor<Goal>())) ?? []).filter { $0.status == .active }.compactMap { goal -> String? in
            guard let option = GoalOption.all.first(where: { $0.metric == goal.metric }) else { return nil }
            return option.title(target: goal.target)
                + (goal.deadline.map { " by \($0.formatted(.dateTime.month(.abbreviated).day()))" } ?? "")
        }
        let lastMonday = calendar.date(byAdding: .day, value: -7, to: monday)!
        let program = profile.programWeek(of: monday, calendar: calendar)
        let request = ProgramDesigner.Request(
            monday: monday, settings: profile.trainingSettings, catalog: catalog(templates), names: names, history: history,
            weeksSinceDeload: Training.weeksSinceDeload(history, before: monday, calendar: calendar), program: program?.week,
            programIndex: program?.index, programWeeks: profile.program?.count, goals: goals,
            lastWeek: (try? self.plan(weekOf: lastMonday, in: context)).flatMap { $0 }.map { workouts($0, templates: templates) } ?? [],
            calendar: calendar)
        designing.weeks.insert(monday)
        defer { designing.weeks.remove(monday) }
        let result = await ProgramDesigner.week(request)
        // The week may have been planned again while the model worked; that plan gets its own turn.
        guard let current = try? self.plan(weekOf: monday, in: context), current.id == plan.id, plan.designedBy == nil else { return }
        if result.source == .model {
            let done = Set(entries.filter { $0.kind == .workout }.map { calendar.startOfDay(for: $0.timestamp) })
            let pinned = Set(plan.items.filter { $0.kind == .workout && $0.pinned }.map { calendar.startOfDay(for: $0.date) })
            _ = try? replan(plan, with: result.week.workouts, keep: done.union(pinned), templates: templates, in: context,
                            calendar: calendar)
            plan.warnings = result.week.warnings
        }
        plan.designedBy = result.source.rawValue
        try? context.save()
    }

    /// FIT-82: weeks began on Monday until they moved to Sunday. Each plan keyed by a Monday is keyed by the Sunday
    /// before it, and an item that now falls in another week (a Sunday, the old week's last day) moves to that week's
    /// plan; a plan made for it is planned again when its week starts. Does nothing once every plan starts on a Sunday.
    static func rekeyWeeks(in context: ModelContext, calendar: Calendar = .current) throws {
        // A program from Monday to a Sunday keeps its length: Sunday to Saturday.
        for profile in try context.fetch(FetchDescriptor<Profile>()) {
            guard let start = profile.programStart, Week.day(of: start, calendar: calendar) == 0 else { continue }
            profile.programStart = calendar.date(byAdding: .day, value: -1, to: start)
            if let target = profile.targetDate, Week.day(of: target, calendar: calendar) == 6 {
                profile.targetDate = calendar.date(byAdding: .day, value: -1, to: target)
            }
        }
        let plans = try context.fetch(FetchDescriptor<Plan>())
        guard plans.contains(where: { $0.weekStart != Week.start(of: $0.weekStart, calendar: calendar) }) else {
            try context.save()
            return
        }
        var byStart: [Date: Plan] = [:]
        for plan in plans.sorted(by: { $0.weekStart < $1.weekStart }) {
            let start = Week.start(of: plan.weekStart, calendar: calendar)
            if let kept = byStart[start] {
                let items = plan.items
                plan.items = []
                kept.items += items
                context.delete(plan)
            } else {
                plan.weekStart = start
                byStart[start] = plan
            }
        }
        for plan in Array(byStart.values) {
            let leaving = plan.items.filter { Week.start(of: $0.date, calendar: calendar) != plan.weekStart }
            guard !leaving.isEmpty else { continue }
            plan.items.removeAll { item in leaving.contains { $0.id == item.id } }
            for item in leaving {
                let start = Week.start(of: item.date, calendar: calendar)
                let target = byStart[start] ?? {
                    let new = Plan(weekContaining: start, calendar: calendar, now: .distantPast)
                    context.insert(new)
                    byStart[start] = new
                    return new
                }()
                target.items.append(item)
            }
        }
        try context.save()
    }

    static func plan(weekOf date: Date, in context: ModelContext, calendar: Calendar = .current) throws -> Plan? {
        let monday = Week.start(of: date, calendar: calendar)
        return try context.fetch(FetchDescriptor<Plan>(predicate: #Predicate { $0.weekStart == monday })).first
    }

    /// Generates the current week once a profile is complete and nothing is planned yet.
    /// A week saved before it began (a session edited from next week's card, FIT-45) is planned again once, now that
    /// the week before is done; its pinned days stay.
    static func ensureWeek(of date: Date = .now, in context: ModelContext, calendar: Calendar = .current) throws {
        guard let plan = try plan(weekOf: date, in: context) else {
            try generate(weekOf: date, in: context, calendar: calendar)
            return
        }
        guard plan.updatedAt < plan.weekStart else { return }
        let pinned = Dictionary(grouping: plan.items.filter { $0.kind == .workout }) { calendar.startOfDay(for: $0.date) }
            .filter { $0.value.allSatisfy(\.pinned) }.keys
        try replan(plan, with: preview(weekOf: date, in: context, calendar: calendar), keep: Set(pinned), today: date,
                   templates: try context.fetch(FetchDescriptor<Template>()), in: context, calendar: calendar)
    }

    /// Idempotent: replaces whatever was planned for that week.
    @discardableResult
    static func generate(weekOf date: Date, in context: ModelContext, calendar: Calendar = .current) throws -> Plan? {
        guard let profile = try context.fetch(FetchDescriptor<Profile>()).first, profile.isComplete else { return nil }
        let monday = Week.start(of: date, calendar: calendar)
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
        let monday = Week.start(of: date, calendar: calendar)
        let templates = try context.fetch(FetchDescriptor<Template>())
        let history = loggedSets(try context.fetch(FetchDescriptor<LogEntry>()), templates: templates)
        return TrainingGenerator.week(
            startingOn: monday, settings: profile.trainingSettings, catalog: catalog(templates), history: history,
            weeksSinceDeload: Training.weeksSinceDeload(history, before: monday, calendar: calendar),
            program: profile.programWeek(of: monday, calendar: calendar)?.week, calendar: calendar).workouts
    }

    /// Exercises in a session share a start time; `order` seconds keep them in the generator's order.
    static func activity(_ workout: PlannedWorkout, order: Int, ids: [String: UUID]) -> PlannedActivity {
        PlannedActivity(kind: .workout, date: workout.date + TimeInterval(order), slot: workout.session,
                        templateRef: ids[workout.exercise],
                        targets: workout.targets, note: workout.note ?? "", adjustedReason: workout.adjustedReason,
                        group: workout.group, main: workout.main)
    }

    /// The plan's workouts as the adjust rules see them. Timestamps drop the ordering seconds.
    static func workouts(_ plan: Plan, templates: [Template]) -> [PlannedWorkout] {
        let slugs = Dictionary(templates.map { ($0.id, $0.slug) }, uniquingKeysWith: { first, _ in first })
        return plan.items.filter { $0.kind == .workout }.sorted { $0.date < $1.date }.map {
            PlannedWorkout(date: Date(timeIntervalSinceReferenceDate: ($0.date.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60),
                           session: $0.slot ?? "", exercise: $0.templateRef.flatMap { slugs[$0] } ?? "",
                           targets: $0.targets, note: $0.note.isEmpty ? nil : $0.note, adjustedReason: $0.adjustedReason,
                           group: $0.group, main: $0.main)
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
        let old = plan.items.filter { $0.kind == .workout }
        let ids = Dictionary(templates.map { ($0.slug, $0.id) }, uniquingKeysWith: { first, _ in first })
        // Set the array without the old rows before deleting them, so appending can't write a deleted row back.
        plan.items = plan.items.filter { $0.kind != .workout } + workouts.enumerated().map { activity($0.element, order: $0.offset, ids: ids) }
        for item in old { context.delete(item) }
        plan.updatedAt = .now
        try context.save()
    }

    /// FIT-40: one day's rows replaced by other workouts; returns the new rows (for Undo).
    @discardableResult
    static func replace(_ items: [PlannedActivity], with workouts: [PlannedWorkout], templates: [Template],
                        in context: ModelContext) throws -> [PlannedActivity] {
        guard let plan = items.first?.plan else { return [] }
        let gone = Set(items.map(\.id))
        let ids = Dictionary(templates.map { ($0.slug, $0.id) }, uniquingKeysWith: { first, _ in first })
        let new = workouts.enumerated().map { activity($0.element, order: $0.offset, ids: ids) }
        // As in `apply`: the array first, so a deleted row can't be written back.
        plan.items = plan.items.filter { !gone.contains($0.id) } + new
        for item in items { context.delete(item) }
        plan.updatedAt = .now
        try context.save()
        return new
    }

    /// FIT-44: the program changed, so the rest of the week is planned again. Days in `keep` (done, past or
    /// pinned) and days before `today` stay as they are. Returns what the replaced days had, for Undo.
    @discardableResult
    static func replan(_ plan: Plan, with workouts: [PlannedWorkout], keep: Set<Date>, today: Date = .now,
                       templates: [Template], in context: ModelContext, calendar: Calendar = .current) throws -> [PlannedWorkout] {
        let start = calendar.startOfDay(for: today)
        func open(_ date: Date) -> Bool { date >= start && !keep.contains(calendar.startOfDay(for: date)) }
        let old = plan.items.filter { $0.kind == .workout && open($0.date) }
        let removed = Self.workouts(plan, templates: templates).filter { open($0.date) }
        let ids = Dictionary(templates.map { ($0.slug, $0.id) }, uniquingKeysWith: { first, _ in first })
        let gone = Set(old.map(\.id))
        // As in `apply`: the array first, so a deleted row can't be written back.
        plan.items = plan.items.filter { !gone.contains($0.id) }
            + workouts.filter { open($0.date) }.enumerated().map { activity($0.element, order: $0.offset, ids: ids) }
        for item in old { context.delete(item) }
        plan.updatedAt = .now
        try context.save()
        return removed
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
