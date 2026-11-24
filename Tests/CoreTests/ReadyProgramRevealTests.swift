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

    @Test func revealTimingKeepsStartWithinTwoSeconds() {
        #expect(PlanReveal.MotionStage.title < .numbers)
        #expect(PlanReveal.MotionStage.numbers < .line)
        #expect(PlanReveal.MotionStage.line < .date)
        #expect(PlanReveal.MotionStage.date < .details)
        #expect(PlanReveal.MotionStage.details < .start)
        #expect(PlanReveal.MotionStage.start.elapsed + .milliseconds(300) < .seconds(2))
    }

    @Test func chartShowsTheDeloadWithoutChangingThePromise() throws {
        let program = try #require(ReadyProgram.named("full-body-3"))
        let projection = try #require(program.projection(days: 3, deloads: program.deloads))
        let loads = PlanReveal.chartLoads(projection.loads, deloads: program.deloads)
        #expect(loads[7] < loads[6] && loads[7] < loads[8])
        #expect(loads.first == projection.start && loads.last == projection.end)

        let fewerDays = try #require(program.projection(days: 2, deloads: program.deloads))
        #expect(PlanReveal.chartLoads(fewerDays.loads, deloads: program.deloads) != loads)
    }

    @Test func chartMorphKeepsItsSamplesAndInterpolatesBetweenProjections() {
        let before = PlanReveal.ChartSamples(loads: [45, 65, 55, 120])
        let after = PlanReveal.ChartSamples(loads: [45, 55, 65, 95, 85, 100, 125])
        #expect(before.values.count == after.values.count)
        var half = after - before
        half.scale(by: 0.5)
        let midway = before + half
        #expect(midway.values[32] == (before.values[32] + after.values[32]) / 2)
        #expect(midway.values[32] != before.values[32])
        #expect(midway.values.first == 0 && midway.values.last == 1)
    }

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

    /// FIT-305: every quiz answer picks a program, one with equipment has a lift to ask the recent set of, and the
    /// reveal for Get Stronger, a full gym and 4 days starts from the set given (it came up blank, then ignored it).
    @Test func quizAnswersCarryThroughToTheReveal() throws {
        for place in ProgramPicker.places {
            for days in 2...6 {
                for goal in ReadyProgram.Goal.allCases {
                    let pick = try #require(ProgramPicker.Answers(have: place.equipment, days: days, goal: goal, lifted: true).pick)
                    #expect(place.equipment.isEmpty || pick.mainLift != nil, "\(place.title), \(days) days, \(goal)")
                }
            }
        }
        var answers = ProgramPicker.Answers(have: ProgramPicker.places[0].equipment, days: 4, goal: .strength, lifted: true)
        let program = try #require(answers.pick)
        // TKL-450: some experience and a strength goal on 4 days is the tiered linear progression, led by its heavy squat.
        #expect(program.slug == "tiered-linear" && program.mainLift?.exercise == "back-squat")
        answers.recent = [StartingSet.recent("back-squat", weight: 185, reps: 3, perHand: false)]
        let reveal = program.projection(days: answers.days, deloads: program.deloads, recent: program.recent(in: answers.recent))
        #expect(reveal?.from == 185)
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

    /// FIT-323: Strength Waves asks for a recent set of each of its four lifts; the others, of their main lift.
    @Test func asksForEachWaveLift() {
        #expect(ReadyProgram.named("strength-waves")?.recentLifts == ["back-squat", "bench-press", "deadlift", "standing-military-press"])
        #expect(ReadyProgram.named("full-body-3")?.recentLifts == ["back-squat"])
        #expect(ReadyProgram.named("bodyweight-basics")?.recentLifts == [])
    }
}
