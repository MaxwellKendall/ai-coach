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

    @Test func restIntervalAndNextLinePopulateForMotion() {
        // TKL-934's countdown rings run from the rest's start; TKL-1023 keeps them under the approved island layout.
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
            next: "Next: Squat 170×5",
            setsDone: 1,
            sets: 3,
            restTotal: 90
        )
        #expect(state.restStarts == start) // the real start wins over ends − total
        #expect(state.restEnds == ends)
        #expect(state.next == "Next: Squat 170×5")
        #expect(state.setsDone == 1 && state.sets == 3)
    }
}
