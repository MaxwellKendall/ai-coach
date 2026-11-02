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
}
