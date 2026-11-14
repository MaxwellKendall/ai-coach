import Testing
@testable import AICoach

/// FIT-455: the strength check's scores and which lift is shown plainly.
struct StrengthCheckTests {
    @Test func scoresFollowTheStandardsLevels() {
        // A 180 lb man benching 180 (1.0 × body weight) is intermediate: 60.
        #expect(StrengthCheck.score("bench-press", estimatedMax: 180, bodyweight: 180, sex: .male) == 60)
        // Halfway between intermediate (1.0) and advanced (1.5): 70.
        #expect(StrengthCheck.score("bench-press", estimatedMax: 225, bodyweight: 180, sex: .male) == 70)
        // Past elite caps at 100; nothing lifted is 0.
        #expect(StrengthCheck.score("deadlift", estimatedMax: 700, bodyweight: 180, sex: .male) == 100)
        #expect(StrengthCheck.score("deadlift", estimatedMax: 0, bodyweight: 180, sex: .male) == 0)
    }

    @Test func womenAreScoredAgainstTheirOwnStandards() {
        let man = StrengthCheck.score("back-squat", estimatedMax: 170, bodyweight: 135, sex: .male)
        let woman = StrengthCheck.score("back-squat", estimatedMax: 170, bodyweight: 135, sex: .female)
        #expect(woman > man)
        let either = StrengthCheck.score("back-squat", estimatedMax: 170, bodyweight: 135, sex: .unspecified)
        #expect((man...woman).contains(either))
    }

    @Test func theWeakestLiftIsTheLowestScore() throws {
        let entries = [StrengthCheck.Entry(slug: "back-squat", weight: 275, reps: 5),
                       StrengthCheck.Entry(slug: "bench-press", weight: 135, reps: 5),
                       StrengthCheck.Entry(slug: "deadlift", weight: 315, reps: 5)]
        let result = try #require(StrengthCheck.result(entries, bodyweight: 180, sex: .male))
        #expect(result.weakest == "bench-press")
        #expect(result.scores.count == 3)
        #expect(result.overall == Int((Double(result.scores.values.reduce(0, +)) / 3).rounded()))
    }

    @Test func tiesGoToTheGoalsLiftThenTheFixedOrder() throws {
        let same = [StrengthCheck.Entry(slug: "deadlift", weight: 0, reps: 5), StrengthCheck.Entry(slug: "back-squat", weight: 0, reps: 5)]
        #expect(try #require(StrengthCheck.result(same, bodyweight: 180, sex: .male)).weakest == "back-squat")
        #expect(try #require(StrengthCheck.result(same, bodyweight: 180, sex: .male, favoring: "deadlift")).weakest == "deadlift")
    }

    @Test func noLiftsNoResult() {
        #expect(StrengthCheck.result([], bodyweight: 180, sex: .male) == nil)
    }
}
