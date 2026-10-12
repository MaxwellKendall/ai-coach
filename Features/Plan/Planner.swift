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
    /// What the designer is told about a week: the profile, catalog, history, goals, program week and last week's plan.
    static func designRequest(weekOf date: Date, in context: ModelContext, calendar: Calendar = .current) -> ProgramDesigner.Request? {
        let monday = Week.start(of: date, calendar: calendar)
        guard let profile = try? context.fetch(FetchDescriptor<Profile>()).first, profile.isComplete,
              let templates = try? context.fetch(FetchDescriptor<Template>()),
              let entries = try? context.fetch(FetchDescriptor<LogEntry>()) else { return nil }
        let history = loggedSets(entries, templates: templates)
        let names = Dictionary(templates.map { ($0.slug, $0.name) }, uniquingKeysWith: { first, _ in first })
        let active = ((try? context.fetch(FetchDescriptor<Goal>())) ?? []).filter { $0.status == .active }
        let goals = goalLines(active)
        let lastMonday = calendar.date(byAdding: .day, value: -7, to: monday)!
        let program = profile.programWeek(of: monday, calendar: calendar)
        let weeks = profile.program ?? []
        // A brief written for other goals or settings isn't this program's; `design` writes it again.
        let brief = profile.brief.flatMap { stored in
            stored.key == ProgramBrief.key(goals: goals, settings: profile.trainingSettings, weeks: weeks) ? stored.brief : nil
        }
        return ProgramDesigner.Request(
            monday: monday, settings: profile.trainingSettings, catalog: catalog(templates), names: names, history: history,
            weeksSinceDeload: Training.weeksSinceDeload(history, before: monday, calendar: calendar), program: program?.week,
            programIndex: program?.index, programWeeks: profile.program?.count, goals: goals,
            lastWeek: (try? self.plan(weekOf: lastMonday, in: context)).flatMap { $0 }.map { workouts($0, templates: templates) } ?? [],
            brief: program.flatMap { brief?.phase($0.week.phase) }, goalLifts: goalLifts(active, history: history),
            programPlan: weeks, sleepHours: sleepHours(entries, before: monday, calendar: calendar), calendar: calendar)
    }

    /// FIT-96: hours slept a night on average over the 7 days before `monday`, when any were logged.
    static func sleepHours(_ entries: [LogEntry], before monday: Date, calendar: Calendar = .current) -> Double? {
        let since = calendar.date(byAdding: .day, value: -7, to: monday)!
        let hours = entries.filter { $0.kind == .sleep && $0.timestamp >= since && $0.timestamp < monday }
            .compactMap { entry in entry.measurements.first { $0.metric == "sleep_h" }?.value }
        return hours.isEmpty ? nil : hours.reduce(0, +) / Double(hours.count)
    }

    /// "Bench more 225 lb by Jan 9": the goals as the designer and the brief are told them.
    static func goalLines(_ goals: [Goal]) -> [String] {
        goals.filter { $0.status == .active }.compactMap { goal in
            guard let option = GoalOption.all.first(where: { $0.metric == goal.metric }) else { return nil }
            return option.title(target: goal.target)
                + (goal.deadline.map { " by \($0.formatted(.dateTime.month(.abbreviated).day()))" } ?? "")
        }
    }

    /// FIT-95: the strength goals a week works toward: a lift's estimated max or reps in a row, from where it started.
    static func goalLifts(_ goals: [Goal], history: [LoggedSet]) -> [GoalLift] {
        goals.filter { $0.status == .active }.compactMap { goal in
            let parts = goal.metric.split(separator: ".").map(String.init)
            guard parts.count == 2, ["1rm_lb", "reps"].contains(parts[1]),
                  let start = goal.baseline ?? GoalProgress.current(goal.metric, sets: history, weighIns: [], since: .distantPast)
            else { return nil }
            return GoalLift(exercise: parts[0], measure: parts[1], start: start, target: goal.target, deadline: goal.deadline)
        }
    }

    /// FIT-95: the program brief for the design request's program, written by the model when the profile has none for
    /// it (a new program, or goals, days or equipment changed since). Kept on the profile.
    static func writeBrief(for request: ProgramDesigner.Request, profile: Profile, model: any AIModel = OnDeviceModel()) async -> ProgramBrief? {
        guard !request.programPlan.isEmpty else { return nil }
        let key = ProgramBrief.key(goals: request.goals, settings: request.settings, weeks: request.programPlan)
        if let stored = profile.brief, stored.key == key { return stored.brief }
        guard let brief = await ProgramBrief.write(ProgramBrief.Request(
            settings: request.settings, catalog: request.catalog, names: request.names, goals: request.goals,
            goalLifts: request.goalLifts, weeks: request.programPlan), model: model) else { return nil }
        profile.brief = ProgramBrief.Stored(brief: brief, key: key, model: model.name)
        return brief
    }

    static func design(weekOf date: Date = .now, in context: ModelContext, model: any AIModel = OnDeviceModel(),
                       calendar: Calendar = .current) async {
        let monday = Week.start(of: date, calendar: calendar)
        guard model.isAvailable, !designing.weeks.contains(monday),
              let plan = try? plan(weekOf: monday, in: context), plan.designedBy == nil,
              let profile = try? context.fetch(FetchDescriptor<Profile>()).first, profile.isComplete,
              let templates = try? context.fetch(FetchDescriptor<Template>()),
              let entries = try? context.fetch(FetchDescriptor<LogEntry>()),
              var request = designRequest(weekOf: monday, in: context, calendar: calendar) else { return }
        designing.weeks.insert(monday)
        defer { designing.weeks.remove(monday) }
        if request.brief == nil, let program = profile.programWeek(of: monday, calendar: calendar) {
            request.brief = await writeBrief(for: request, profile: profile, model: model)?.phase(program.week.phase)
        }
        // FIT-101: each main lift's top set decided by the rule table first; the model designs the week around them.
        request.progression = await Progression.decided(request, by: Progression.Rules(tier: AgeTier.of(age: profile.age)))
        let result = await ProgramDesigner.week(request, model: model)
        // The week may have been planned again while the model worked; that plan gets its own turn.
        guard let current = try? self.plan(weekOf: monday, in: context), current.id == plan.id else { return }
        land(result, on: plan, entries: entries, templates: templates, in: context, calendar: calendar)
    }

    /// A designed week replaces the plan's, but for days done or pinned; the plan is marked designed either way.
    private static func land(_ result: ProgramDesigner.Result, on plan: Plan, entries: [LogEntry], templates: [Template],
                             in context: ModelContext, calendar: Calendar) {
        guard plan.designedBy == nil else { return }
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

    /// Onboarding's first week, when Start was tapped before its design came back: Today says the coach is planning
    /// it, and it lands as `design`'s would (with the brief, if the profile has none yet). Without a design, `design`
    /// starts one.
    static func finishFirstWeek(_ design: Task<(brief: ProgramBrief?, model: String, result: ProgramDesigner.Result)?, Never>,
                                weekOf date: Date = .now, in context: ModelContext, model: any AIModel,
                                calendar: Calendar = .current) async {
        let monday = Week.start(of: date, calendar: calendar)
        designing.weeks.insert(monday)
        let done = await design.value
        designing.weeks.remove(monday)
        guard let done else { return await self.design(weekOf: monday, in: context, model: model, calendar: calendar) }
        guard let profile = try? context.fetch(FetchDescriptor<Profile>()).first,
              let templates = try? context.fetch(FetchDescriptor<Template>()),
              let entries = try? context.fetch(FetchDescriptor<LogEntry>()),
              let plan = try? plan(weekOf: monday, in: context) else { return }
        if profile.brief == nil, let brief = done.brief {
            let goals = goalLines((try? context.fetch(FetchDescriptor<Goal>())) ?? [])
            profile.brief = ProgramBrief.Stored(brief: brief, key: ProgramBrief.key(goals: goals, settings: profile.trainingSettings,
                                                                                    weeks: profile.program ?? []), model: done.model)
        }
        land(done.result, on: plan, entries: entries, templates: templates, in: context, calendar: calendar)
    }

    // MARK: The coach (FIT-103)

    /// What the coach is told: the profile's settings and program, the goals, and this week from today on, days done left out.
    static func coachContext(in context: ModelContext, now: Date = .now, calendar: Calendar = .current) -> CoachChat.Context? {
        guard let profile = try? context.fetch(FetchDescriptor<Profile>()).first, profile.isComplete,
              let templates = try? context.fetch(FetchDescriptor<Template>()),
              let entries = try? context.fetch(FetchDescriptor<LogEntry>()) else { return nil }
        let names = Dictionary(templates.map { ($0.slug, $0.name) }, uniquingKeysWith: { first, _ in first })
        let today = calendar.startOfDay(for: now)
        let done = Set(entries.filter { $0.kind == .workout }.map { calendar.startOfDay(for: $0.timestamp) })
        let week = ((try? plan(weekOf: now, in: context, calendar: calendar)) ?? nil).map { workouts($0, templates: templates) }?
            .filter { $0.date >= today && !done.contains(calendar.startOfDay(for: $0.date)) } ?? []
        let goals = goalLines(((try? context.fetch(FetchDescriptor<Goal>())) ?? []).filter { $0.status == .active })
        let phases = profile.brief?.brief.phases.map { "\($0.phase): \($0.focus); main lifts \($0.mainLifts.joined(separator: ", ")) × \($0.mainReps)." } ?? []
        return CoachChat.Context(now: now, settings: profile.trainingSettings, catalog: catalog(templates), names: names,
                                 history: loggedSets(entries, templates: templates), week: week, goals: goals, program: profile.program,
                                 programStart: profile.programStart, targetDate: profile.targetDate, travelWeeks: profile.travelWeeks,
                                 phases: phases, calendar: calendar)
    }

    /// The coach's draft, applied: the program's settings, then the rest of this week, as the draft has it or planned
    /// again for new settings (and then designed, by whoever calls `design`). Days done stay. Returns the Undo.
    static func applyCoach(_ draft: CoachChat.Draft, in context: ModelContext, now: Date = .now,
                           calendar: Calendar = .current) throws -> () -> Void {
        guard let profile = try context.fetch(FetchDescriptor<Profile>()).first else { return {} }
        let templates = try context.fetch(FetchDescriptor<Template>())
        let entries = try context.fetch(FetchDescriptor<LogEntry>())
        let before = (days: profile.trainingDays, minutes: profile.sessionMinutes, target: profile.targetDate, travel: profile.travelWeeks)
        let programChanged = draft.trainingDays != nil || draft.sessionMinutes != nil || draft.targetDate != nil || draft.travelWeeks != nil
        if let days = draft.trainingDays { profile.trainingDays = days }
        if let minutes = draft.sessionMinutes { profile.sessionMinutes = minutes }
        if let target = draft.targetDate { profile.targetDate = target }
        if let travel = draft.travelWeeks { profile.travelWeeks = travel }
        if programChanged { profile.updatedAt = now }
        try context.save()
        let done = Set(entries.filter { $0.kind == .workout }.map { calendar.startOfDay(for: $0.timestamp) })
        var removed: [PlannedWorkout] = []
        var designedBy: String?
        if let plan = try plan(weekOf: now, in: context, calendar: calendar) {
            designedBy = plan.designedBy
            if let week = draft.week {
                removed = try replan(plan, with: week, keep: done, today: now, templates: templates, in: context, calendar: calendar)
            } else if programChanged {
                removed = try replan(plan, with: try preview(weekOf: now, in: context, calendar: calendar), keep: done, today: now,
                                     templates: templates, in: context, calendar: calendar)
                // New settings: the coach designs the rest of the week again.
                plan.designedBy = nil
                try context.save()
            }
        }
        return {
            profile.trainingDays = before.days
            profile.sessionMinutes = before.minutes
            profile.targetDate = before.target
            profile.travelWeeks = before.travel
            if let plan = try? self.plan(weekOf: now, in: context, calendar: calendar) {
                _ = try? replan(plan, with: removed, keep: done, today: now, templates: templates, in: context, calendar: calendar)
                plan.designedBy = designedBy
            }
            try? context.save()
        }
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
