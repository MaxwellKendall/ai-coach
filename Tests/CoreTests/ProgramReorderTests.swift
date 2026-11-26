import Foundation
import SwiftData
import Testing
@testable import AICoach

private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}

/// 2026-11-15 is a Sunday; 2026-11-16 Mon … 2026-11-21 Sat (matches the TKL-745 week).
private func day(_ offset: Int, hour: Int = 7, minute: Int = 0, second: Int = 0) -> Date {
    let base = calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: hour, minute: minute, second: second))!
    return calendar.date(byAdding: .day, value: offset, to: base)!
}

private func startOfDay(_ offset: Int) -> Date {
    calendar.startOfDay(for: day(offset))
}

/// TKL-745: reordering workouts, making rest days, and copying workouts on the Program week card.
@MainActor
struct ProgramReorderTests {
    private let container = try! AppSchema.container(inMemory: true)

    private func seededPlan() throws -> (context: ModelContext, plan: Plan, templates: [String: Template]) {
        let context = container.mainContext
        try Seeder.seed(context)
        context.insert(Profile(age: 34, weightLb: 185))
        let all = try context.fetch(FetchDescriptor<Template>())
        let bySlug = Dictionary(all.map { ($0.slug, $0) }, uniquingKeysWith: { a, _ in a })
        let plan = Plan(weekContaining: day(0), calendar: calendar, now: day(0))
        context.insert(plan)

        let squat = try #require(bySlug["back-squat"])
        let bench = try #require(bySlug["bench-press"])
        let deadlift = try #require(bySlug["deadlift"])
        let row = try #require(bySlug["barbell-row"])

        let items: [PlannedActivity] = [
            // Mon (offset 1): Squat + Row
            PlannedActivity(kind: .workout, date: day(1, hour: 7, second: 0), slot: "Lower A", templateRef: squat.id,
                            targets: [Measurement(metric: "sets", value: 3, unit: "sets"), Measurement(metric: "reps", value: 5, unit: "reps"),
                                      Measurement(metric: "load_lb", value: 225, unit: "lb")], main: true),
            PlannedActivity(kind: .workout, date: day(1, hour: 7, second: 1), slot: "Lower A", templateRef: row.id,
                            targets: [Measurement(metric: "sets", value: 3, unit: "sets"), Measurement(metric: "reps", value: 8, unit: "reps")]),
            // Tue (offset 2): Bench (with sessionNote and group)
            {
                let item = PlannedActivity(kind: .workout, date: day(2, hour: 7, second: 0), slot: "Upper A", templateRef: bench.id,
                                           targets: [Measurement(metric: "sets", value: 4, unit: "sets"), Measurement(metric: "reps", value: 6, unit: "reps"),
                                                     Measurement(metric: "load_lb", value: 165, unit: "lb")],
                                           note: "pause on chest", group: 1, main: true)
                item.sessionNote = "Keep elbows tucked"
                return item
            }(),
            // Thu (offset 4): Deadlift
            PlannedActivity(kind: .workout, date: day(4, hour: 7, second: 0), slot: "Lower B", templateRef: deadlift.id,
                            targets: [Measurement(metric: "sets", value: 3, unit: "sets"), Measurement(metric: "reps", value: 5, unit: "reps"),
                                      Measurement(metric: "load_lb", value: 275, unit: "lb")], main: true),
            // Non-workout kitchen item on Tue (must never be moved or deleted by workout edits)
            PlannedActivity(kind: .cook, date: day(2, hour: 17, second: 0), slot: "Dinner",
                            targets: [Measurement(metric: "duration_h", value: 1, unit: "h")]),
        ]
        plan.items = items
        try context.save()
        return (context, plan, bySlug)
    }

    @Test func weekSlotsCoverSundayThroughSaturdayWithStates() {
        let workouts = [
            Planner.SketchDay(PlannedWorkout(date: day(1), session: "Lower A", exercise: "back-squat", targets: []), names: ["back-squat": "Back Squat"]),
            Planner.SketchDay(PlannedWorkout(date: day(2), session: "Upper A", exercise: "bench-press", targets: []), names: ["bench-press": "Bench Press"]),
            Planner.SketchDay(PlannedWorkout(date: day(4), session: "Lower B", exercise: "deadlift", targets: []), names: ["deadlift": "Deadlift"]),
        ]
        // Today is Tue (offset 2); Sun logged nothing, Mon missed, Tue done, Wed rest, Thu workout.
        let slots = ProgramWeekEditor.weekSlots(
            weekStart: startOfDay(0),
            workouts: workouts,
            loggedDays: [startOfDay(2)],
            today: day(2, hour: 10),
            calendar: calendar
        )
        #expect(slots.count == 7)
        #expect(slots.map(\.date) == (0..<7).map(startOfDay))

        // Sun: past rest day -> not editable, not missed
        #expect(slots[0].workout == nil && !slots[0].done && !slots[0].missed && !slots[0].editable)
        // Mon: past workout not logged -> missed, not editable
        #expect(slots[1].workout != nil && !slots[1].done && slots[1].missed && !slots[1].editable)
        // Tue: today, logged -> done, not editable
        #expect(slots[2].workout != nil && slots[2].done && !slots[2].missed && !slots[2].editable)
        // Wed: future rest day -> editable
        #expect(slots[3].workout == nil && !slots[3].done && !slots[3].missed && slots[3].editable)
        // Thu: future workout -> editable
        #expect(slots[4].workout != nil && !slots[4].done && !slots[4].missed && slots[4].editable)
    }

    @Test func dragPayloadRoundTripsAndRejectsOtherWeeks() {
        let week = startOfDay(0)
        let otherWeek = calendar.date(byAdding: .day, value: 7, to: week)!
        let payload = ProgramWeekEditor.dragPayload(weekStart: week, day: startOfDay(2), calendar: calendar)
        #expect(ProgramWeekEditor.parseDragPayload(payload, expectedWeekStart: week, calendar: calendar) == startOfDay(2))
        #expect(ProgramWeekEditor.parseDragPayload(payload, expectedWeekStart: otherWeek, calendar: calendar) == nil)
        #expect(ProgramWeekEditor.parseDragPayload("random-text", expectedWeekStart: week, calendar: calendar) == nil)
    }

    @Test func movingWorkoutToRestDayShiftsExercisesPreservesOrderAndSupportsUndo() throws {
        let (context, plan, templates) = try seededPlan()
        // Today is Mon (offset 1): move Mon (Squat + Row) -> Wed (offset 3, rest day)
        let outcome = try #require(try ProgramWeekEditor.moveOrSwap(
            from: startOfDay(1), to: startOfDay(3), in: plan, loggedDays: [], coached: false,
            context: context, now: day(1, hour: 8), calendar: calendar
        ))
        #expect(outcome.message.contains("Mon") && outcome.message.contains("Wed"))

        let monAfter = plan.items.filter { $0.kind == .workout && calendar.isDate($0.date, inSameDayAs: day(1)) }
        let wedAfter = plan.items.filter { $0.kind == .workout && calendar.isDate($0.date, inSameDayAs: day(3)) }.sorted { $0.date < $1.date }
        #expect(monAfter.isEmpty)
        #expect(wedAfter.count == 2)
        #expect(wedAfter.map(\.templateRef) == [templates["back-squat"]?.id, templates["barbell-row"]?.id])
        #expect(wedAfter.allSatisfy(\.pinned))

        // Undo puts Squat + Row back on Mon and clears Wed
        outcome.undo()
        let monUndo = plan.items.filter { $0.kind == .workout && calendar.isDate($0.date, inSameDayAs: day(1)) }.sorted { $0.date < $1.date }
        let wedUndo = plan.items.filter { $0.kind == .workout && calendar.isDate($0.date, inSameDayAs: day(3)) }
        #expect(wedUndo.isEmpty)
        #expect(monUndo.map(\.templateRef) == [templates["back-squat"]?.id, templates["barbell-row"]?.id])
        #expect(monUndo.allSatisfy { !$0.pinned })
    }

    @Test func swappingTwoWorkoutDaysExchangesBothSessionsAndSupportsUndo() throws {
        let (context, plan, templates) = try seededPlan()
        // Swap Tue (Bench) and Thu (Deadlift), today is Tue
        let outcome = try #require(try ProgramWeekEditor.moveOrSwap(
            from: startOfDay(2), to: startOfDay(4), in: plan, loggedDays: [], coached: false,
            context: context, now: day(2, hour: 8), calendar: calendar
        ))
        #expect(outcome.message.contains("Swapped"))

        let tue = plan.items.filter { $0.kind == .workout && calendar.isDate($0.date, inSameDayAs: day(2)) }
        let thu = plan.items.filter { $0.kind == .workout && calendar.isDate($0.date, inSameDayAs: day(4)) }
        let tueCook = plan.items.filter { $0.kind == .cook && calendar.isDate($0.date, inSameDayAs: day(2)) }
        #expect(tue.map(\.templateRef) == [templates["deadlift"]?.id])
        #expect(thu.map(\.templateRef) == [templates["bench-press"]?.id])
        #expect(thu.first?.sessionNote == "Keep elbows tucked")
        #expect(tueCook.count == 1) // Kitchen item stayed on Tue

        outcome.undo()
        let tueRestored = plan.items.filter { $0.kind == .workout && calendar.isDate($0.date, inSameDayAs: day(2)) }
        let thuRestored = plan.items.filter { $0.kind == .workout && calendar.isDate($0.date, inSameDayAs: day(4)) }
        #expect(tueRestored.map(\.templateRef) == [templates["bench-press"]?.id])
        #expect(thuRestored.map(\.templateRef) == [templates["deadlift"]?.id])
    }

    @Test func lockedDaysCannotBeMovedOrDroppedOnto() throws {
        let (context, plan, _) = try seededPlan()
        // Today is Tue (offset 2), and Tue is logged
        let logged: Set<Date> = [startOfDay(2)]
        // Past day (Mon) cannot move
        #expect(try ProgramWeekEditor.moveOrSwap(from: startOfDay(1), to: startOfDay(3), in: plan, loggedDays: logged, coached: false, context: context, now: day(2, hour: 10), calendar: calendar) == nil)
        // Done day (Tue) cannot move
        #expect(try ProgramWeekEditor.moveOrSwap(from: startOfDay(2), to: startOfDay(3), in: plan, loggedDays: logged, coached: false, context: context, now: day(2, hour: 10), calendar: calendar) == nil)
        // Future day (Thu) cannot drop onto past day (Mon) or done day (Tue)
        #expect(try ProgramWeekEditor.moveOrSwap(from: startOfDay(4), to: startOfDay(1), in: plan, loggedDays: logged, coached: false, context: context, now: day(2, hour: 10), calendar: calendar) == nil)
        #expect(try ProgramWeekEditor.moveOrSwap(from: startOfDay(4), to: startOfDay(2), in: plan, loggedDays: logged, coached: false, context: context, now: day(2, hour: 10), calendar: calendar) == nil)
        // Same day is a no-op
        #expect(try ProgramWeekEditor.moveOrSwap(from: startOfDay(4), to: startOfDay(4), in: plan, loggedDays: logged, coached: false, context: context, now: day(2, hour: 10), calendar: calendar) == nil)
        // Rest day (Wed) has nothing to drag
        #expect(try ProgramWeekEditor.moveOrSwap(from: startOfDay(3), to: startOfDay(5), in: plan, loggedDays: logged, coached: false, context: context, now: day(2, hour: 10), calendar: calendar) == nil)
    }

    @Test func markingDayAsRestClearsWorkoutsLeavesKitchenAndSupportsUndo() throws {
        let (context, plan, templates) = try seededPlan()
        let originalID = try #require(plan.items.first { $0.kind == .workout && calendar.isDate($0.date, inSameDayAs: day(2)) }?.id)

        let outcome = try #require(try ProgramWeekEditor.makeRestDay(
            startOfDay(2), in: plan, loggedDays: [], context: context, now: day(2, hour: 8), calendar: calendar
        ))
        #expect(outcome.message.contains("rest day"))

        #expect(plan.items.filter { $0.kind == .workout && calendar.isDate($0.date, inSameDayAs: day(2)) }.isEmpty)
        // Kitchen item stays untouched
        #expect(plan.items.filter { $0.kind == .cook && calendar.isDate($0.date, inSameDayAs: day(2)) }.count == 1)
        // Calling makeRestDay again on an already-rest day returns nil
        #expect(try ProgramWeekEditor.makeRestDay(startOfDay(2), in: plan, loggedDays: [], context: context, now: day(2, hour: 8), calendar: calendar) == nil)

        outcome.undo()
        let restored = plan.items.filter { $0.kind == .workout && calendar.isDate($0.date, inSameDayAs: day(2)) }
        #expect(restored.count == 1)
        #expect(restored.first?.id == originalID)
        #expect(restored.first?.templateRef == templates["bench-press"]?.id)
        #expect(restored.first?.sessionNote == "Keep elbows tucked")
        #expect(restored.first?.note == "pause on chest")
        #expect(restored.first?.group == 1)
    }

    @Test func copyingWorkoutCreatesFreshRowsAndAllowsCopyingFromPastMissedDay() throws {
        let (context, plan, templates) = try seededPlan()
        // Today is Tue: Mon was missed, copy Mon (Squat + Row) -> Wed (rest day)
        let outcome = try #require(try ProgramWeekEditor.copyWorkout(
            from: startOfDay(1), to: startOfDay(3), in: plan, loggedDays: [], coached: false,
            context: context, now: day(2, hour: 8), calendar: calendar
        ))
        #expect(outcome.message.contains("Copied"))

        let mon = plan.items.filter { $0.kind == .workout && calendar.isDate($0.date, inSameDayAs: day(1)) }.sorted { $0.date < $1.date }
        let wed = plan.items.filter { $0.kind == .workout && calendar.isDate($0.date, inSameDayAs: day(3)) }.sorted { $0.date < $1.date }
        #expect(mon.count == 2)
        #expect(wed.count == 2)
        #expect(wed.map(\.templateRef) == [templates["back-squat"]?.id, templates["barbell-row"]?.id])
        #expect(Set(mon.map(\.id)).isDisjoint(with: Set(wed.map(\.id))))

        outcome.undo()
        #expect(plan.items.filter { $0.kind == .workout && calendar.isDate($0.date, inSameDayAs: day(3)) }.isEmpty)
        #expect(plan.items.filter { $0.kind == .workout && calendar.isDate($0.date, inSameDayAs: day(1)) }.count == 2)
    }

    @Test func editingNextWeekSurvivesEnsureWeekWhenNextWeekStarts() throws {
        let context = container.mainContext
        try Seeder.seed(context)
        context.insert(Profile(age: 34, weightLb: 185))
        let nextSunday = day(7)
        let nextPlan = try #require(try Planner.generate(weekOf: nextSunday, in: context, calendar: calendar))
        nextPlan.updatedAt = day(2)
        let workoutDays = Set(nextPlan.items.filter { $0.kind == .workout }.map { calendar.startOfDay(for: $0.date) }).sorted()
        let firstDay = try #require(workoutDays.first)

        // User marks Next week's first workout day as a rest day on Tuesday before Next week begins
        _ = try #require(try ProgramWeekEditor.makeRestDay(
            firstDay, in: nextPlan, loggedDays: [], context: context, now: day(2, hour: 9), calendar: calendar
        ))
        // When Next week starts on Sunday, ensureWeek must NOT put a workout back on that rest day
        try Planner.ensureWeek(of: day(7, hour: 8), in: context, calendar: calendar)
        let stillRest = nextPlan.items.filter { $0.kind == .workout && calendar.isDate($0.date, inSameDayAs: firstDay) }
        #expect(stillRest.isEmpty)
    }

    @Test func reorderingUpdatesSyncUnitsCleanly() throws {
        let (context, plan, _) = try seededPlan()
        _ = try #require(try ProgramWeekEditor.moveOrSwap(
            from: startOfDay(1), to: startOfDay(3), in: plan, loggedDays: [], coached: false,
            context: context, now: day(1, hour: 8), calendar: calendar
        ))
        let units = try SyncUnits.all(in: context, calendar: calendar)
        #expect(units["plan#2026-11-16"] == nil) // Mon cleared
        #expect(units["plan#2026-11-18"] != nil) // Wed now has Squat + Row
    }

    @Test func ensurePlanDoesNotRegenerateAfterAllWorkoutsAreCleared() throws {
        let (context, plan, _) = try seededPlan()
        for offset in [1, 2, 4] {
            _ = try #require(try ProgramWeekEditor.makeRestDay(
                startOfDay(offset), in: plan, loggedDays: [], context: context, now: day(0, hour: 8), calendar: calendar
            ))
        }
        #expect(plan.items.filter { $0.kind == .workout }.isEmpty)
        let fetched = try ProgramWeekEditor.ensurePlan(weekOf: day(0), plansItself: true, in: context, calendar: calendar)
        #expect(fetched.id == plan.id)
        #expect(fetched.items.filter { $0.kind == .workout }.isEmpty)
    }

    @Test func coachedPlanPreservesCoachAdjustedReasonAndDoesNotPin() throws {
        let (context, plan, _) = try seededPlan()
        for item in plan.items where item.kind == .workout {
            item.adjustedReason = "From Dana"
        }
        try context.save()
        _ = try #require(try ProgramWeekEditor.moveOrSwap(
            from: startOfDay(2), to: startOfDay(3), in: plan, loggedDays: [], coached: true,
            context: context, now: day(2, hour: 8), calendar: calendar
        ))
        let moved = plan.items.filter { $0.kind == .workout && calendar.isDate($0.date, inSameDayAs: day(3)) }
        #expect(moved.count == 1)
        #expect(moved.first?.adjustedReason == "From Dana")
        #expect(moved.first?.pinned == false)
        #expect(Planner.isCoached(plan))
    }
}
