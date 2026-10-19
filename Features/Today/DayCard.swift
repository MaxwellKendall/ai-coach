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
        /// FIT-185: runs already logged beside the day's lifting.
        var ran: [LogEntry] = []
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
        /// FIT-179: a day that was only a run: its distance and time.
        var runMeters: Double? = nil
        var runSeconds: Double? = nil
        /// FIT-185: where a tracked run went.
        var route: [Polyline.Point]? = nil
        /// FIT-188: the run a run-only day opens to.
        var run: LogEntry? = nil
    }

    /// Workouts only: cooking and groceries are left off Today for now (FIT-25).
    @MainActor
    static func make(day: Date, planned: [PlannedActivity], entries: [LogEntry], next: (name: String, date: Date)?,
                     context: Context) -> DayCard {
        let calendar = Calendar.current
        let items = planned.filter { $0.kind == .workout && calendar.isDate($0.date, inSameDayAs: day) }.sorted { $0.date < $1.date }
        let logged = entries.filter { $0.kind == .workout && calendar.isDate($0.timestamp, inSameDayAs: day) }
        // FIT-179: a run doesn't finish the day's lifting; a day that was only a run shows the run.
        let runs = Set(context.templates.filter { Running.runs.contains($0.slug) }.map(\.id))
        let ran = logged.filter { $0.templateRef.map(runs.contains) == true }
        let lifted = logged.filter { $0.templateRef.map(runs.contains) != true }
        let liftsPlanned = items.contains { $0.templateRef.map(runs.contains) != true }
        if !lifted.isEmpty { return .done(summary(lifted, planned: items, context: context)) }
        if !ran.isEmpty && !liftsPlanned { return .done(runSummary(ran, planned: items)) }
        guard let first = items.first else { return .rest(Coach.rest(next: next, from: day)) }
        let reasons = items.compactMap(\.adjustedReason)
        // FIT-183: a day of runs only is as long as its runs, with a running tip.
        let runMinutes = liftsPlanned ? nil : items.flatMap(\.targets).filter { $0.metric == "duration_s" }.map(\.value).reduce(0, +) / 60
        let minutes = reasons.first { $0.hasSuffix("min available") }.flatMap { Int($0.prefix { $0.isNumber }) }
            ?? runMinutes.flatMap { $0 > 0 ? Int($0.rounded()) : nil } ?? context.sessionMinutes
        return .plan(Planned(items: items, session: Planner.session(items, templates: context.templates),
                             title: first.slot ?? "Workout", start: first.date, minutes: minutes,
                             coach: liftsPlanned ? Coach.plan(deload: context.deload, reasons: reasons) : Coach.run(kind: first.note),
                             ran: ran))
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

    private static func runSummary(_ runs: [LogEntry], planned: [PlannedActivity]) -> Done {
        func total(_ metric: String) -> Double { runs.compactMap { $0.measurements.first { $0.metric == metric }?.value }.reduce(0, +) }
        let meters = total("distance_m"), seconds = total("duration_s")
        let first = runs.min { $0.timestamp < $1.timestamp }
        let coach = meters > 0 && seconds > 0 ? "\(Running.distance(meters)) in \(Running.clock(seconds)), \(Running.pace(seconds: seconds, meters: meters))." : "Run logged."
        return Done(title: planned.first?.slot ?? "Run", start: first?.timestamp ?? .now, minutes: seconds > 0 ? Int((seconds / 60).rounded()) : nil,
                    sets: 0, volume: 0, coach: coach, note: first?.note ?? "", feel: nil, planned: planned,
                    runMeters: meters > 0 ? meters : nil, runSeconds: seconds > 0 ? seconds : nil,
                    route: runs.lazy.compactMap { $0.route.flatMap(Polyline.decode) }.first { $0.count > 1 },
                    run: first)
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
