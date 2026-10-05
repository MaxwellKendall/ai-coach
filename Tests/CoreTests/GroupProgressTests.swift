import Foundation
import Testing
@testable import AICoach

struct GroupProgressTests {
    let day: TimeInterval = 86_400
    let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func weighIn(_ days: Double, _ lb: Double) -> DatedValue { DatedValue(date: start + days * day, value: lb) }

    @Test func relativeWeightGoalFromEachMembersOwnStart() {
        // "Lose 10 lb in 2 months": one member starts at 210, another at 160. Both are 60% there.
        let deadline = start + 60 * day
        let heavy = GroupProgress.mine(metric: "weight_lb", goal: -10, mode: .relative, deadline: deadline, baseline: 210,
                                       joined: start, sets: [], weighIns: [weighIn(30, 204)], now: start + 30 * day)
        let light = GroupProgress.mine(metric: "weight_lb", goal: -10, mode: .relative, deadline: deadline, baseline: 160,
                                       joined: start, sets: [], weighIns: [weighIn(30, 154)], now: start + 30 * day)
        #expect(heavy == .init(baseline: 210, value: 204, pct: 60, onPace: true))
        #expect(light?.pct == 60)
    }

    @Test func firstPublishTakesTheBaselineFromTheLatestLog() {
        let mine = GroupProgress.mine(metric: "weight_lb", goal: -10, mode: .relative, deadline: nil, baseline: nil,
                                      joined: start, sets: [], weighIns: [weighIn(-3, 199), weighIn(-1, 198)])
        #expect(mine == .init(baseline: 198, value: 198, pct: 0, onPace: nil))
    }

    @Test func nothingToShareWithoutALog() {
        #expect(GroupProgress.mine(metric: "weight_lb", goal: -10, mode: .relative, deadline: nil, baseline: nil,
                                   joined: start, sets: [], weighIns: []) == nil)
    }

    @Test func absoluteMaxGoalUsesTheBestEstimate() {
        let sets = [LoggedSet(date: start + day, exercise: "bench-press", pattern: nil,
                              measurements: [Measurement(metric: "load_lb", value: 185, unit: "lb"),
                                             Measurement(metric: "reps", value: 5, unit: "reps")])]
        let mine = GroupProgress.mine(metric: "bench-press.1rm_lb", goal: 225, mode: .absolute, deadline: nil, baseline: 200,
                                      joined: start, sets: sets, weighIns: [])
        // Brzycki 185×5 ≈ 208: 8 of 25 lb.
        #expect(mine?.value == 208)
        #expect(mine?.pct == 32)
    }

    @Test func paceIsAStraightLineWithTheProgramsEightyPercentRule() {
        let deadline = start + 100 * day
        #expect(GroupProgress.onPace(done: 0.4, from: start, to: deadline, now: start + 50 * day) == true)
        #expect(GroupProgress.onPace(done: 0.39, from: start, to: deadline, now: start + 50 * day) == false)
        // The first week is too early to judge.
        #expect(GroupProgress.onPace(done: 0, from: start, to: deadline, now: start + 600) == nil)
        #expect(GroupProgress.onPace(done: 0, from: start, to: deadline, now: start + 6 * day) == nil)
        #expect(GroupProgress.onPace(done: 0, from: start, to: deadline, now: start + 8 * day) == false)
        #expect(GroupProgress.onPace(done: 0.7, from: start, to: deadline, now: start + 200 * day) == false)
    }

    @Test func milestonesAreQuarterMarksCrossed() {
        #expect(GroupProgress.milestone(from: nil, to: 10) == nil)
        #expect(GroupProgress.milestone(from: 20, to: 30) == 25)
        #expect(GroupProgress.milestone(from: 20, to: 80) == 75)
        #expect(GroupProgress.milestone(from: 50, to: 50) == nil)
        #expect(GroupProgress.milestone(from: 90, to: 100) == 100)
        #expect(GroupProgress.milestone(from: 60, to: 40) == nil)
    }

    @Test func togetherIsTheMeanAndDaysLeftNeverNegative() {
        #expect(GroupProgress.together([60, 20, 40]) == 40)
        #expect(GroupProgress.together([]) == nil)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        #expect(GroupProgress.daysLeft(until: start + 10 * day, now: start, calendar: calendar) == 10)
        #expect(GroupProgress.daysLeft(until: start - 10 * day, now: start, calendar: calendar) == 0)
    }

    @Test func titlesAndChanges() {
        #expect(GroupProgress.title(metric: "weight_lb", goal: -10, mode: .relative) == "Lose 10 lb")
        #expect(GroupProgress.title(metric: "bench-press.1rm_lb", goal: 20, mode: .relative) == "Add 20 lb to bench press max")
        #expect(GroupProgress.title(metric: "pull-up.reps", goal: 5, mode: .relative) == "+5 pull-ups")
        #expect(GroupProgress.title(metric: "bench-press.1rm_lb", goal: 225, mode: .absolute) == "Bench press max 225 lb")
        #expect(GroupProgress.change(203.8, from: 210, unit: "lb") == "−6.2 lb")
        #expect(GroupProgress.change(215, from: 200, unit: "lb") == "+15 lb")
    }
}
