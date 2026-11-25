import Testing
@testable import AICoach

struct CoachMotionTests {
    @Test func affectedWeeksAreUniqueChronologicalAndIncludeClearedDays() {
        let days = ["2026-11-30", "2026-11-21", "2026-11-29"]
        #expect(CoachMotion.weeks(for: days) == ["2026-11-15", "2026-11-29"])
    }

    @Test func newlyLoggedDaysIgnoreEditsToExistingLogs() {
        #expect(CoachMotion.newLogs(before: [true, false, true], after: [true, true, false]) == [1])
    }
}
