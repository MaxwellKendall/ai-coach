import Foundation
import Testing
@testable import AICoach

/// FIT-304: the Dynamic Island's left side names the lift in a word, beside the set.
struct LiveActivityTests {
    @Test func liftInAWord() {
        #expect(WorkoutActivityAttributes.short("Back Squat") == "Squat")
        #expect(WorkoutActivityAttributes.short("Bench Press") == "Bench")
        #expect(WorkoutActivityAttributes.short("Deadlift") == "Deadlift")
        #expect(WorkoutActivityAttributes.short("Standing Military Press") == "Press")
        #expect(WorkoutActivityAttributes.short("Dumbbell Romanian Deadlift") == "RDL")
        #expect(WorkoutActivityAttributes.short("Pull-up") == "Pull-up")
    }

    @Test func restIntervalAndNextUpLinePopulateForMotion() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let ends = start.addingTimeInterval(120)
        let state = WorkoutActivityAttributes.ContentState(
            title: "Back Squat",
            detail: "Set 2 of 3 · 170 lb × 5",
            step: "2/3",
            load: "170 lb",
            restStarted: start,
            restEnds: ends,
            progress: 0.33,
            lift: "Squat",
            set: "170×5",
            nextUp: WorkoutActivityAttributes.nextUpLine(title: "Back Squat", dose: "170 × 5"),
            loggedSets: 1,
            totalSets: 3
        )
        #expect(state.restStarted == start)
        #expect(state.restEnds == ends)
        #expect(state.nextUp == "Next: Back Squat · 170 × 5")
        #expect(state.loggedSets == 1)
        #expect(state.totalSets == 3)
    }
}
