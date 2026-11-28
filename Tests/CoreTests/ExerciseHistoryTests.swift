import Foundation
import Testing
@testable import AICoach

/// FIT-356: past sessions and an exercise's last sessions, from logged sets.
struct ExerciseHistoryTests {
    private let monday = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 7))!

    private func set(_ exercise: String, _ reps: Double, _ load: Double?, days: Int = 0, minute: Int = 0, rpe: Double? = nil) -> LoggedSet {
        let date = Calendar.current.date(byAdding: .day, value: days, to: monday)!.addingTimeInterval(TimeInterval(minute * 60))
        var measurements = [Measurement(metric: "reps", value: reps, unit: "reps")]
        if let load { measurements.append(Measurement(metric: "load_lb", value: load, unit: "lb")) }
        if let rpe { measurements.append(Measurement(metric: "rpe", value: rpe, unit: "rpe")) }
        return LoggedSet(date: date, exercise: exercise, pattern: nil, measurements: measurements)
    }

    @Test func itGroupsByDayNewestFirstWithEachLiftInOrder() {
        let sets = [set("back-squat", 5, 170, minute: 0), set("back-squat", 5, 170, minute: 3), set("pull-up", 8, nil, minute: 10),
                    set("back-squat", 5, 175, days: 3)]
        let days = ExerciseHistory.days(sets)
        #expect(days.map(\.date) == [Calendar.current.startOfDay(for: sets[3].date), Calendar.current.startOfDay(for: monday)])
        #expect(days[1].lifts.map(\.exercise) == ["back-squat", "pull-up"])
        #expect(days[1].lifts[0].sets.count == 2)
        // Brzycki on 170 × 5: 170 × 36 / 32.
        #expect(days[1].lifts[0].best == 191.25)
        #expect(days[1].lifts[1].best == nil)

        let squats = ExerciseHistory.days(sets, exercise: "back-squat")
        #expect(squats.count == 2 && squats.allSatisfy { $0.lifts.map(\.exercise) == ["back-squat"] })
    }

    @Test func aHardSetIsntAnEstimate() {
        #expect(ExerciseHistory.days([set("bench-press", 5, 200, rpe: 9.5)])[0].lifts[0].best == nil)
    }

    @Test func theSummaryIsShortWhenTheSetsMatch() {
        typealias Line = ExerciseHistory.Line
        #expect(ExerciseHistory.summary([Line(reps: 5, load: 170), Line(reps: 5, load: 170), Line(reps: 5, load: 170)]) == "3 × 5 @ 170 lb")
        #expect(ExerciseHistory.summary([Line(reps: 5, load: 170), Line(reps: 3, load: 175)]) == "5 @ 170 · 3 @ 175 lb")
        #expect(ExerciseHistory.summary([Line(reps: 10), Line(reps: 10)]) == "2 × 10")
        #expect(ExerciseHistory.summary([Line(seconds: 45)]) == "45 s")
        #expect(ExerciseHistory.summary([Line(load: 53, meters: 40), Line(load: 53, meters: 40)]) == "2 × 40 m @ 53 lb")
        #expect(ExerciseHistory.summary([]) == "")
    }

    // TKL-1087: the notes written about a workout day, the lifter's own and the coach's, kept apart.
    private func note(_ text: String, days: Int = 0, hour: Int = 2) -> ExerciseHistory.Note {
        ExerciseHistory.Note(date: Calendar.current.date(byAdding: .day, value: days, to: monday)!.addingTimeInterval(TimeInterval(hour * 3600)), text: text)
    }

    @Test func aDayWithoutANoteHasNone() {
        let days = ExerciseHistory.days([set("back-squat", 5, 170)], notes: [note("easy", days: 3)], coachNotes: [])
        #expect(days.count == 1)
        #expect(days[0].note == nil && days[0].coachNote == nil)
    }

    @Test func aDayCarriesTheLiftersNote() {
        let days = ExerciseHistory.days([set("back-squat", 5, 170), set("back-squat", 5, 175, days: 3)],
                                        notes: [note("Felt strong, knee fine", hour: 2)], coachNotes: [])
        #expect(days[1].note == "Felt strong, knee fine" && days[1].coachNote == nil)
        #expect(days[0].note == nil)
    }

    @Test func aDayCanHaveOnlyTheCoachsNote() {
        let days = ExerciseHistory.days([set("back-squat", 5, 170)], notes: [], coachNotes: [note("Stay at RPE 7 today")])
        #expect(days[0].note == nil && days[0].coachNote == "Stay at RPE 7 today")
    }

    @Test func bothNotesStayApart() {
        let days = ExerciseHistory.days([set("back-squat", 5, 170)], notes: [note("Grip gave out")], coachNotes: [note("Belt on the top set")])
        #expect(days[0].note == "Grip gave out" && days[0].coachNote == "Belt on the top set")
    }

    @Test func emptyNotesAndNotesOnDaysWithoutLiftingAreDropped() {
        let days = ExerciseHistory.days([set("back-squat", 5, 170)], notes: [note("  \n "), note("rest day walk", days: 1)], coachNotes: [note("")])
        #expect(days.count == 1 && days[0].note == nil && days[0].coachNote == nil)
    }

    @Test func twoSessionsInADayKeepBothNotesInOrder() {
        let days = ExerciseHistory.days([set("back-squat", 5, 170)], notes: [note("evening", hour: 10), note("morning", hour: 1)], coachNotes: [])
        #expect(days[0].note == "morning\n\nevening")
    }

    @Test func theListShowsTheNotesFirstLine() {
        #expect(ExerciseHistory.firstLine("Felt strong\nknee fine later") == "Felt strong")
        #expect(ExerciseHistory.firstLine("\n  Second try  \nmore") == "Second try")
        #expect(ExerciseHistory.firstLine("one line") == "one line")
    }
}
