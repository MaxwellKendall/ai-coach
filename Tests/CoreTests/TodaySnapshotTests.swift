import Foundation
import SwiftData
import Testing
@testable import AICoach

/// TKL-802: the "today" snapshot the app writes for the widget, and what the widget shows from it on any day, midnight
/// rollover included, without the app.
struct TodaySnapshotTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    private func day(_ d: Int, hour: Int = 0, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: d, hour: hour, minute: minute))!
    }

    private func october(_ d: Int, hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: d, hour: hour, minute: minute))!
    }

    private func september(_ d: Int, hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: d, hour: hour))!
    }

    private func set(_ reps: Double?, load: Double? = nil, seconds: Double? = nil, warmup: Bool = false) -> SessionPlan.PlannedSet {
        var targets: [AICoach.Measurement] = []
        if let reps { targets.append(AICoach.Measurement(metric: "reps", value: reps, unit: "reps")) }
        if let load { targets.append(AICoach.Measurement(metric: "load_lb", value: load, unit: "lb")) }
        if let seconds { targets.append(AICoach.Measurement(metric: "duration_s", value: seconds, unit: "s")) }
        return SessionPlan.PlannedSet(targets: targets, note: warmup ? TrainingGenerator.warmupNote : "")
    }

    private func block(_ exercise: String, _ sets: [SessionPlan.PlannedSet]) -> SessionPlan.Block {
        SessionPlan.Block(movements: [SessionPlan.Movement(exercise: exercise, sets: sets)])
    }

    private let names = ["back-squat": "Back Squat", "bench-press": "Bench Press", "pull-up": "Pull-up", "plank": "Plank", "row-erg": "Row"]
    private func name(_ slug: String) -> (name: String, short: String) {
        let name = names[slug] ?? slug
        return (name, name == "Back Squat" ? "Squat" : name == "Bench Press" ? "Bench" : name)
    }

    private var session: SessionPlan {
        SessionPlan(blocks: [
            block("row-erg", [set(nil, seconds: 300, warmup: true)]),
            block("back-squat", [set(5, load: 45, warmup: true), set(5, load: 225), set(5, load: 225), set(5, load: 225)]),
            block("bench-press", [set(8, load: 135), set(8, load: 135), set(8, load: 135)]),
            block("pull-up", [set(8), set(8), set(8)]),
            block("plank", [set(nil, seconds: 45), set(nil, seconds: 45), set(nil, seconds: 45)]),
        ])
    }

    // MARK: Builder

    @Test func liftsAreTheWorkingSetsWithoutTheWarmup() {
        let lifts = TodaySnapshot.lifts(session, name: name)
        #expect(lifts.map(\.name) == ["Back Squat", "Bench Press", "Pull-up", "Plank"])
        #expect(lifts.map(\.short) == ["Squat", "Bench", "Pull-up", "Plank"])
        #expect(lifts.map(\.dose) == ["3×5 · 225", "3×8 · 135", "3×8", "3×45s"])
        #expect(lifts.map(\.sets) == [3, 3, 3, 3])
    }

    @Test func theBestSetIsTheHeaviest() {
        let logged = [
            LoggedSet(date: day(17, hour: 18), exercise: "bench-press", measurements: [AICoach.Measurement(metric: "load_lb", value: 135, unit: "lb"), AICoach.Measurement(metric: "reps", value: 8, unit: "reps")]),
            LoggedSet(date: day(17, hour: 18), exercise: "back-squat", measurements: [AICoach.Measurement(metric: "load_lb", value: 225, unit: "lb"), AICoach.Measurement(metric: "reps", value: 4, unit: "reps")]),
            LoggedSet(date: day(17, hour: 18), exercise: "back-squat", measurements: [AICoach.Measurement(metric: "load_lb", value: 225, unit: "lb"), AICoach.Measurement(metric: "reps", value: 5, unit: "reps")]),
        ]
        #expect(TodaySnapshot.best(logged, name: name) == "Squat 225×5")
        #expect(TodaySnapshot.best([LoggedSet(date: .now, exercise: "pull-up", measurements: [AICoach.Measurement(metric: "reps", value: 8, unit: "reps")])], name: name) == nil)
    }

    @Test func theUsualTimeIsTheMedianOnThatWeekdayOverEightWeeksWithThreeSessions() {
        // Tuesdays: Nov 17 is a Tuesday. Starts on three earlier Tuesdays at 5:50, 6:05 and 6:40 PM; median 6:05 → 6 PM.
        let starts = [day(10, hour: 17, minute: 50), day(3, hour: 18, minute: 5), october(27, hour: 18, minute: 40)]
        #expect(TodaySnapshot.usual(on: day(17), starts: starts, calendar: calendar) == 18 * 60)
        // Two isn't enough, other weekdays don't count, and nine weeks back is too long ago.
        #expect(TodaySnapshot.usual(on: day(17), starts: Array(starts.prefix(2)) + [day(11, hour: 7)], calendar: calendar) == nil)
        #expect(TodaySnapshot.usual(on: day(17), starts: Array(starts.prefix(2)) + [september(15, hour: 18)], calendar: calendar) == nil)
        #expect(TodaySnapshot.clock(18 * 60) == "6 PM")
        #expect(TodaySnapshot.clock(6 * 60 + 30) == "6:30 AM")
    }

    @Test func buildKeepsEachDayAndItsUsualTime() {
        let starts = [day(3, hour: 18), day(10, hour: 18), october(27, hour: 18)]
        let snapshot = TodaySnapshot.build([
            (day(16), .done(title: "Squat, bench", sets: 12, volume: 9450, logged: [], at: day(16, hour: 18, minute: 52))),
            (day(17), .plan(title: "Squat, bench, pull-up + 1 more", session: session, minutes: 55)),
            (day(18), .rest),
        ], name: name, starts: starts, setUp: true, plate: "red", calendar: calendar)
        #expect(snapshot.plate == "red")
        #expect(snapshot.days.count == 3)
        #expect(snapshot.days[0].done == TodaySnapshot.Done(sets: 12, volume: 9450, best: nil, at: day(16, hour: 18, minute: 52)))
        #expect(snapshot.days[1].title == "Squat, bench, pull-up + 1 more")
        #expect(snapshot.days[1].lifts.count == 4)
        #expect(snapshot.days[1].minutes == 55)
        #expect(snapshot.days[1].usual == 18 * 60)
        #expect(snapshot.days[2].title == nil && snapshot.days[2].done == nil)
        // It round-trips through the file the widget reads.
        let data = try! JSONEncoder().encode(snapshot)
        #expect(try! JSONDecoder().decode(TodaySnapshot.self, from: data) == snapshot)
    }

    @Test func theHorizonReachesThePlannedWeeksAheadWithinACap() {
        // Sunday Nov 15. No plan ahead: this week and next.
        #expect(TodaySnapshot.horizon(from: day(15), through: nil, calendar: calendar) == 14)
        #expect(TodaySnapshot.horizon(from: day(15), through: day(20, hour: 7), calendar: calendar) == 14)
        // A workout on Sunday Nov 29 (the review's case: written on Saturday the 21st, opened 8 days later): its whole week.
        #expect(TodaySnapshot.horizon(from: day(15), through: day(29, hour: 7), calendar: calendar) == 21)
        // Months of plan: capped at 12 weeks.
        let march = calendar.date(from: DateComponents(year: 2027, month: 3, day: 1))!
        #expect(TodaySnapshot.horizon(from: day(15), through: march, calendar: calendar) == TodaySnapshot.maxDays)
        #expect(TodaySnapshot.maxDays == 84)
    }

    // MARK: What the widget shows

    /// Sunday Nov 15 to Saturday Nov 28: lifting Mon, Tue, Thu, Sat and next Mon; Monday done.
    private var fortnight: TodaySnapshot {
        let lifts = TodaySnapshot.lifts(session, name: name)
        let days = (15...28).map { d -> TodaySnapshot.Day in
            var day = TodaySnapshot.Day(date: self.day(d))
            if [16, 17, 19, 21, 23].contains(d) {
                day.title = d == 19 ? "Upper B" : "Full body A"
                day.lifts = lifts
                day.minutes = 55
            }
            if d == 16 { day.done = TodaySnapshot.Done(sets: 12, volume: 9450, best: "Squat 225×5", at: self.day(16, hour: 18)) }
            return day
        }
        return TodaySnapshot(setUp: true, plate: "blue", days: days)
    }

    @Test func aWorkoutToday() {
        let content = fortnight.content(on: day(17, hour: 5), calendar: calendar)
        #expect(content.state == .workout)
        #expect(content.day?.title == "Full body A")
        #expect(content.next?.title == "Upper B")
        #expect(content.week.map(\.letter) == ["S", "M", "T", "W", "T", "F", "S"])
        #expect(content.week.map(\.kind) == [.rest, .done, .today, .rest, .planned, .rest, .planned])
        #expect(content.doneThisWeek == 1 && content.plannedThisWeek == 4)
    }

    @Test func doneToday() {
        let content = fortnight.content(on: day(16, hour: 20), calendar: calendar)
        #expect(content.state == .done)
        #expect(content.day?.done?.volume == 9450)
        #expect(content.next?.title == "Full body A")
        #expect(content.week[1] == TodaySnapshot.Dot(letter: "M", kind: .done))
    }

    @Test func aRestDaySaysWhatsNext() {
        let content = fortnight.content(on: day(18, hour: 9), calendar: calendar)
        #expect(content.state == .rest)
        #expect(content.next?.title == "Upper B")
        #expect(content.next?.date == day(19))
    }

    @Test func notSetUpAndNoData() {
        #expect(TodaySnapshot(setUp: false, plate: "blue", days: []).content(on: day(17), calendar: calendar).state == .notSetUp)
        #expect(TodaySnapshot.content(nil, on: day(17), calendar: calendar).state == .noData)
        // A day the snapshot doesn't reach (the app hasn't opened in two weeks) is no data, not a rest day.
        #expect(fortnight.content(on: day(29, hour: 9), calendar: calendar).state == .noData)
    }

    @Test func theTimelineRollsOverAtEachMidnightWithoutTheApp() {
        let snapshot = fortnight
        let dates = snapshot.timeline(from: day(17, hour: 21, minute: 30), calendar: calendar)
        #expect(dates.first == day(17, hour: 21, minute: 30))
        #expect(dates[1] == day(18))
        #expect(dates[2] == day(19))
        #expect(dates.last == day(29))
        // The new week's dots, a week on, from the same snapshot.
        let monday = snapshot.content(on: day(23), calendar: calendar)
        #expect(monday.state == .workout)
        #expect(monday.week[1].kind == .today)
        #expect(monday.week[0].kind == .rest)
        #expect(monday.doneThisWeek == 0 && monday.plannedThisWeek == 1)
        // Past a day planned and not done, its dot is just planned (not done).
        #expect(snapshot.content(on: day(18), calendar: calendar).week[2].kind == .planned)
    }
}

/// TKL-802: the app's side: the store → the file the widget reads, rewritten (and the widget reloaded) only on a change.
@MainActor
struct TodayWidgetTests {
    @Test func theStoreBecomesTodaysSnapshotAndALogMakesItDone() throws {
        let context = ModelContext(try AppSchema.container(inMemory: true))
        let squat = Template(kind: .exercise, name: "Back Squat", slug: "back-squat", attributes: [])
        context.insert(squat)
        let today = Calendar.current.startOfDay(for: .now)
        context.insert(PlannedActivity(kind: .workout, date: today.addingTimeInterval(7 * 3600), slot: "Lower A", templateRef: squat.id,
                                       targets: [AICoach.Measurement(metric: "sets", value: 3, unit: "sets"), AICoach.Measurement(metric: "reps", value: 5, unit: "reps"),
                                                 AICoach.Measurement(metric: "load_lb", value: 225, unit: "lb")]))
        try context.save()

        let url = FileManager.default.temporaryDirectory.appending(path: "today-\(UUID()).json")
        #expect(TodayWidget.refresh(context, to: url))
        #expect(!TodayWidget.refresh(context, to: url), "nothing changed, so nothing is written")
        var content = TodaySnapshot.read(from: url)?.content(on: .now)
        #expect(content?.state == .workout)
        #expect(content?.day?.title == "Squat")
        #expect(content?.day?.lifts.first?.dose == "3×5 · 225")
        #expect(TodaySnapshot.read(from: url)?.days.count == 14)

        context.insert(LogEntry(kind: .workout, timestamp: .now, templateRef: squat.id,
                                measurements: [AICoach.Measurement(metric: "load_lb", value: 225, unit: "lb"), AICoach.Measurement(metric: "reps", value: 5, unit: "reps")]))
        try context.save()
        #expect(TodayWidget.refresh(context, to: url))
        content = TodaySnapshot.read(from: url)?.content(on: .now)
        #expect(content?.state == .done)
        #expect(content?.day?.done?.best == "Squat 225×5")
    }

    @Test func aPlannedWorkoutPastNextWeekShowsWithoutTheApp() throws {
        // TKL-802 review: the app last writes on a Saturday; the next workout is the Sunday 8 days later.
        let calendar = Calendar.current
        let context = ModelContext(try AppSchema.container(inMemory: true))
        let squat = Template(kind: .exercise, name: "Back Squat", slug: "back-squat", attributes: [])
        context.insert(squat)
        let saturday = calendar.date(byAdding: .day, value: 6, to: Week.start(of: .now, calendar: calendar))!.addingTimeInterval(20 * 3600)
        let later = calendar.date(byAdding: .day, value: 8, to: calendar.startOfDay(for: saturday))!
        context.insert(PlannedActivity(kind: .workout, date: later.addingTimeInterval(7 * 3600), slot: "Lower A", templateRef: squat.id,
                                       targets: [AICoach.Measurement(metric: "sets", value: 3, unit: "sets"), AICoach.Measurement(metric: "reps", value: 5, unit: "reps")]))
        try context.save()

        let snapshot = try TodayWidget.snapshot(context, now: saturday, calendar: calendar)
        #expect(snapshot.days.count == 21)
        #expect(snapshot.content(on: later.addingTimeInterval(9 * 3600), calendar: calendar).state == .workout)
        #expect(snapshot.timeline(from: saturday, calendar: calendar).contains(later), "an entry at that day's midnight")
        // The days between are rest, not "no data".
        let monday = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: saturday))!
        #expect(snapshot.content(on: monday, calendar: calendar).state == .rest)
        #expect(snapshot.content(on: monday, calendar: calendar).next?.date == later)
    }

    @Test func anEmptyStoreIsNotSetUp() throws {
        let context = ModelContext(try AppSchema.container(inMemory: true))
        let url = FileManager.default.temporaryDirectory.appending(path: "today-\(UUID()).json")
        #expect(TodayWidget.refresh(context, to: url))
        #expect(TodaySnapshot.read(from: url)?.content(on: .now).state == .notSetUp)
    }

    @Test func theWidgetsLinks() {
        #expect(TodaySnapshot.Link(URL(string: "barbrabell://start")!) == .start)
        #expect(TodaySnapshot.Link(URL(string: "barbrabell://today")!) == .today)
        #expect(TodaySnapshot.Link(URL(string: "https://barbrabell.com/today")!) == nil)
        #expect(TodaySnapshot.Link.start.url.absoluteString == "barbrabell://start")
    }
}
