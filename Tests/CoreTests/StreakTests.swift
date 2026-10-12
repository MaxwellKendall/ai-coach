import Foundation
import Testing
@testable import AICoach

private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}

private func date(_ month: Int, _ day: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))! }

/// FIT-121: weeks in a row with every planned session done. The program starts Monday Aug 10; its weeks run Sunday
/// to Saturday, with sessions planned Monday and Wednesday.
struct StreakTests {
    let start = date(8, 10)
    /// Mon and Wed of weeks 1–3, all done.
    let past = [date(8, 10), date(8, 12), date(8, 17), date(8, 19), date(8, 24), date(8, 26)]
    let thisWeek = [date(8, 31), date(9, 2)]

    private func status(done: [Date], planned: [Date]? = nil, today: Date) -> Streak.Status {
        Streak.status(since: start, plannedDays: planned ?? past + thisWeek, workoutDays: done, today: today, calendar: calendar)
    }

    @Test func fullWeeksCountAndThisWeekJoinsWhenItsDone() {
        let midweek = status(done: past + [date(8, 31)], today: date(9, 2))
        #expect(midweek == Streak.Status(weeks: 3, thisWeek: .onTrack))
        #expect(Streak.line(midweek, today: date(9, 2), calendar: calendar) == "3 weeks in a row")
        let done = status(done: past + thisWeek, today: date(9, 2))
        #expect(done == Streak.Status(weeks: 4, thisWeek: .full))
        #expect(Streak.line(done, calendar: calendar) == "4 weeks in a row")
    }

    @Test func aMissedSessionCanBeMadeUpBeforeTheWeekEnds() {
        let thursday = status(done: past + [date(8, 31)], today: date(9, 3))
        #expect(thursday.weeks == 3)
        #expect(Streak.line(thursday, today: date(9, 3), calendar: calendar)
                == "Do Wednesday’s session by Saturday to make it 4 weeks in a row")
        let saturday = status(done: past + [date(8, 31)], today: date(9, 5))
        #expect(Streak.line(saturday, today: date(9, 5), calendar: calendar) == "Do Wednesday’s session today to make it 4 weeks in a row")
        // Made up on Friday: the week is full.
        #expect(status(done: past + [date(8, 31), date(9, 4)], today: date(9, 5)) == Streak.Status(weeks: 4, thisWeek: .full))
    }

    @Test func tooManyMissedEndsIt() {
        // Three planned this week, none done by Saturday: one day can't make up three.
        let planned = past + [date(8, 31), date(9, 2), date(9, 4)]
        let late = status(done: past, planned: planned, today: date(9, 5))
        #expect(late.thisWeek == .broken)
        #expect(Streak.line(late, calendar: calendar) == nil)
    }

    @Test func aMissedWeekStartsOverAndAnEmptyOneDoesnt() {
        // Week 2 missed Wednesday: only week 3 counts.
        let missed = past.filter { $0 != date(8, 19) }
        #expect(status(done: missed, today: date(8, 31)).weeks == 1)
        #expect(Streak.line(status(done: missed, today: date(8, 31)), calendar: calendar) == nil)
        // Week 2 had nothing planned: weeks 1 and 3 are 2 in a row.
        let gap = past.filter { $0 != date(8, 17) && $0 != date(8, 19) }
        #expect(status(done: gap, planned: gap, today: date(8, 31)).weeks == 2)
    }

    @Test func oneWeekIsntShownButMakingItTwoIs() {
        let first = [date(8, 10), date(8, 12), date(8, 17)]
        let planned = first + [date(8, 19)]
        let tuesday = Streak.status(since: start, plannedDays: planned, workoutDays: first, today: date(8, 18), calendar: calendar)
        #expect(tuesday == Streak.Status(weeks: 1, thisWeek: .onTrack))
        #expect(Streak.line(tuesday, today: date(8, 18), calendar: calendar) == nil)
        let thursday = Streak.status(since: start, plannedDays: planned, workoutDays: first, today: date(8, 20), calendar: calendar)
        #expect(Streak.line(thursday, today: date(8, 20), calendar: calendar) == "Do Wednesday’s session by Saturday to make it 2 weeks in a row")
    }
}
