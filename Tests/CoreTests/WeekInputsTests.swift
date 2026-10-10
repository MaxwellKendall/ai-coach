import Foundation
import Testing
@testable import AICoach

/// FIT-96: a week's design sees last week as done, not just as planned, and short sleep.
@MainActor
struct WeekInputsTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }
    private var monday: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 12))! }
    private var lastMonday: Date { calendar.date(byAdding: .day, value: -7, to: monday)! }
    private let settings = TrainingSettings(age: 36, daysPerWeek: 3, sessionMinutes: 45, trainingDays: [0, 2, 4], workoutTime: 420,
                                            equipment: ["barbell", "rack", "dumbbells", "bench"], maxWeeklySets: 60)
    private let names = ["bench-press": "Bench Press", "back-squat": "Back Squat", "deadlift": "Deadlift", "dumbbell-row": "Dumbbell Row"]

    private func day(_ offset: Int) -> Date { calendar.date(byAdding: .minute, value: 420, to: calendar.date(byAdding: .day, value: offset, to: lastMonday)!)! }

    private func planned(_ offset: Int, _ exercise: String, load: Double, reps: Double, main: Bool = true) -> PlannedWorkout {
        PlannedWorkout(date: day(offset), session: "S", exercise: exercise,
                       targets: [.init(metric: "sets", value: 3, unit: "sets"), .init(metric: "reps", value: reps, unit: "reps"),
                                 .init(metric: "load_lb", value: load, unit: "lb")], main: main)
    }

    private func set(_ offset: Int, _ exercise: String, load: Double, reps: Double, rpe: Double? = nil) -> LoggedSet {
        LoggedSet(date: day(offset), exercise: exercise, pattern: nil,
                  measurements: [.init(metric: "load_lb", value: load, unit: "lb"), .init(metric: "reps", value: reps, unit: "reps")]
                    + (rpe.map { [Measurement(metric: "rpe", value: $0, unit: "RPE")] } ?? []))
    }

    private func request(planned: [PlannedWorkout], history: [LoggedSet], sleep: Double? = nil) -> ProgramDesigner.Request {
        ProgramDesigner.Request(monday: monday, settings: settings, catalog: [], names: names, history: history, weeksSinceDeload: 1,
                                program: nil, lastWeek: planned, sleepHours: sleep, calendar: calendar)
    }

    @Test func sessionsDoneAndSkippedAreCounted() {
        let plan = [planned(0, "bench-press", load: 185, reps: 5), planned(2, "back-squat", load: 225, reps: 5), planned(4, "deadlift", load: 275, reps: 5)]
        let history = [set(0, "bench-press", load: 185, reps: 5), set(2, "back-squat", load: 225, reps: 5)]
        #expect(ProgramDesigner.lastWeekDone(request(planned: plan, history: history)) == ["Last week: 2 of 3 sessions done (Fri skipped)."])
    }

    @Test func aMainLiftThatFellShortSaysHow() {
        let plan = [planned(0, "bench-press", load: 185, reps: 5), planned(0, "dumbbell-row", load: 60, reps: 10, main: false),
                    planned(2, "back-squat", load: 225, reps: 5)]
        let history = [set(0, "bench-press", load: 185, reps: 5), set(0, "bench-press", load: 185, reps: 5),
                       set(0, "bench-press", load: 185, reps: 4, rpe: 9.5), set(0, "dumbbell-row", load: 50, reps: 8),
                       set(2, "back-squat", load: 225, reps: 5, rpe: 8)]
        let lines = ProgramDesigner.lastWeekDone(request(planned: plan, history: history))
        #expect(lines == ["Last week: 2 of 2 sessions done.", "Bench Press planned 185 × 5, did 185 × 4 at RPE 9.5."])
    }

    @Test func aMainLiftLeftOutOfASessionDoneIsNotDone() {
        let plan = [planned(0, "bench-press", load: 185, reps: 5), planned(0, "back-squat", load: 225, reps: 5)]
        let lines = ProgramDesigner.lastWeekDone(request(planned: plan, history: [set(0, "bench-press", load: 185, reps: 5)]))
        #expect(lines.last == "Back Squat planned 225 × 5, not done.")
    }

    @Test func noPlanSaysNothing() {
        #expect(ProgramDesigner.lastWeekDone(request(planned: [], history: [])).isEmpty)
    }

    @Test func shortSleepIsSaidAndNormalSleepIsNot() {
        let short = ProgramDesigner.prompt(request(planned: [], history: [], sleep: 5.6), settings: settings, light: false)
        #expect(short.contains("Slept 5.5 h a night on average last week."))
        let fine = ProgramDesigner.prompt(request(planned: [], history: [], sleep: 7.2), settings: settings, light: false)
        #expect(!fine.contains("Slept"))
    }

    @Test func sleepIsTheAverageOfTheWeekBefore() {
        func entry(_ daysBefore: Int, _ hours: Double) -> LogEntry {
            LogEntry(kind: .sleep, timestamp: calendar.date(byAdding: .day, value: -daysBefore, to: monday)!,
                     measurements: [.init(metric: "sleep_h", value: hours, unit: "h")])
        }
        let entries = [entry(1, 6), entry(3, 5), entry(10, 9)]
        #expect(Planner.sleepHours(entries, before: monday, calendar: calendar) == 5.5)
        #expect(Planner.sleepHours([], before: monday, calendar: calendar) == nil)
    }
}
