import Foundation
import Testing
@testable import AICoach

/// FIT-281: the web quiz's answers (infra/test/readyPrograms.test.ts writes them) are the app's: the same program,
/// training days and reveal for each case, so the plan revealed on the web is the plan the app opens. With the goal,
/// experience and a recent set of the main lift too.
struct ReadyProgramRevealTests {
    struct Case: Decodable {
        struct Reveal: Decodable {
            var exercise: String
            var loads: [Double]
            var perHand: Bool
            var from: Double
        }
        struct Recent: Decodable {
            var weight: Double
            var reps: Double
        }
        var have: [String]
        var days: Int
        var goal: ReadyProgram.Goal?
        var lifted: Bool?
        var recent: Recent?
        var slug: String
        var trainingDays: [Int]
        var projection: Reveal?
    }

    @Test func webAndAppAgree() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures/ready-program-reveal.json")
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
        #expect(cases.count > 5)
        for answer in cases {
            let program = try #require(ReadyProgram.matches(have: Set(answer.have), days: answer.days, goal: answer.goal,
                                                            lifted: answer.lifted).first)
            #expect(program.slug == answer.slug, "\(answer.have) \(answer.days)")
            let days = ReadyProgram.days(for: program.days(nearest: answer.days))
            #expect(days == answer.trainingDays, "\(answer.slug)")
            let recent = answer.recent.map {
                StartingSet.recent(program.mainLift!.exercise!, weight: $0.weight, reps: $0.reps, perHand: program.place == .dumbbells)
            }
            let reveal = program.projection(days: days.count, deloads: program.deloads, recent: recent)
            #expect(reveal?.exercise == answer.projection?.exercise, "\(answer.slug)")
            #expect(reveal?.loads == answer.projection?.loads, "\(answer.slug)")
            #expect(reveal?.perHand == answer.projection?.perHand, "\(answer.slug)")
            #expect(reveal?.from == answer.projection?.from, "\(answer.slug)")
        }
    }

    @Test func deloadIsTheSeventhWeek() {
        #expect(ReadyProgram.named("full-body-3")!.deloads == [6])
    }
}

/// FIT-267: the paywall's headline says what the web's does (web/src/start.test.ts).
struct PlanRevealHeadlineTests {
    private let ends: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: 2027, month: 1, day: 16))!
    }()

    @Test func promisesTheLiftByTheLastDay() {
        let program = ReadyProgram.named("full-body-3")!
        let reveal = program.projection(days: 3, deloads: program.deloads)
        #expect(PlanReveal.headline(program, reveal: reveal, exercise: "Back Squat", ends: ends) == "Back Squat 45 → 120 lb by Jan 16")
    }

    @Test func startsFromTheirRecentSet() {
        let program = ReadyProgram.named("full-body-3")!
        let recent = StartingSet.recent("back-squat", weight: 225, reps: 5, perHand: false)
        let reveal = program.projection(days: 3, deloads: program.deloads, recent: recent)
        #expect(reveal?.start == 205)
        #expect(PlanReveal.headline(program, reveal: reveal, exercise: "Back Squat", ends: ends) == "Back Squat 225 → 250 lb by Jan 16")
    }

    @Test func saysAHandForDumbbells() {
        let program = ReadyProgram.named("dumbbell-full-body")!
        let reveal = program.projection(days: 3, deloads: program.deloads)
        #expect(PlanReveal.headline(program, reveal: reveal, exercise: "Split Squat", ends: ends).hasSuffix(" lb a hand by Jan 16"))
    }

    @Test func hasNoLoadForBodyWeight() {
        let program = ReadyProgram.named("bodyweight-basics")!
        #expect(PlanReveal.headline(program, reveal: nil, exercise: "", ends: ends) == "Bodyweight Basics: 12 weeks, done by Jan 16")
    }
}
