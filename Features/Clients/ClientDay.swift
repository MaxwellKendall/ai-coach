import Foundation
import SwiftData

/// FIT-298: one of a client's days, read from their sync units (SyncUnits' rows), and their session changed by hand
/// the way Today changes one's own (FIT-302), written back as the day's plan unit.
enum ClientDay {
    static func plan(_ units: [String: String], _ day: String) -> [SyncUnits.PlanRow] {
        units["plan#\(day)"].flatMap { try? SyncUnits.decode([SyncUnits.PlanRow].self, $0) } ?? []
    }

    static func log(_ units: [String: String], _ day: String) -> [SyncUnits.LogRow] {
        units["log#\(day)"].flatMap { try? SyncUnits.decode([SyncUnits.LogRow].self, $0) } ?? []
    }

    /// FIT-347: what the client can do, from their profile, for the exercise picker. Everything when there's no profile yet.
    static func settings(_ units: [String: String]) -> TrainingSettings {
        let profile = units["profile"].flatMap { try? SyncUnits.decode(SyncUnits.ProfileBody.self, $0) }
        return TrainingSettings(
            age: profile?.age ?? 35, daysPerWeek: profile?.daysPerWeek ?? 3, sessionMinutes: profile?.sessionMinutes ?? 45,
            trainingDays: Week.ordered(profile?.trainingDays ?? [0, 2, 4]), workoutTime: profile?.workoutTime ?? 420,
            equipment: Set(profile?.equipment ?? Profile.allEquipment), injuredAreas: BodyArea.muscles(for: profile?.injuredAreas ?? []),
            avoidExercises: Set(profile?.avoidExercises ?? []), maxWeeklySets: profile?.maxWeeklySets ?? 60)
    }

    /// FIT-347: every exercise in the client's plans and logs, with when, for the picker's Recent.
    static func uses(_ units: [String: String]) -> [(slug: String, at: Date)] {
        units.keys.flatMap { key -> [(slug: String, at: Date)] in
            let day = String(key.split(separator: "#", maxSplits: 1).last ?? "")
            if key.hasPrefix("plan#") { return plan(units, day).compactMap { row in row.template.map { ($0, row.at) } } }
            if key.hasPrefix("log#") { return log(units, day).compactMap { row in row.template.map { ($0, row.at) } } }
            return []
        }
    }

    static func trained(_ units: [String: String], _ day: String) -> Bool { log(units, day).contains { $0.kind == .workout } }
    static func planned(_ units: [String: String], _ day: String) -> Bool { plan(units, day).contains { $0.kind == .workout } }

    /// What they did, a line per exercise in the order done: "245 × 5, 5, 3 · RPE 9".
    static func lifts(_ log: [SyncUnits.LogRow], names: [String: String]) -> [(slug: String, name: String, sets: String)] {
        var order: [String] = []
        var sets: [String: [SyncUnits.LogRow]] = [:]
        for row in log.sorted(by: { $0.at < $1.at }) where row.kind == .workout {
            guard let slug = row.template else { continue }
            if sets[slug] == nil { order.append(slug) }
            sets[slug, default: []].append(row)
        }
        return order.map { slug in
            let rows = sets[slug]!
            let value = { (row: SyncUnits.LogRow, metric: String) in row.measurements.first { $0.metric == metric }?.value }
            let reps = rows.compactMap { value($0, "reps") }.map(Coach.number).joined(separator: ", ")
            let load = rows.compactMap { value($0, "load_lb") ?? value($0, "load_lb_hand") }.max()
            let rpe = rows.compactMap { value($0, "rpe") }.max()
            var line = load.map { "\(Coach.number($0)) × \(reps)" } ?? (reps.isEmpty ? "\(rows.count) sets" : reps)
            if let rpe { line += " · RPE \(Coach.number(rpe))" }
            return (slug, names[slug] ?? slug, line)
        }
    }

    /// The client's own words that day: the session's summary row, the check-in's note (FIT-223), and the weekly
    /// check-in's answers (FIT-344).
    static func notes(_ log: [SyncUnits.LogRow]) -> [String] {
        let session = log.filter { $0.kind == .workout && $0.template == nil }.map(\.note)
        let checkIn = (log.filter { $0.kind == .sleep } + log.filter { $0.kind == .bodyweight }).map(\.note)
        let weekly = log.filter { $0.kind == .checkin }.map(\.note)
        var seen = Set<String>()
        return (session + checkIn.prefix(1) + weekly).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The session's name, which each logged set carries as its note (WorkoutDraft.save).
    static func sessionName(_ log: [SyncUnits.LogRow]) -> String? {
        log.first { $0.kind == .workout && $0.template != nil && !$0.note.isEmpty }?.note
    }

    // MARK: FIT-337: a coach correcting what a client logged (the dashboard's FIT-200 fixSet)

    /// One logged set's weight, reps (or seconds) and RPE as typed; nil leaves a value out.
    struct SetFix: Equatable {
        var load: Double?
        var reps: Double?
        var rpe: Double?
    }

    /// The day's log with one set's numbers changed; its other measurements, and every other row, as they were.
    static func fixed(_ log: [SyncUnits.LogRow], id: UUID, _ fix: SetFix) -> [SyncUnits.LogRow] {
        log.map { row in
            guard row.id == id else { return row }
            var row = row
            let loadMetric = row.measurements.contains { $0.metric == "load_lb_hand" } ? "load_lb_hand" : "load_lb"
            let repsMetric = row.measurements.contains { $0.metric == "duration_s" } && !row.measurements.contains { $0.metric == "reps" }
                ? "duration_s" : "reps"
            func put(_ metric: String, _ value: Double?, unit: String) {
                row.measurements.removeAll { $0.metric == metric }
                if let value, value > 0 { row.measurements.append(Measurement(metric: metric, value: value, unit: unit)) }
            }
            put(repsMetric, fix.reps, unit: repsMetric == "reps" ? "reps" : "s")
            put(loadMetric, fix.load, unit: "lb")
            put("rpe", fix.rpe, unit: "RPE")
            return row
        }
    }

    // MARK: FIT-335: a coach programming a client's days

    /// A day's rows at another day, at the same times of day, pinned as a coach's change is (FIT-202). `fresh` gives
    /// them new ids, for a copy.
    static func shifted(_ rows: [SyncUnits.PlanRow], to day: Date, fresh: Bool = false,
                        calendar: Calendar = .current) -> [SyncUnits.PlanRow] {
        rows.map { row in
            var row = row
            row.at = calendar.startOfDay(for: day) + row.at.timeIntervalSince(calendar.startOfDay(for: row.at))
            row.pinned = true
            if fresh { row.id = UUID() }
            return row
        }
    }

    /// Rows added to a day after the ones it has, a second apart so their order holds (Planner.activity's offsets).
    static func appended(_ incoming: [SyncUnits.PlanRow], to existing: [SyncUnits.PlanRow]) -> [SyncUnits.PlanRow] {
        guard let last = existing.map(\.at).max() else { return incoming }
        return existing + incoming.sorted { $0.at < $1.at }.enumerated().map { index, row in
            var row = row
            row.at = last + TimeInterval(index + 1)
            return row
        }
    }

    /// A new exercise on a day, 3 × 10 as Add exercise starts one (SessionPlan.add), after what's there or at 9:00.
    static func exercise(_ slug: String, on day: Date, after existing: [SyncUnits.PlanRow],
                         calendar: Calendar = .current) -> [SyncUnits.PlanRow] {
        let row = SyncUnits.PlanRow(id: UUID(), kind: .workout, at: calendar.startOfDay(for: day) + 9 * 3600, slot: nil, template: slug,
                                    targets: [Measurement(metric: "sets", value: 3, unit: "sets"), Measurement(metric: "reps", value: 10, unit: "reps")],
                                    note: "", adjustedReason: "edited", group: nil, main: existing.isEmpty, pinned: true)
        return appended([row], to: existing)
    }

    /// A planned run, as the program plans one: the outdoor run with its distance, and its kind ("easy", "long", …)
    /// as the note, which Today's running tip reads (Coach.run).
    static func run(_ kind: String, miles: Double, on day: Date, after existing: [SyncUnits.PlanRow],
                    calendar: Calendar = .current) -> [SyncUnits.PlanRow] {
        let row = SyncUnits.PlanRow(id: UUID(), kind: .workout, at: calendar.startOfDay(for: day) + 7 * 3600, slot: "Run", template: Running.outdoor,
                                    targets: [Measurement(metric: "sets", value: 1, unit: "sets"),
                                              Measurement(metric: "distance_m", value: (miles * Running.mile).rounded(), unit: "m")],
                                    note: kind, adjustedReason: "edited", group: nil, main: false, pinned: true)
        return appended([row], to: existing)
    }

    /// A client's day as PlannedActivity, in a store of its own that's never saved, so Planner's session and its
    /// hand edits work on it as on one's own; `rows` turns it back into the day's unit.
    @MainActor final class Editor {
        private let context: ModelContext
        private let templates: [Template]

        init(_ rows: [SyncUnits.PlanRow], templates: [Template]) {
            context = ModelContext(try! AppSchema.container(inMemory: true))
            self.templates = templates
            let ids = Dictionary(templates.map { ($0.slug, $0.id) }, uniquingKeysWith: { a, _ in a })
            for row in rows {
                let item = PlannedActivity(kind: row.kind, date: row.at)
                item.id = row.id
                item.slot = row.slot
                item.templateRef = row.template.flatMap { ids[$0] }
                item.targets = row.targets
                item.note = row.note
                item.adjustedReason = row.adjustedReason
                item.group = row.group
                item.main = row.main
                item.pinned = row.pinned
                context.insert(item)
            }
        }

        private var all: [PlannedActivity] { ((try? context.fetch(FetchDescriptor<PlannedActivity>())) ?? []).sorted { $0.date < $1.date } }
        private var workouts: [PlannedActivity] { all.filter { $0.kind == .workout } }

        var session: SessionPlan? { workouts.isEmpty ? nil : Planner.session(workouts, templates: templates) }

        /// The session as changed by hand, pinned as a coach's change is (FIT-202), and the day's rows to send.
        func save(_ session: SessionPlan) -> [SyncUnits.PlanRow] {
            for item in Planner.save(session, over: workouts, templates: templates, in: context) { item.pinned = true }
            let slugs = Dictionary(templates.map { ($0.id, $0.slug) }, uniquingKeysWith: { a, _ in a })
            return all.map { SyncUnits.planRow($0, slugs) }
        }
    }
}
