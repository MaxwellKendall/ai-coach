import Foundation
import SwiftData
import Testing
@testable import AICoach

/// FIT-344: the weekly check-in: one `checkin` row a week, due on the coach's day (Sunday until it's set), with a
/// weekly reminder that day; the coach's day travels as the `checkin` unit. Flags are in TriageTests.
@MainActor
struct WeeklyCheckInTests {
    private let calendar = Calendar.current
    private func date(_ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }
    // Sunday Nov 8 to Saturday Nov 14, 2026.
    private let values: [String: Double] = ["energy_1to5": 4, "stress_1to5": 2, "soreness_1to5": 3, "adherence_1to5": 5]

    @Test func itsDueOnTheCoachsDayUntilSaturday() {
        // Wednesday (day 2) in the week of Tuesday Nov 10.
        #expect(WeeklyCheckIn.due(2, weekOf: date(10)) == calendar.startOfDay(for: date(11)))
        #expect(!WeeklyCheckIn.isDue(2, today: date(10), done: false))
        #expect(WeeklyCheckIn.isDue(2, today: date(11), done: false))
        #expect(WeeklyCheckIn.isDue(2, today: date(14), done: false))
        #expect(!WeeklyCheckIn.isDue(2, today: date(14), done: true))
        // Sunday, the default, is the week's first day: due all week.
        #expect(WeeklyCheckIn.due(WeeklyCheckIn.defaultDay, weekOf: date(10)) == calendar.startOfDay(for: date(8)))
        #expect(WeeklyCheckIn.isDue(WeeklyCheckIn.defaultDay, today: date(8), done: false))
    }

    @Test func theReminderIsWeeklyOnThatDayAtNine() {
        #expect(WeeklyCheckIn.reminder(WeeklyCheckIn.defaultDay) == DateComponents(hour: 9, minute: 0, weekday: 1))
        #expect(WeeklyCheckIn.reminder(0) == DateComponents(hour: 9, minute: 0, weekday: 2))
        #expect(WeeklyCheckIn.reminder(5) == DateComponents(hour: 9, minute: 0, weekday: 7))
    }

    @Test func theAnswersAreItsNoteAndReadBack() {
        let note = WeeklyCheckIn.note(wentWell: " Every session done ", wasHard: "Sleep,\nwork trip")
        #expect(note == "What went well: Every session done\nWhat was hard: Sleep, work trip")
        let answers = WeeklyCheckIn.answers(note)
        #expect(answers.wentWell == "Every session done" && answers.wasHard == "Sleep, work trip")
        #expect(WeeklyCheckIn.note(wentWell: "", wasHard: "Knees") == "What was hard: Knees")
        #expect(WeeklyCheckIn.summary(values) == "Energy 4 · Stress 2 · Soreness 3 · Plan 5")
    }

    @Test func itsOneRowAWeekInThatDaysUnit() throws {
        let context = ModelContext(try AppSchema.container(inMemory: true))
        try WeeklyCheckIn.save(values, wentWell: "PR on squat", wasHard: "", on: date(10), in: context, now: date(10, hour: 18))
        var rows = try WeeklyCheckIn.entries(weekOf: date(10), in: context)
        #expect(rows.count == 1 && rows[0].kind == .checkin)
        #expect(rows[0].measurements.map(\.metric) == WeeklyCheckIn.ratings.map(\.metric))
        #expect(rows[0].measurements.allSatisfy { $0.unit == "/5" })
        let unit = try #require(try SyncUnits.all(in: context)["log#2026-11-10"])
        #expect(try SyncUnits.decode([SyncUnits.LogRow].self, unit).first?.note == "What went well: PR on squat")

        // Changed later that week: the same row, still one.
        var lower = values
        lower["energy_1to5"] = 2
        try WeeklyCheckIn.save(lower, wentWell: "PR on squat", wasHard: "Long days", on: date(12), in: context, now: date(12, hour: 8))
        rows = try WeeklyCheckIn.entries(weekOf: date(12), in: context)
        #expect(rows.count == 1 && rows[0].measurements.first?.value == 2 && rows[0].note.hasSuffix("What was hard: Long days"))
        // Next week's is its own.
        try WeeklyCheckIn.save(values, wentWell: "", wasHard: "", on: date(15), in: context, now: date(15, hour: 9))
        #expect(try WeeklyCheckIn.entries(weekOf: date(15), in: context).count == 1)
        #expect(try WeeklyCheckIn.entries(weekOf: date(10), in: context).count == 1)
    }

    @Test func theCoachsDayIsACheckinUnitBothWays() throws {
        let context = ModelContext(try AppSchema.container(inMemory: true))
        let profile = Profile(age: 32, weightLb: 178)
        context.insert(profile)
        try context.save()
        #expect(try SyncUnits.all(in: context)["checkin"] == nil)
        try SyncUnits.apply("checkin", body: #"{"day":2}"#, in: context)
        #expect(profile.checkInDay == 2)
        #expect(try SyncUnits.all(in: context)["checkin"] == #"{"day":2}"#)
        // The profile unit doesn't carry it, so the coach can write it and not the profile.
        #expect(try SyncUnits.all(in: context)["profile"]?.contains("checkIn") == false)
        try SyncUnits.apply("checkin", body: nil, in: context)
        #expect(profile.checkInDay == nil)
    }

    @Test func theCoachReadsTheirCheckInsAndDay() throws {
        let row = SyncUnits.LogRow(id: UUID(), kind: .checkin, at: date(10), measurements: values.map { Measurement(metric: $0.key, value: $0.value, unit: "/5") },
                                   note: "What went well: PR")
        let units = ["log#2026-11-10": SyncUnits.encode([row]), "checkin": #"{"day":0}"#]
        #expect(ClientProgress.weekly(units) == [ClientProgress.Weekly(date: date(10), values: values, note: "What went well: PR")])
        #expect(ClientProgress.checkInDay(units) == 0)
        #expect(ClientProgress.checkInDay([:]) == WeeklyCheckIn.defaultDay)
        // It's news on the roster, and the client's words on that day.
        #expect(Roster.unread(units, comments: [], from: "ann", since: date(9)) == 1)
        #expect(ClientDay.notes([row]) == ["What went well: PR"])
    }
}
