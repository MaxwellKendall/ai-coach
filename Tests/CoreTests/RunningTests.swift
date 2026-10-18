import Foundation
import Testing
@testable import AICoach

/// FIT-179: race-time goals in the app, the same numbers as infra/lambda/running.ts.
struct RunningTests {
    @Test func metricsAndRiegel() {
        #expect(Running.metric(meters: 10000) == "run_10000m.time_s")
        #expect(Running.meters("run_21098m.time_s") == 21098)
        #expect(Running.meters("back-squat.1rm_lb") == nil)
        // 8 km in 44:00 predicts a 10K in 55:44; a mile is too short to say.
        #expect(Running.clock(Running.riegel(seconds: 2640, from: 8000, to: 10000)!) == "55:44")
        #expect(Running.riegel(seconds: 420, from: 1609, to: 10000) == nil)
        #expect(Running.clock(6330) == "1:45:30")
        #expect(Running.pace(seconds: 2640, meters: 8000) == "5:30/km")
    }

    @Test func aRaceGoalStartsFromARecentRun() {
        var answers = OnboardingAnswers()
        answers.goals = ["10k"]
        answers.weeks = 16
        answers.starts[Running.outdoor] = StartingSet(exercise: Running.outdoor, measurements: [
            Measurement(metric: "distance_m", value: 10000, unit: "m"), Measurement(metric: "duration_s", value: 3600, unit: "s")])
        let option = GoalOption.with(id: "10k")!
        #expect(answers.baseline(option) == 3600)
        // Half a percent faster a week for 16 weeks is 8%: 55:12, to the nearest 15 s.
        #expect(answers.suggestedTarget(option) == 3315)
        #expect(option.title(target: 3300) == "10K in 55:00")
        #expect(option.format(3315) == "55:15" && option.shownUnit.isEmpty && option.step == 30)
        #expect(!GoalOption.group.contains { $0.measure == .time })
    }

    @Test func faster() {
        let goal = Wins.Goal(metric: "run_10000m.time_s", unit: "s", baseline: 3600, target: 3300)
        func run(_ day: Int, _ km: Double, _ minutes: Double) -> LoggedSet {
            LoggedSet(date: Date(timeIntervalSince1970: 1_790_000_000 + Double(day) * 86_400), exercise: Running.outdoor, pattern: "conditioning",
                      measurements: [Measurement(metric: "distance_m", value: km * 1000, unit: "m"), Measurement(metric: "duration_s", value: minutes * 60, unit: "s")])
        }
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let runs = [run(1, 10, 59), run(8, 8, 46), run(15, 10, 61)]
        #expect(GoalProgress.current(goal.metric, sets: runs, weighIns: [], since: start) == 3497)
        let wins = Wins.detect(goals: [goal], sets: runs, weighIns: [], since: start, end: start.addingTimeInterval(86_400 * 100),
                               plannedDays: [], workoutDays: [], today: start.addingTimeInterval(86_400 * 20))
        #expect(wins.filter { $0.kind == .pr }.map(\.value) == [3497, 3540])
    }

    @Test func runTimesAsTyped() {
        #expect(Running.seconds("48:30") == 2910)
        #expect(Running.seconds("1:02:10") == 3730)
        #expect(Running.seconds("45") == 2700)
        #expect(Running.seconds("abc") == nil)
    }
}
