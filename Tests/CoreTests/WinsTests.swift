import Foundation
import Testing
@testable import AICoach

private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}

private func date(_ month: Int, _ day: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))! }
/// Wins are dated to their day.
private func day(_ month: Int, _ day: Int) -> Date { calendar.startOfDay(for: date(month, day)) }

private func set(_ exercise: String, _ month: Int, _ day: Int, load: Double? = nil, reps: Double) -> LoggedSet {
    LoggedSet(date: date(month, day), exercise: exercise, pattern: nil,
              measurements: (load.map { [Measurement(metric: "load_lb", value: $0, unit: "lb")] } ?? []) + [Measurement(metric: "reps", value: reps, unit: "")])
}

/// The prototype's goals, started Monday Aug 10 and ending Nov 29.
struct WinsTests {
    let start = date(8, 10), end = date(11, 29)
    let squat = Wins.Goal(metric: "back-squat.1rm_lb", unit: "lb", baseline: 186, target: 250)
    let pullups = Wins.Goal(metric: "pull-up.reps", unit: "reps", baseline: 6, target: 10)
    let weight = Wins.Goal(metric: "weight_lb", unit: "lb", baseline: 201, target: 180)

    private func detect(_ goals: [Wins.Goal], sets: [LoggedSet] = [], weighIns: [DatedValue] = [], planned: [Date] = [], done: [Date] = [],
                        today: Date = date(10, 5)) -> [WinItem] {
        Wins.detect(goals: goals, sets: sets, weighIns: weighIns, since: start, end: end, plannedDays: planned, workoutDays: done,
                    today: today, calendar: calendar)
    }

    @Test func aPersonalBestBeatsWhereTheGoalStarted() throws {
        // 165 × 5 estimates 186: not past the 186 it started at. 185 × 5 is 208, 195 × 5 is 219.
        let wins = detect([squat], sets: [set("back-squat", 8, 12, load: 165, reps: 5), set("back-squat", 9, 14, load: 185, reps: 5),
                                          set("back-squat", 10, 3, load: 195, reps: 5)])
        let prs = wins.filter { $0.kind == .pr }
        #expect(prs.map(\.value) == [219, 208])
        #expect(prs.map(\.previous) == [208, 186])
        #expect(prs.map(\.date) == [day(10, 3), day(9, 14)])
        #expect(prs[0].key == "pr:back-squat.1rm_lb:219")
        #expect(prs[0].trend == [186, 186, 208, 219] || prs[0].trend == [186, 208, 219])
        #expect(prs[0].weeksLeft == 8)
        // Weight isn't a personal best, only a milestone.
        let loss = detect([weight], weighIns: [DatedValue(date: date(9, 6), value: 195.5)])
        #expect(loss.filter { $0.kind == .pr }.isEmpty)
    }

    @Test func milestonesAreTheFirstCrossingOfEach() {
        // Squat 186 → 250: 50% is 218, so 219 crosses 25 and 50 on Oct 3, 208 had crossed 25 on Sep 14.
        let sets = [set("back-squat", 9, 14, load: 185, reps: 5), set("back-squat", 10, 3, load: 195, reps: 5)]
        let milestones = detect([squat], sets: sets).filter { $0.kind == .milestone }
        #expect(milestones.map(\.key) == ["milestone:back-squat.1rm_lb:50", "milestone:back-squat.1rm_lb:25"])
        #expect(milestones.map(\.date) == [day(10, 3), day(9, 14)])
        #expect(milestones[0].percent == 50 && milestones[0].value == 219 && milestones[0].target == 250)
        // Weight goes down: 201 → 180, a quarter of the way is 195.75.
        let weights = [DatedValue(date: date(9, 6), value: 195.5), DatedValue(date: date(9, 13), value: 196), DatedValue(date: date(10, 1), value: 194.6)]
        let quarter = detect([weight], weighIns: weights).filter { $0.kind == .milestone }
        #expect(quarter.map(\.key) == ["milestone:weight_lb:25"] && quarter[0].date == day(9, 6))
    }

    @Test func reachingTheGoalIsTheLastMilestone() {
        let done = detect([pullups], sets: [set("pull-up", 9, 1, reps: 8), set("pull-up", 10, 2, reps: 10)])
        #expect(done.filter { $0.kind == .milestone }.compactMap(\.percent).sorted() == [25, 50, 75, 100])
        #expect(done.first { $0.percent == 100 }?.date == day(10, 2))
    }

    @Test func fullWeeksInARowMakeAStreakFromTwo() {
        // Mon Aug 10 is week 1. Sessions on Mon and Wed; week 3 misses Wednesday, so weeks 4 to 7 count again.
        func week(_ n: Int, _ skip: Bool = false) -> (planned: [Date], done: [Date]) {
            let monday = calendar.date(byAdding: .day, value: 7 * (n - 1), to: start)!
            let days = [monday, calendar.date(byAdding: .day, value: 2, to: monday)!]
            return (days, skip ? [days[0]] : days)
        }
        let weeks = (1...7).map { week($0, $0 == 3) }
        let wins = detect([], planned: weeks.flatMap(\.planned), done: weeks.flatMap(\.done), today: date(9, 28)).filter { $0.kind == .streak }
        // Weeks 1–2 are 2 in a row; after the miss, weeks 4–7 reach 2 and then 4.
        #expect(wins.map(\.key) == ["streak:4", "streak:2", "streak:2"])
        #expect(wins.map(\.workouts) == [8, 4, 4])
        #expect(wins.map(\.date) == [day(9, 27), day(9, 13), day(8, 23)])
        // The week in progress doesn't count yet.
        #expect(detect([], planned: weeks.flatMap(\.planned), done: weeks.flatMap(\.done), today: date(8, 20)).filter { $0.kind == .streak }.isEmpty)
        // A week with nothing planned neither adds nor breaks.
        let gap = weeks[0].planned + weeks[1].planned + weeks[3].planned
        #expect(detect([], planned: gap, done: gap, today: date(9, 1)).filter { $0.kind == .streak }.map(\.key) == ["streak:2"])
    }

    @Test func newestFirst() {
        let wins = detect([squat], sets: [set("back-squat", 9, 14, load: 185, reps: 5), set("back-squat", 10, 3, load: 195, reps: 5)])
        #expect(wins.map(\.date) == wins.map(\.date).sorted(by: >))
        #expect(wins.first?.date == day(10, 3))
    }
}
