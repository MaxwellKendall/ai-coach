import Foundation
import Testing
@testable import AICoach

/// FIT-113: a session shared, and planned again for a friend.
struct SharedSessionTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }
    private var thursday: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 15))! }

    private func row(_ exercise: String, sets: Double = 1, reps: Double? = 5, load: Double? = nil, note: String? = nil) -> PlannedWorkout {
        var targets = [Measurement(metric: "sets", value: sets, unit: "sets")]
        if let reps { targets.append(Measurement(metric: "reps", value: reps, unit: "reps")) }
        if let load { targets.append(Measurement(metric: "load_lb", value: load, unit: "lb")) }
        return PlannedWorkout(date: thursday, session: "Lower body", exercise: exercise, targets: targets, note: note)
    }

    @Test func aDaysRowsBecomeOneEntryPerExerciseWithoutWarmUps() {
        let rows = [row("back-squat", reps: 8, load: 95, note: TrainingGenerator.warmupNote),
                    row("back-squat", sets: 2, load: 185), row("back-squat", sets: 2, load: 195), row("plank", sets: 3, reps: nil)]
        let shared = SharedSession.make(title: "Lower body", date: thursday, workouts: rows, names: ["back-squat": "Back Squat"],
                                        showNumbers: true, invite: "A1B2C3D4", calendar: calendar)
        #expect(shared.date == "2026-10-15")
        #expect(shared.exercises.map(\.name) == ["Back Squat", "plank"])
        #expect(shared.exercises[0].sets == 4)
        #expect(shared.exercises[0].load == 195)
        #expect(shared.minutes == 20)
    }

    @Test func hiddenWeightsAreNotShared() {
        let shared = SharedSession.make(title: "Lower body", date: thursday, workouts: [row("back-squat", sets: 4, load: 185)],
                                        names: [:], showNumbers: false, invite: nil, calendar: calendar)
        #expect(shared.exercises[0].load == nil)
    }

    @Test func theFriendGetsTheSameSessionWithTheirOwnWeights() {
        let shared = SharedSession.Shared(title: "Lower body", date: "2026-10-15", minutes: 50, exercises: [
            .init(exercise: "back-squat", name: "Back Squat", sets: 4, reps: 5, load: 225, unit: "lb"),
            .init(exercise: "goblet-squat", name: "Goblet Squat", sets: 3, reps: 10),
        ])
        // Their best: 155 × 5, an estimated max of about 174.
        let history = [LoggedSet(date: thursday.addingTimeInterval(-7 * 86_400), exercise: "back-squat", pattern: nil,
                                 measurements: [Measurement(metric: "load_lb", value: 155, unit: "lb"), Measurement(metric: "reps", value: 5, unit: "reps")])]
        let workouts = SharedSession.workouts(shared, history: history, calendar: calendar)
        #expect(workouts.map(\.exercise) == ["back-squat", "goblet-squat"])
        #expect(workouts[0].target("load_lb") == 140)
        #expect(workouts[0].target("sets") == 4)
        // No history for it: theirs to fill in, not the sharer's 225.
        #expect(workouts[1].target("load_lb") == nil)
        #expect(calendar.isDate(workouts[0].date, inSameDayAs: thursday))
    }
}

/// FIT-114: the week a member shares with a group.
struct WeekShareTests {
    @MainActor @Test func oneSessionNameADayThisWeekOnly() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.firstWeekday = 2
        let day = { (d: Int, h: Int) in calendar.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h))! }
        let planned = [(date: day(12, 6), title: "Lower body"), (date: day(12, 7), title: "Lower body"),
                       (date: day(14, 6), title: "Upper body"), (date: day(19, 6), title: "Next week")]
        let week = GroupSync.week(of: day(13, 12), planned: planned, calendar: calendar)
        #expect(week.weekOf == "2026-10-11")  // The app's weeks start on Sunday (Week.start).
        #expect(week.days == [Cloud.PlannedDay(day: "2026-10-12", title: "Lower body"), Cloud.PlannedDay(day: "2026-10-14", title: "Upper body")])
    }
}
