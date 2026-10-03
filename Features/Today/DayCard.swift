import Foundation

/// What one day's card on Today shows (FIT-27): the plan, what was done, or rest.
enum DayCard {
    case plan(Planned)
    case done(Done)
    case rest(String)

    struct Planned {
        var items: [PlannedActivity]
        var session: SessionPlan
        var title: String
        var start: Date
        var minutes: Int
        var coach: String
    }

    struct Done {
        var title: String
        var start: Date
        var minutes: Int?
        var sets: Int
        var volume: Double
        var coach: String
        var note: String
        var feel: Feel?
        var planned: [PlannedActivity]
    }

    /// Workouts only: cooking and groceries are left off Today for now (FIT-25).
    @MainActor
    static func make(day: Date, planned: [PlannedActivity], entries: [LogEntry], next: (name: String, date: Date)?,
                     context: Context) -> DayCard {
        let calendar = Calendar.current
        let items = planned.filter { $0.kind == .workout && calendar.isDate($0.date, inSameDayAs: day) }.sorted { $0.date < $1.date }
        let logged = entries.filter { $0.kind == .workout && calendar.isDate($0.timestamp, inSameDayAs: day) }
        if !logged.isEmpty { return .done(summary(logged, planned: items, context: context)) }
        guard let first = items.first else { return .rest(Coach.rest(next: next, from: day)) }
        let reasons = items.compactMap(\.adjustedReason)
        let minutes = reasons.first { $0.hasSuffix("min available") }.flatMap { Int($0.prefix { $0.isNumber }) }
            ?? context.sessionMinutes
        return .plan(Planned(items: items, session: Planner.session(items, templates: context.templates),
                             title: first.slot ?? "Workout", start: first.date, minutes: minutes,
                             coach: Coach.plan(deload: context.deload, reasons: reasons)))
    }

    struct Context {
        var templates: [Template]
        var sessionMinutes: Int
        var deload: Bool
        var tier: AgeTier
    }

    @MainActor
    private static func summary(_ entries: [LogEntry], planned: [PlannedActivity], context: Context) -> Done {
        let session = SessionRecord.lastSession(entries.sorted { $0.timestamp < $1.timestamp }, isSummary: { $0.templateRef == nil })
        let summary = session.last { $0.templateRef == nil }
        let sets = session.filter { $0.templateRef != nil }
        let logged = Planner.loggedSets(Array(sets), templates: context.templates)
        func value(_ metric: String) -> Double? { summary?.measurements.first { $0.metric == metric }?.value }
        let completion = value("completion_rate")
        let missed = completion.map { $0 > 0 ? Int((Double(logged.count) / $0).rounded()) - logged.count : 0 } ?? 0
        let title = planned.first?.slot ?? "Workout"
        // Sessions saved before FIT-28 kept the session's name in the summary's note.
        let note = summary.map { summary in
            summary.note == title || sets.contains { $0.note == summary.note } ? "" : summary.note
        } ?? ""
        return Done(title: title, start: sets.first?.timestamp ?? summary?.timestamp ?? .now,
                    minutes: value("duration_s").map { max(1, Int(($0 / 60).rounded())) }, sets: logged.count,
                    volume: SessionRecord(logged, groups: []).volume,
                    coach: Coach.done(lifts(Array(sets), planned: planned, context: context), missedSets: missed),
                    note: note, feel: Feel(effort: value("effort")), planned: planned)
    }

    /// Main lifts in the order they were done, with what the progression rule plans next.
    @MainActor
    static func lifts(_ entries: [LogEntry], planned: [PlannedActivity], context: Context) -> [Coach.Lift] {
        let byID = Dictionary(context.templates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let main = Set(Planner.catalog(context.templates).filter(\.isGoalLift).map(\.slug))
        let plannedReps = Dictionary(planned.map { ($0.id, $0.targets.first { $0.metric == "reps" }?.value) },
                                     uniquingKeysWith: { first, _ in first })
        var lifts: [Coach.Lift] = []
        for template in entries.compactMap({ $0.templateRef.flatMap { byID[$0] } }) where main.contains(template.slug)
            && !lifts.contains(where: { $0.name == template.name }) {
            let mine = entries.filter { $0.templateRef == template.id }
            let sets = Planner.loggedSets(mine, templates: context.templates)
            guard let next = SessionRecord.nextLoad(sets, main: true, tier: context.tier) else { continue }
            let short = mine.enumerated().compactMap { index, entry -> (set: Int, done: Double, planned: Double)? in
                guard let done = entry.measurements.first(where: { $0.metric == "reps" })?.value,
                      let planned = entry.plannedRef.flatMap({ plannedReps[$0] }) ?? nil, done < planned else { return nil }
                return (index + 1, done, planned)
            }
            lifts.append(Coach.Lift(name: template.name, load: next.from, next: next.to, short: short))
        }
        return lifts
    }
}
