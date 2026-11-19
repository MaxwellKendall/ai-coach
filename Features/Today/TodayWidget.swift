import Foundation
import SwiftData
import WidgetKit

/// TKL-802: keeps the "today's workout" widget's snapshot (Core/Widget/TodaySnapshot.swift) current. The app calls
/// `refresh` on launch, whenever the store saves (a plan or a log changed, here or by sync) and when the plate changes;
/// it writes this week and next to the App Group and reloads the widget's timelines when they changed.
@MainActor
enum TodayWidget {
    /// The widget's kind, as Widgets/TodayWidget.swift registers it.
    static let kind = "TodayWidget"

    /// The snapshot as of `now`: Sunday of this week through Saturday of next, each day as Today shows it.
    static func snapshot(_ context: ModelContext, now: Date = .now, calendar: Calendar = .current) throws -> TodaySnapshot {
        let planned = try context.fetch(FetchDescriptor<PlannedActivity>(sortBy: [SortDescriptor(\.date)])).filter { $0.kind == .workout }
        let entries = try context.fetch(FetchDescriptor<LogEntry>(sortBy: [SortDescriptor(\.timestamp)])).filter { $0.kind == .workout }
        let templates = try context.fetch(FetchDescriptor<Template>())
        let profile = try context.fetch(FetchDescriptor<Profile>()).first
        let bySlug = Dictionary(templates.map { ($0.slug, $0.name) }, uniquingKeysWith: { first, _ in first })
        let byID = Dictionary(templates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func name(_ slug: String) -> (name: String, short: String) {
            let name = bySlug[slug] ?? slug
            let short = TodayScreen.short(name)
            return (name, short.prefix(1).uppercased() + short.dropFirst())
        }
        let context = DayCard.Context(templates: templates, sessionMinutes: profile?.sessionMinutes ?? 45, deload: false,
                                      tier: AgeTier.of(age: profile?.age ?? 30))
        let sunday = Week.start(of: now, calendar: calendar)
        let days = (0..<14).map { calendar.date(byAdding: .day, value: $0, to: sunday)! }
        let inputs = days.map { day -> (date: Date, input: TodaySnapshot.Input) in
            let next = planned.first { $0.date >= calendar.date(byAdding: .day, value: 1, to: day)! }
            switch DayCard.make(day: day, planned: planned, entries: entries, next: next.map { ($0.slot ?? "Workout", $0.date) }, context: context) {
            case .plan(let plan):
                return (day, .plan(title: TodayScreen.title(plan.session, names: bySlug, fallback: plan.title), session: plan.session, minutes: plan.minutes))
            case .done(let done):
                let logged = entries.filter { $0.templateRef != nil && calendar.isDate($0.timestamp, inSameDayAs: day) }
                let title = TodayScreen.title(Planner.session(done.planned, templates: templates), names: bySlug, fallback: done.title)
                return (day, .done(title: title, sets: done.sets, volume: done.volume,
                                   logged: Planner.loggedSets(logged, templates: templates), at: done.start))
            case .rest:
                return (day, .rest)
            }
        }
        // Each day's first logged set: when they start, for the usual time.
        let runs = Set(templates.filter { Running.runs.contains($0.slug) }.map(\.id))
        let starts = Dictionary(grouping: entries.filter { $0.templateRef.map { byID[$0] != nil && !runs.contains($0) } == true },
                                by: { calendar.startOfDay(for: $0.timestamp) }).values.compactMap { $0.map(\.timestamp).min() }
        let setUp = !planned.isEmpty || profile?.programStart != nil
        return TodaySnapshot.build(inputs, name: name, starts: starts, setUp: setUp, plate: Plate.current.rawValue, calendar: calendar)
    }

    /// Writes the snapshot if it changed, and reloads the widget. Returns whether it wrote.
    @discardableResult
    static func refresh(_ context: ModelContext, now: Date = .now, to url: URL? = TodaySnapshot.url) -> Bool {
        guard let url, let snapshot = try? snapshot(context, now: now), let data = try? TodaySnapshot.encoder.encode(snapshot) else { return false }
        if (try? Data(contentsOf: url)) == data { return false }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return false
        }
        WidgetCenter.shared.reloadAllTimelines()
        return true
    }
}
