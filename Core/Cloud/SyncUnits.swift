import CryptoKit
import Foundation
import SwiftData

/// FIT-126: the program and logs as units the server keeps a copy of: a day's planned activity (`plan#2026-10-16`), a
/// day's log entries (`log#…`), each goal (`goal#UUID`) and the profile. Bodies are canonical JSON, so the same data
/// is always the same bytes; the phone works out what changed by comparing them with what the server last agreed to.
enum SyncUnits {
    struct PlanRow: Codable, Equatable {
        var id: UUID
        var kind: ActivityKind
        /// Seconds since 1970, exact. Sessions' rows are ordered by these (Planner.activity's second offsets).
        var at: Date
        var slot: String?
        /// The template's slug, the same on every device.
        var template: String?
        var targets: [Measurement]
        var note: String
        var adjustedReason: String?
        var group: Int?
        var main: Bool
        var pinned: Bool
    }

    struct LogRow: Codable, Equatable {
        var id: UUID
        var kind: ActivityKind
        var at: Date
        var plannedRef: UUID?
        var template: String?
        var measurements: [Measurement]
        var note: String
    }

    struct GoalBody: Codable, Equatable {
        var kind: GoalKind
        var metric: String
        var target: Double
        var unit: String
        var deadline: Date?
        var baseline: Double?
        var status: GoalStatus
    }

    struct ProfileBody: Codable, Equatable {
        var age: Int
        var weightLb: Double
        var targetWeightLb: Double?
        var daysPerWeek: Int
        var sessionMinutes: Int
        var trainingDays: [Int]
        var workoutTime: Int
        var equipment: [String]
        var injuredAreas: [String]
        var fineAreas: [String: Date]
        var avoidExercises: [String]
        var maxWeeklySets: Int
        var style: TrainingStyle
        var warmups: Bool
        var deloadEveryWeeks: Int?
        var cookWindows: [CookWindow]
        var groceryDay: Int?
        var weeklyBudgetUSD: Double?
        var programStart: Date?
        var targetDate: Date?
        var travelWeeks: [Int]
        var starts: [StartingSet]
        var brief: ProgramBrief.Stored?
    }

    static func encode(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .secondsSince1970
        return String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ body: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(type, from: Data(body.utf8))
    }

    static func hash(_ body: String) -> String {
        SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    /// The day a `plan#` or `log#` key is about, as its first moment.
    static func date(ofKey key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "#").last?.split(separator: "-").compactMap { Int($0) } ?? []
        guard key.hasPrefix("plan#") || key.hasPrefix("log#"), parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    // MARK: From the store

    /// Every unit on this device, key → body. Days and goals with nothing in them aren't units.
    static func all(in context: ModelContext, calendar: Calendar = .current) throws -> [String: String] {
        let slugs = Dictionary(try context.fetch(FetchDescriptor<Template>()).map { ($0.id, $0.slug) }, uniquingKeysWith: { a, _ in a })
        var units: [String: String] = [:]
        let planned = Dictionary(grouping: try context.fetch(FetchDescriptor<PlannedActivity>())) { day($0.date, calendar: calendar) }
        for (day, items) in planned {
            units["plan#\(day)"] = encode(items.sorted(by: order).map { planRow($0, slugs) })
        }
        let logged = Dictionary(grouping: try context.fetch(FetchDescriptor<LogEntry>())) { day($0.timestamp, calendar: calendar) }
        for (day, entries) in logged {
            units["log#\(day)"] = encode(entries.sorted(by: order).map { logRow($0, slugs) })
        }
        for goal in try context.fetch(FetchDescriptor<Goal>()) {
            units["goal#\(goal.id.uuidString)"] = encode(goalBody(goal))
        }
        if let profile = try context.fetch(FetchDescriptor<Profile>()).first {
            units["profile"] = encode(profileBody(profile))
        }
        return units
    }

    private static func order(_ a: PlannedActivity, _ b: PlannedActivity) -> Bool {
        (a.date, a.id.uuidString) < (b.date, b.id.uuidString)
    }

    private static func order(_ a: LogEntry, _ b: LogEntry) -> Bool {
        (a.timestamp, a.id.uuidString) < (b.timestamp, b.id.uuidString)
    }

    static func planRow(_ item: PlannedActivity, _ slugs: [UUID: String]) -> PlanRow {
        PlanRow(id: item.id, kind: item.kind, at: item.date, slot: item.slot, template: item.templateRef.flatMap { slugs[$0] },
                targets: item.targets, note: item.note, adjustedReason: item.adjustedReason, group: item.group, main: item.main,
                pinned: item.pinned)
    }

    static func logRow(_ entry: LogEntry, _ slugs: [UUID: String]) -> LogRow {
        LogRow(id: entry.id, kind: entry.kind, at: entry.timestamp, plannedRef: entry.plannedRef,
               template: entry.templateRef.flatMap { slugs[$0] }, measurements: entry.measurements, note: entry.note)
    }

    static func goalBody(_ goal: Goal) -> GoalBody {
        GoalBody(kind: goal.kind, metric: goal.metric, target: goal.target, unit: goal.unit, deadline: goal.deadline,
                 baseline: goal.baseline, status: goal.status)
    }

    static func profileBody(_ p: Profile) -> ProfileBody {
        ProfileBody(age: p.age, weightLb: p.weightLb, targetWeightLb: p.targetWeightLb, daysPerWeek: p.daysPerWeek,
                    sessionMinutes: p.sessionMinutes, trainingDays: p.trainingDays, workoutTime: p.workoutTime, equipment: p.equipment,
                    injuredAreas: p.injuredAreas, fineAreas: p.fineAreas, avoidExercises: p.avoidExercises, maxWeeklySets: p.maxWeeklySets,
                    style: p.style, warmups: p.warmups, deloadEveryWeeks: p.deloadEveryWeeks, cookWindows: p.cookWindows,
                    groceryDay: p.groceryDay, weeklyBudgetUSD: p.weeklyBudgetUSD, programStart: p.programStart, targetDate: p.targetDate,
                    travelWeeks: p.travelWeeks, starts: p.starts, brief: p.brief)
    }

    // MARK: Into the store

    /// Makes the store hold what a unit says: rows are updated in place by id (so a log keeps its photo), added, or
    /// removed when the unit no longer has them. `body` nil is a deleted unit. The caller saves.
    static func apply(_ key: String, body: String?, in context: ModelContext, calendar: Calendar = .current) throws {
        let templates = try context.fetch(FetchDescriptor<Template>())
        let ids = Dictionary(templates.map { ($0.slug, $0.id) }, uniquingKeysWith: { a, _ in a })
        let now = Date.now
        if key.hasPrefix("plan#"), let start = date(ofKey: key, calendar: calendar) {
            let rows = try body.map { try decode([PlanRow].self, $0) } ?? []
            let end = calendar.date(byAdding: .day, value: 1, to: start)!
            let wanted = Set(rows.map(\.id))
            let onDay = try context.fetch(FetchDescriptor<PlannedActivity>(predicate: #Predicate { $0.date >= start && $0.date < end }))
            let existing = try context.fetch(FetchDescriptor<PlannedActivity>(predicate: #Predicate { wanted.contains($0.id) }))
            let byId = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var plans = try context.fetch(FetchDescriptor<Plan>())
            for item in onDay where !wanted.contains(item.id) { context.delete(item) }
            for row in rows {
                let item = byId[row.id] ?? {
                    let new = PlannedActivity(kind: row.kind, date: row.at, now: now)
                    new.id = row.id
                    context.insert(new)
                    return new
                }()
                item.kind = row.kind
                item.date = row.at
                item.slot = row.slot
                item.templateRef = row.template.flatMap { ids[$0] }
                item.targets = row.targets
                item.note = row.note
                item.adjustedReason = row.adjustedReason
                item.group = row.group
                item.main = row.main
                item.pinned = row.pinned
                item.updatedAt = now
                let week = Week.start(of: row.at, calendar: calendar)
                if item.plan?.weekStart != week {
                    let plan = plans.first { $0.weekStart == week } ?? {
                        let new = Plan(weekContaining: row.at, calendar: calendar, now: now)
                        context.insert(new)
                        plans.append(new)
                        return new
                    }()
                    item.plan = plan
                }
            }
        } else if key.hasPrefix("log#"), let start = date(ofKey: key, calendar: calendar) {
            let rows = try body.map { try decode([LogRow].self, $0) } ?? []
            let end = calendar.date(byAdding: .day, value: 1, to: start)!
            let wanted = Set(rows.map(\.id))
            let onDay = try context.fetch(FetchDescriptor<LogEntry>(predicate: #Predicate { $0.timestamp >= start && $0.timestamp < end }))
            let existing = try context.fetch(FetchDescriptor<LogEntry>(predicate: #Predicate { wanted.contains($0.id) }))
            let byId = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for entry in onDay where !wanted.contains(entry.id) { context.delete(entry) }
            for row in rows {
                let entry = byId[row.id] ?? {
                    let new = LogEntry(kind: row.kind, timestamp: row.at, now: now)
                    new.id = row.id
                    context.insert(new)
                    return new
                }()
                entry.kind = row.kind
                entry.timestamp = row.at
                entry.plannedRef = row.plannedRef
                entry.templateRef = row.template.flatMap { ids[$0] }
                entry.measurements = row.measurements
                entry.note = row.note
                entry.updatedAt = now
            }
        } else if key.hasPrefix("goal#"), let id = UUID(uuidString: String(key.dropFirst(5))) {
            let goal = try context.fetch(FetchDescriptor<Goal>(predicate: #Predicate { $0.id == id })).first
            guard let body else {
                if let goal { context.delete(goal) }
                return
            }
            let g = try decode(GoalBody.self, body)
            let target = goal ?? {
                let new = Goal(kind: g.kind, metric: g.metric, target: g.target, unit: g.unit, now: now)
                new.id = id
                context.insert(new)
                return new
            }()
            target.kind = g.kind
            target.metric = g.metric
            target.target = g.target
            target.unit = g.unit
            target.deadline = g.deadline
            target.baseline = g.baseline
            target.status = g.status
            target.updatedAt = now
        } else if key == "profile", let body {
            let b = try decode(ProfileBody.self, body)
            let p = try context.fetch(FetchDescriptor<Profile>()).first ?? {
                let new = Profile(age: b.age, weightLb: b.weightLb, now: now)
                context.insert(new)
                return new
            }()
            p.age = b.age
            p.weightLb = b.weightLb
            p.targetWeightLb = b.targetWeightLb
            p.daysPerWeek = b.daysPerWeek
            p.sessionMinutes = b.sessionMinutes
            p.trainingDays = b.trainingDays
            p.workoutTime = b.workoutTime
            p.equipment = b.equipment
            p.injuredAreas = b.injuredAreas
            p.fineAreas = b.fineAreas
            p.avoidExercises = b.avoidExercises
            p.maxWeeklySets = b.maxWeeklySets
            p.style = b.style
            p.warmups = b.warmups
            p.deloadEveryWeeks = b.deloadEveryWeeks
            p.cookWindows = b.cookWindows
            p.groceryDay = b.groceryDay
            p.weeklyBudgetUSD = b.weeklyBudgetUSD
            p.programStart = b.programStart
            p.targetDate = b.targetDate
            p.travelWeeks = b.travelWeeks
            p.starts = b.starts
            p.brief = b.brief
            p.updatedAt = now
        }
    }
}

/// FIT-126: what this phone has agreed with the server, per unit, and what changed here since. Pure, so the merge
/// rules are tested without a server: the newest change wins per unit, and a deleted unit is a tombstone.
struct SyncState: Codable, Equatable {
    struct Pending: Codable, Equatable {
        var hash: String?
        var at: Date
    }

    struct Unit: Equatable {
        var key: String
        var updatedAt: Date
        var body: String?
        var deleted: Bool { body == nil }
    }

    /// key → hash of the body both sides hold. A unit not here doesn't exist on the server (or is a tombstone).
    var synced: [String: String] = [:]
    /// key → the local change not yet stored on the server, and when it was first seen as it is now.
    var pending: [String: Pending] = [:]
    var cursor: String?
    /// Done once: on the first sync the server's copy wins, so a new phone takes the account's program.
    var pulledOnce = false

    /// Notes what differs between `local` (key → body) and what's synced. A unit changed again gets a new time.
    mutating func notice(_ local: [String: String], now: Date) {
        for key in Set(local.keys).union(synced.keys).union(pending.keys) {
            let hash = local[key].map(SyncUnits.hash)
            if hash == synced[key] {
                pending[key] = nil
            } else if pending[key].map({ $0.hash != hash }) ?? true {
                pending[key] = Pending(hash: hash, at: now)
            }
        }
    }

    /// The pending changes, as units to push.
    func outgoing(_ local: [String: String]) -> [Unit] {
        pending.sorted { $0.key < $1.key }.map { Unit(key: $0.key, updatedAt: $0.value.at, body: local[$0.key]) }
    }

    /// The server stored these (those it rejected are applied as incoming units instead).
    mutating func pushed(_ units: [Unit]) {
        for unit in units {
            synced[unit.key] = unit.body.map(SyncUnits.hash)
            if let mine = pending[unit.key], mine.hash == synced[unit.key] { pending[unit.key] = nil }
        }
    }

    /// Whether a unit from the server should overwrite this phone's: not when it's what we already have, and not when
    /// this phone changed it later (that change is pushed instead).
    func shouldApply(_ unit: Unit) -> Bool {
        if !pulledOnce { return true }
        let hash = unit.body.map(SyncUnits.hash)
        if let mine = pending[unit.key] { return mine.at < unit.updatedAt && mine.hash != hash }
        return hash != synced[unit.key]
    }

    /// After applying a server unit; `local` is how the unit reads back from the store, which is what's now agreed
    /// (a template this phone doesn't know reads back without it, and isn't pushed over the server's).
    mutating func applied(_ key: String, local: String?) {
        synced[key] = local.map(SyncUnits.hash)
        pending[key] = nil
    }
}
