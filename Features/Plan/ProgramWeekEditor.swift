import Foundation
import SwiftData

/// TKL-745: reordering workouts, making rest days, and copying workouts on the Program week card.
/// Every mutation stays inside one week's `Plan`, touches only `.workout` rows (never kitchen items),
/// preserves exercise ordering (second offsets) across DST boundaries, and returns an Undo closure.
@MainActor
enum ProgramWeekEditor {
    /// Marker on `Plan.designedBy` when the lifter rearranged or cleared days in a future week,
    /// so `Planner.ensureWeek` keeps their schedule instead of regenerating over newly-made rest days.
    static let userDesigned = "user"

    /// One calendar day of a week card (Sunday through Saturday), with its workout summary (nil on a rest day).
    struct DaySlot: Identifiable {
        var date: Date
        var workout: Planner.SketchDay?
        var done: Bool
        var missed: Bool
        var editable: Bool
        var id: Date { date }
    }

    /// Result of a week-level edit: toast message and an Undo closure that restores the plan exactly.
    struct Outcome {
        var message: String
        var undo: @MainActor () -> Void
    }

    /// Snapshot of a `PlannedActivity` so Undo can restore deleted or replaced rows with their exact IDs.
    private struct ItemSnapshot {
        var id: UUID
        var kind: ActivityKind
        var date: Date
        var slot: String?
        var templateRef: UUID?
        var targets: [Measurement]
        var note: String
        var adjustedReason: String?
        var group: Int?
        var main: Bool
        var pinned: Bool
        var sessionNote: String?

        init(_ item: PlannedActivity) {
            id = item.id
            kind = item.kind
            date = item.date
            slot = item.slot
            templateRef = item.templateRef
            targets = item.targets
            note = item.note
            adjustedReason = item.adjustedReason
            group = item.group
            main = item.main
            pinned = item.pinned
            sessionNote = item.sessionNote
        }

        func makeActivity(plan: Plan, now: Date) -> PlannedActivity {
            let item = PlannedActivity(
                kind: kind, date: date, slot: slot, templateRef: templateRef,
                targets: targets, note: note, adjustedReason: adjustedReason,
                group: group, main: main, now: now
            )
            item.id = id
            item.pinned = pinned
            item.sessionNote = sessionNote
            item.plan = plan
            return item
        }
    }

    /// Snapshot of mutable fields for items moved or swapped in place.
    private struct MoveSnapshot {
        var item: PlannedActivity
        var date: Date
        var pinned: Bool
        var adjustedReason: String?

        init(_ item: PlannedActivity) {
            self.item = item
            self.date = item.date
            self.pinned = item.pinned
            self.adjustedReason = item.adjustedReason
        }

        func restore(now: Date) {
            item.date = date
            item.pinned = pinned
            item.adjustedReason = adjustedReason
            item.updatedAt = now
        }
    }

    /// The 7 days of the week starting `weekStart` (Sunday through Saturday), matching `Week.start`.
    static func weekSlots(
        weekStart: Date,
        workouts: [Planner.SketchDay],
        loggedDays: Set<Date>,
        today: Date = .now,
        calendar: Calendar = .current
    ) -> [DaySlot] {
        let start = calendar.startOfDay(for: weekStart)
        let todayStart = calendar.startOfDay(for: today)
        let byDay = Dictionary(workouts.map { (calendar.startOfDay(for: $0.date), $0) }, uniquingKeysWith: { first, _ in first })
        return (0..<7).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: start)!
            let workout = byDay[date]
            let isDone = loggedDays.contains(date)
            let isMissed = workout != nil && date < todayStart && !isDone
            let editable = date >= todayStart && !isDone
            return DaySlot(date: date, workout: workout, done: isDone, missed: isMissed, editable: editable)
        }
    }

    /// Whether a day can be dragged, dropped onto, or cleared: today or later, and not already logged.
    static func isEditable(_ date: Date, loggedDays: Set<Date>, today: Date = .now, calendar: Calendar = .current) -> Bool {
        let day = calendar.startOfDay(for: date)
        return day >= calendar.startOfDay(for: today) && !loggedDays.contains(day)
    }

    // MARK: Drag-and-drop payload

    private static let dragPrefix = "program-day#"

    /// Scopes a dragged day to its week (`"program-day#yyyy-MM-dd#yyyy-MM-dd"`).
    static func dragPayload(weekStart: Date, day: Date, calendar: Calendar = .current) -> String {
        "\(dragPrefix)\(SyncUnits.day(weekStart, calendar: calendar))#\(SyncUnits.day(day, calendar: calendar))"
    }

    /// Returns the dragged day's start-of-day date if `payload` belongs to `expectedWeekStart`.
    static func parseDragPayload(_ payload: String, expectedWeekStart: Date, calendar: Calendar = .current) -> Date? {
        guard payload.hasPrefix(dragPrefix) else { return nil }
        let parts = payload.dropFirst(dragPrefix.count).split(separator: "#").map(String.init)
        guard parts.count == 2,
              parts[0] == SyncUnits.day(expectedWeekStart, calendar: calendar),
              let day = SyncUnits.date(ofKey: "plan#\(parts[1])", calendar: calendar) else { return nil }
        return calendar.startOfDay(for: day)
    }

    // MARK: Plan materialization

    /// Ensures a `Plan` exists in SwiftData for `weekStart` (generating an app-planned week only when
    /// no `Plan` exists yet, otherwise returning the existing `Plan` even if all days are now rest days).
    @discardableResult
    static func ensurePlan(
        weekOf weekStart: Date,
        plansItself: Bool,
        in context: ModelContext,
        calendar: Calendar = .current
    ) throws -> Plan {
        let start = Week.start(of: weekStart, calendar: calendar)
        if let existing = try Planner.plan(weekOf: start, in: context, calendar: calendar) {
            return existing
        }
        if plansItself, let generated = try Planner.generate(weekOf: start, in: context, calendar: calendar) {
            return generated
        }
        let created = Plan(weekContaining: start, calendar: calendar)
        context.insert(created)
        try context.save()
        return created
    }

    // MARK: Mutations

    /// Moves `from`'s workout to `to` (when `to` is a rest day) or swaps their workouts (when `to` has one).
    /// Returns nil when either day is locked, cross-week, the same day, or `from` has no workout.
    static func moveOrSwap(
        from: Date,
        to: Date,
        in plan: Plan,
        loggedDays: Set<Date>,
        coached: Bool,
        context: ModelContext,
        now: Date = .now,
        calendar: Calendar = .current
    ) throws -> Outcome? {
        let fromDay = calendar.startOfDay(for: from)
        let toDay = calendar.startOfDay(for: to)
        guard fromDay != toDay,
              Week.start(of: fromDay, calendar: calendar) == plan.weekStart,
              Week.start(of: toDay, calendar: calendar) == plan.weekStart,
              isEditable(fromDay, loggedDays: loggedDays, today: now, calendar: calendar),
              isEditable(toDay, loggedDays: loggedDays, today: now, calendar: calendar) else { return nil }

        let fromItems = workoutItems(on: fromDay, in: plan, calendar: calendar)
        guard !fromItems.isEmpty else { return nil }
        let toItems = workoutItems(on: toDay, in: plan, calendar: calendar)

        let delta = calendar.dateComponents([.day], from: fromDay, to: toDay).day ?? 0
        let snapshots = (fromItems + toItems).map(MoveSnapshot.init)
        let previousDesignedBy = plan.designedBy

        let fromWeekday = shortWeekday(fromDay, calendar: calendar)
        let toWeekday = shortWeekday(toDay, calendar: calendar)

        for item in fromItems {
            item.date = calendar.date(byAdding: .day, value: delta, to: item.date)!
            if !coached {
                item.pinned = true
                if !isCoachReason(item.adjustedReason) {
                    item.adjustedReason = toItems.isEmpty ? "Moved from \(wideWeekday(fromDay, calendar: calendar))" : "Swapped with \(wideWeekday(toDay, calendar: calendar))"
                }
            }
            item.updatedAt = now
        }
        for item in toItems {
            item.date = calendar.date(byAdding: .day, value: -delta, to: item.date)!
            if !coached {
                item.pinned = true
                if !isCoachReason(item.adjustedReason) {
                    item.adjustedReason = "Swapped with \(wideWeekday(fromDay, calendar: calendar))"
                }
            }
            item.updatedAt = now
        }

        markFutureUserEdit(plan, now: now, calendar: calendar)
        plan.updatedAt = now
        try context.save()

        let message = toItems.isEmpty ? "Moved \(fromWeekday) to \(toWeekday)" : "Swapped \(fromWeekday) and \(toWeekday)"
        return Outcome(message: message) {
            let undoNow = Date.now
            for snap in snapshots { snap.restore(now: undoNow) }
            plan.designedBy = previousDesignedBy
            plan.updatedAt = undoNow
            try? context.save()
        }
    }

    /// Clears all planned workout items on `day` so it becomes a rest day. Kitchen items stay untouched.
    static func makeRestDay(
        _ day: Date,
        in plan: Plan,
        loggedDays: Set<Date>,
        context: ModelContext,
        now: Date = .now,
        calendar: Calendar = .current
    ) throws -> Outcome? {
        let targetDay = calendar.startOfDay(for: day)
        guard Week.start(of: targetDay, calendar: calendar) == plan.weekStart,
              isEditable(targetDay, loggedDays: loggedDays, today: now, calendar: calendar) else { return nil }

        let items = workoutItems(on: targetDay, in: plan, calendar: calendar)
        guard !items.isEmpty else { return nil }

        let snapshots = items.map(ItemSnapshot.init)
        let gone = Set(items.map(\.id))
        let previousDesignedBy = plan.designedBy

        // Update the relationship array before deleting rows (matches Planner.apply/replace).
        plan.items = plan.items.filter { !gone.contains($0.id) }
        for item in items { context.delete(item) }
        markFutureUserEdit(plan, now: now, calendar: calendar)
        plan.updatedAt = now
        try context.save()

        let label = shortWeekday(targetDay, calendar: calendar)
        return Outcome(message: "\(label) set to rest day") {
            let undoNow = Date.now
            var restored: [PlannedActivity] = []
            for snap in snapshots {
                let item = snap.makeActivity(plan: plan, now: undoNow)
                context.insert(item)
                restored.append(item)
            }
            plan.items.append(contentsOf: restored)
            plan.designedBy = previousDesignedBy
            plan.updatedAt = undoNow
            try? context.save()
        }
    }

    /// Copies `from`'s planned workout onto `to` (replacing any existing workout on `to`).
    /// `from` may be any day in the week with planned workouts (including a missed past day); `to` must be editable.
    static func copyWorkout(
        from: Date,
        to: Date,
        in plan: Plan,
        loggedDays: Set<Date>,
        coached: Bool,
        context: ModelContext,
        now: Date = .now,
        calendar: Calendar = .current
    ) throws -> Outcome? {
        let fromDay = calendar.startOfDay(for: from)
        let toDay = calendar.startOfDay(for: to)
        guard fromDay != toDay,
              Week.start(of: fromDay, calendar: calendar) == plan.weekStart,
              Week.start(of: toDay, calendar: calendar) == plan.weekStart,
              isEditable(toDay, loggedDays: loggedDays, today: now, calendar: calendar) else { return nil }

        let sourceItems = workoutItems(on: fromDay, in: plan, calendar: calendar)
        guard !sourceItems.isEmpty else { return nil }

        let replacedItems = workoutItems(on: toDay, in: plan, calendar: calendar)
        let replacedSnapshots = replacedItems.map(ItemSnapshot.init)
        let gone = Set(replacedItems.map(\.id))
        let previousDesignedBy = plan.designedBy
        let delta = calendar.dateComponents([.day], from: fromDay, to: toDay).day ?? 0

        var copies: [PlannedActivity] = []
        for item in sourceItems {
            let copy = PlannedActivity(
                kind: .workout,
                date: calendar.date(byAdding: .day, value: delta, to: item.date)!,
                slot: item.slot,
                templateRef: item.templateRef,
                targets: item.targets,
                note: item.note,
                adjustedReason: coached ? item.adjustedReason : "Copied from \(wideWeekday(fromDay, calendar: calendar))",
                group: item.group,
                main: item.main,
                now: now
            )
            copy.pinned = !coached
            copy.sessionNote = item.sessionNote
            copy.plan = plan
            context.insert(copy)
            copies.append(copy)
        }

        plan.items = plan.items.filter { !gone.contains($0.id) } + copies
        for item in replacedItems { context.delete(item) }
        markFutureUserEdit(plan, now: now, calendar: calendar)
        plan.updatedAt = now
        try context.save()

        let createdIDs = Set(copies.map(\.id))
        let fromWeekday = shortWeekday(fromDay, calendar: calendar)
        let toWeekday = shortWeekday(toDay, calendar: calendar)
        return Outcome(message: "Copied \(fromWeekday) to \(toWeekday)") {
            let undoNow = Date.now
            let toRemove = plan.items.filter { createdIDs.contains($0.id) }
            plan.items = plan.items.filter { !createdIDs.contains($0.id) }
            for item in toRemove { context.delete(item) }
            var restored: [PlannedActivity] = []
            for snap in replacedSnapshots {
                let item = snap.makeActivity(plan: plan, now: undoNow)
                context.insert(item)
                restored.append(item)
            }
            plan.items.append(contentsOf: restored)
            plan.designedBy = previousDesignedBy
            plan.updatedAt = undoNow
            try? context.save()
        }
    }

    // MARK: Helpers

    private static func workoutItems(on day: Date, in plan: Plan, calendar: Calendar) -> [PlannedActivity] {
        plan.items
            .filter { $0.kind == .workout && calendar.isDate($0.date, inSameDayAs: day) }
            .sorted { $0.date < $1.date }
    }

    private static func isCoachReason(_ reason: String?) -> Bool {
        guard let reason else { return false }
        return reason.hasPrefix("From ") || reason.hasPrefix("Changed by ")
    }

    private static func markFutureUserEdit(_ plan: Plan, now: Date, calendar: Calendar) {
        if plan.weekStart > calendar.startOfDay(for: now), plan.designedBy != ProgramDesigner.Source.model.rawValue {
            plan.designedBy = userDesigned
        }
    }

    private static func shortWeekday(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }

    private static func wideWeekday(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }
}
