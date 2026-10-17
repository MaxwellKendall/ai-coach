import Foundation
import Testing
@testable import AICoach

/// FIT-129: the web dashboard shows progress from the same logs, so the app's rules and the web's (web/src/progress.ts)
/// are held to one fixture. Change a rule here and the web's test fails until it matches.
struct ProgressParityTests {
    struct Fixture: Decodable {
        struct Set: Decodable {
            var exercise: String
            var day: String
            var load_lb: Double?
            var reps: Double?
            var rpe: Double?
            var duration_s: Double?
        }
        var sets: [Set]
        var expected1RM: [String: Double]
        var expectedTrend: [String: [[Value]]]
        var programStart: String
        var today: String
        var plannedDays: [String]
        var workoutDays: [String]
        var expectedStreakWeeks: Int
        var expectedThisWeek: String
        var plateau: Plateau

        struct Plateau: Decodable {
            var today: String
            var sets: [Set]
            var expected: [String: Bool]
        }

        enum Value: Decodable {
            case day(String), number(Double)
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let s = try? c.decode(String.self) { self = .day(s) } else { self = .number(try c.decode(Double.self)) }
            }
        }
    }

    let calendar = Calendar.current
    let fixture: Fixture = {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/progress-parity.json")
        return try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }()

    func day(_ string: String) -> Date {
        let p = string.split(separator: "-").map { Int($0)! }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))!
    }

    var sets: [LoggedSet] { loggedSets(fixture.sets) }

    func loggedSets(_ sets: [Fixture.Set]) -> [LoggedSet] {
        sets.map { s in
            LoggedSet(date: day(s.day), exercise: s.exercise, measurements: [
                s.load_lb.map { Measurement(metric: "load_lb", value: $0, unit: "lb") },
                s.reps.map { Measurement(metric: "reps", value: $0, unit: "reps") },
                s.rpe.map { Measurement(metric: "rpe", value: $0, unit: "rpe") },
                s.duration_s.map { Measurement(metric: "duration_s", value: $0, unit: "s") },
            ].compactMap { $0 })
        }
    }

    @Test func estimatedMaxesMatchTheWeb() {
        #expect(Training.estimated1RMs(sets) == fixture.expected1RM)
        for (exercise, points) in fixture.expectedTrend {
            let expected = points.map { pair -> DatedValue in
                guard case .day(let d) = pair[0], case .number(let v) = pair[1] else { fatalError() }
                return DatedValue(date: day(d), value: v)
            }
            #expect(Training.estimated1RMTrend(sets, exercise: exercise, calendar: calendar) == expected)
        }
    }

    @Test func streakMatchesTheWeb() {
        let status = Streak.status(since: day(fixture.programStart), plannedDays: fixture.plannedDays.map(day),
                                   workoutDays: fixture.workoutDays.map(day), today: day(fixture.today), calendar: calendar)
        #expect(status.weeks == fixture.expectedStreakWeeks)
        #expect(status.thisWeek == .onTrack)
        #expect(fixture.expectedThisWeek == "onTrack")
    }

    @Test func plateausMatchTheWeb() {
        let sets = loggedSets(fixture.plateau.sets)
        for (exercise, expected) in fixture.plateau.expected {
            #expect(Training.plateaued(sets, exercise: exercise, today: day(fixture.plateau.today), calendar: calendar) == expected,
                    "\(exercise)")
        }
    }
}
