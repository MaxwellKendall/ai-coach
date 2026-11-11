import Foundation
import Testing
import SwiftData
@testable import AICoach

private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}

private func date(_ month: Int, _ day: Int, hour: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
}

/// FIT-424: a week is always there, and what was seen ahead is what comes.
@MainActor
struct WeekKeepingTests {
    /// The context doesn't retain its container, so the test keeps it.
    private let container = try! AppSchema.container(inMemory: true)

    private func store() throws -> ModelContext {
        let context = container.mainContext
        try Seeder.seed(context)
        context.insert(Profile(age: 36, weightLb: 200))
        return context
    }

    /// Each planned session on `day`, logged that evening as planned.
    private func logSessions(on day: Date, in context: ModelContext) throws {
        let items = try Planner.plan(weekOf: day, in: context, calendar: calendar)?.items
            .filter { $0.kind == .workout && calendar.isDate($0.date, inSameDayAs: day) } ?? []
        for item in items {
            context.insert(LogEntry(kind: .workout, timestamp: calendar.date(byAdding: .hour, value: 18, to: day)!,
                                    plannedRef: item.id, templateRef: item.templateRef, measurements: item.targets))
        }
        try context.save()
    }

    /// Four weeks with the clock moving a day at a time: every day has its planned week, and next week is saved once
    /// this week's last session is logged, before it starts.
    @Test func everyDayHasItsWeekForFourWeeks() throws {
        let context = try store()
        let start = date(10, 4)
        for offset in 0..<28 {
            let day = calendar.date(byAdding: .day, value: offset, to: start)!
            try Planner.keepWeeks(now: calendar.date(byAdding: .hour, value: 8, to: day)!, in: context, calendar: calendar)
            #expect(try Planner.plan(weekOf: day, in: context, calendar: calendar) != nil, "no week on \(day)")
            try logSessions(on: day, in: context)
            try Planner.keepWeeks(now: calendar.date(byAdding: .hour, value: 19, to: day)!, in: context, calendar: calendar)
            // The week's last session logged (Saturday at the latest): next week is saved.
            let next = calendar.date(byAdding: .day, value: 7, to: day)!
            if try Planner.lastSessionLogged(weekOf: day, in: context, calendar: calendar) {
                #expect(try Planner.plan(weekOf: next, in: context, calendar: calendar) != nil, "next week not saved on \(day)")
            }
        }
        #expect(try context.fetchCount(FetchDescriptor<Plan>()) == 5)
    }

    /// Next week as Program shows it on Saturday is the week Today shows on Sunday; a row that changed says why.
    @Test func whatWasSeenOnSaturdayIsWhatComesOnSunday() throws {
        let context = try store()
        let templates = try context.fetch(FetchDescriptor<Template>())
        for offset in 0..<7 {
            let day = calendar.date(byAdding: .day, value: offset, to: date(10, 4))!
            try Planner.keepWeeks(now: calendar.date(byAdding: .hour, value: 8, to: day)!, in: context, calendar: calendar)
            try logSessions(on: day, in: context)
            try Planner.keepWeeks(now: calendar.date(byAdding: .hour, value: 19, to: day)!, in: context, calendar: calendar)
        }
        let next = try #require(try Planner.plan(weekOf: date(10, 11), in: context, calendar: calendar))
        let seen = Planner.workouts(next, templates: templates)
        #expect(!seen.isEmpty)

        try Planner.keepWeeks(now: date(10, 11, hour: 8), in: context, calendar: calendar)
        let came = Planner.workouts(next, templates: templates)
        #expect(came.count == seen.count)
        for row in came where !seen.contains(row) {
            #expect(row.adjustedReason?.contains(" after ") == true, "\(row.exercise) changed without saying why")
        }
        // Brought up to date once: a second look the same day changes nothing.
        try Planner.keepWeeks(now: date(10, 11, hour: 12), in: context, calendar: calendar)
        #expect(Planner.workouts(next, templates: templates) == came)
    }

    /// Nothing logged: next week isn't saved ahead, and is planned on its first day.
    @Test func aWeekWithItsLastSessionMissedIsPlannedWhenItStarts() throws {
        let context = try store()
        try Planner.keepWeeks(now: date(10, 4, hour: 8), in: context, calendar: calendar)
        try Planner.keepWeeks(now: date(10, 10, hour: 20), in: context, calendar: calendar)
        #expect(try Planner.plan(weekOf: date(10, 11), in: context, calendar: calendar) == nil)
        try Planner.keepWeeks(now: date(10, 11, hour: 8), in: context, calendar: calendar)
        #expect(try Planner.plan(weekOf: date(10, 11), in: context, calendar: calendar) != nil)
    }

    /// FIT-426: a week the AI designed ahead, after this week's last session, is the week that comes; code doesn't
    /// plan over it when it starts.
    @Test func aWeekTheAIDesignedAheadIsTheWeekThatComes() throws {
        let context = try store()
        let templates = try context.fetch(FetchDescriptor<Template>())
        let next = try #require(try Planner.generate(weekOf: date(10, 11), in: context, calendar: calendar))
        next.updatedAt = date(10, 9)
        next.designedBy = ProgramDesigner.Source.model.rawValue
        for item in next.items where item.kind == .workout { item.adjustedReason = "Bench held at 185: two sets short Tuesday" }
        let designed = Planner.workouts(next, templates: templates)
        try Planner.keepWeeks(now: date(10, 11, hour: 8), in: context, calendar: calendar)
        #expect(Planner.workouts(next, templates: templates) == designed)
        #expect(next.updatedAt >= next.weekStart)
    }

    /// FIT-426: the designer is told what they wrote in the weeks before and so far, most recent first, once each.
    @Test func notesAreToldMostRecentFirst() throws {
        let context = try store()
        let templates = try context.fetch(FetchDescriptor<Template>())
        let squat = try #require(templates.first { $0.slug == "back-squat" })
        let entries = [
            LogEntry(kind: .workout, timestamp: date(10, 1, hour: 18), templateRef: squat.id, note: "knee sore at the bottom"),
            LogEntry(kind: .workout, timestamp: date(10, 1, hour: 18), templateRef: squat.id, note: "knee sore at the bottom"),
            LogEntry(kind: .checkin, timestamp: date(10, 3, hour: 9), note: "travelling Thursday"),
            LogEntry(kind: .workout, timestamp: date(9, 1, hour: 18), templateRef: squat.id, note: "too long ago"),
        ]
        let notes = Planner.notes(entries, templates: templates, before: date(10, 11), now: date(10, 6), calendar: calendar)
        #expect(notes.count == 2)
        #expect(notes[0].hasSuffix("check-in: travelling Thursday"))
        #expect(notes[1].hasSuffix("Back Squat: knee sore at the bottom"))
    }

    /// FIT-427: a coach's week is never planned over, and once coaching ends the app plans again from the next week.
    @Test func endingCoachingHandsPlanningBackTheFollowingWeek() throws {
        let context = try store()
        let templates = try context.fetch(FetchDescriptor<Template>())
        let coached = try #require(try Planner.generate(weekOf: date(10, 4), in: context, calendar: calendar))
        for item in coached.items where item.kind == .workout { item.adjustedReason = "From Sam" }
        coached.updatedAt = date(10, 1)
        try context.save()
        let written = Planner.workouts(coached, templates: templates)

        // Coaching ended on Wednesday: this week stays the coach's.
        try Planner.keepWeeks(now: date(10, 7, hour: 9), in: context, calendar: calendar)
        #expect(Planner.workouts(coached, templates: templates) == written)
        #expect(try Planner.plan(weekOf: date(10, 11), in: context, calendar: calendar) == nil)
        // The next week is the app's again.
        try Planner.keepWeeks(now: date(10, 11, hour: 8), in: context, calendar: calendar)
        let next = try #require(try Planner.plan(weekOf: date(10, 11), in: context, calendar: calendar))
        #expect(next.items.contains { $0.kind == .workout } && !Planner.isCoached(next))
        #expect(Planner.workouts(coached, templates: templates) == written)
    }

    @Test func eachChangeSaysHowAndSinceWhen() {
        let monday = date(10, 12, hour: 17)
        func row(_ exercise: String, _ load: Double) -> PlannedWorkout {
            PlannedWorkout(date: monday, session: "A", exercise: exercise,
                           targets: [Measurement(metric: "reps", value: 5, unit: "reps"), Measurement(metric: "load_lb", value: load, unit: "lb")])
        }
        let seen = [row("back_squat", 185), row("bench_press", 135)]
        let now = [row("back_squat", 190), row("bench_press", 135), row("barbell_row", 95)]
        let names = ["back_squat": "Squat", "bench_press": "Bench press", "barbell_row": "Row"]
        let thursday = date(10, 8, hour: 18)
        let week = Planner.changes(from: seen, to: now, names: names, after: thursday, calendar: calendar)
        #expect(week[0].adjustedReason == "Squat up 5 lb after Thursday")
        #expect(week[1] == seen[1])
        #expect(week[2].adjustedReason == "Row added after Thursday")
        #expect(Coach.plan(deload: false, reasons: [week[0].adjustedReason!]) == "Squat up 5 lb after Thursday.")
    }
}
