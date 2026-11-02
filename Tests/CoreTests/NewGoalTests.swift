import Foundation
import Testing
@testable import AICoach

/// FIT-233: a goal added after onboarding starts where they are and suggests a target a little on.
struct NewGoalTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func offersOnlyTheGoalsTheyDoNotHave() {
        let bench = Goal(kind: .training, metric: "bench-press.1rm_lb", target: 225, unit: "lb")
        let dropped = Goal(kind: .training, metric: "pull-up.reps", target: 10, unit: "reps", status: .abandoned)
        let ids = NewGoal.options(besides: [bench, dropped]).map(\.id)
        #expect(!ids.contains("bench") && ids.contains("pullups") && ids.contains("squat"))
    }

    @Test func startsFromLogsThenTheStartingSetThenWeight() {
        let squat = GoalOption.with(id: "squat")!
        let logged = [LoggedSet(date: start.addingTimeInterval(86_400), exercise: "back-squat", pattern: nil,
                                measurements: [Measurement(metric: "load_lb", value: 225, unit: "lb"), Measurement(metric: "reps", value: 5, unit: "reps")])]
        #expect(NewGoal.baseline(squat, sets: logged, weighIns: [], starts: [], weight: nil, since: start) == 253)
        let set = StartingSet(exercise: "back-squat", measurements: [Measurement(metric: "load_lb", value: 185, unit: "lb"),
                                                                      Measurement(metric: "reps", value: 5, unit: "reps")])
        #expect(NewGoal.baseline(squat, sets: [], weighIns: [], starts: [set], weight: nil, since: start) == 208)
        #expect(NewGoal.baseline(squat, sets: [], weighIns: [], starts: [], weight: 190, since: start) == nil)
        #expect(NewGoal.baseline(GoalOption.with(id: "weight")!, sets: [], weighIns: [], starts: [], weight: 190, since: start) == 190)
    }

    @Test func suggestsATargetALittleOn() {
        #expect(NewGoal.suggested(GoalOption.with(id: "squat")!, from: 253) == 280)
        #expect(NewGoal.suggested(GoalOption.with(id: "pullups")!, from: 6) == 9)
        #expect(NewGoal.suggested(GoalOption.with(id: "weight")!, from: 190) == 180)
        #expect(NewGoal.suggested(GoalOption.with(id: "5k")!, from: 1800) == 1740)
        #expect(NewGoal.suggested(GoalOption.with(id: "bench")!, from: nil) == 185)
    }
}
