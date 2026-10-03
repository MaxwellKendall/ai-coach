import Foundation
import Testing
@testable import AICoach

private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}

private func date(_ month: Int, _ day: Int, hour: Int = 12) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
}

private func value(_ month: Int, _ day: Int, _ value: Double) -> DatedValue { DatedValue(date: date(month, day), value: value) }

/// The prototype's week: Monday Sep 28 to Sunday Oct 4, sessions Monday, Wednesday and Friday.
struct WeeklyReviewTests {
    let week = WeeklyReview.days(of: date(10, 4), calendar: calendar)
    let sessions = [date(9, 28), date(9, 30), date(10, 2)]

    @Test func weekIsMondayToSunday() {
        #expect(week.lowerBound == calendar.startOfDay(for: date(9, 28)))
        #expect(week.contains(date(10, 4, hour: 23)))
        #expect(!week.contains(date(10, 5, hour: 0)))
    }

    @Test func numbers() {
        func set(_ day: Int, _ pattern: String) -> LoggedSet {
            LoggedSet(date: day > 20 ? date(9, day) : date(10, day), exercise: "x", pattern: pattern, measurements: [])
        }
        let sets = [set(28, "squat"), set(28, "pull"), set(30, "push"), set(30, "pull"), set(2, "pull"), set(21, "push")]
        let numbers = WeeklyReview.numbers(week: week, workoutDays: sessions, sets: sets,
                                           protein: [value(9, 28, 130), value(9, 29, 146)], kcal: [], sleep: [value(9, 30, 7)],
                                           weighIns: [value(9, 27, 195.2), value(10, 1, 195), value(10, 3, 194.6)], calendar: calendar)
        #expect(numbers.workoutsDone == 3 && numbers.workoutsPlanned == 3 && numbers.sets == 5)
        #expect(numbers.protein == 138 && numbers.kcal == nil && numbers.sleep == 7)
        #expect(numbers.weight == 194.6)
        #expect(abs(numbers.weightChange! + 0.6) < 0.001)
        #expect(numbers.push == 1 && numbers.pull == 3)
    }

    @Test func proteinSleepAndCalorieAlerts() {
        let protein = [value(9, 27, 104), value(9, 28, 150), value(9, 29, 140), value(9, 30, 112), value(10, 1, 160), value(10, 2, 150)]
        let alerts = WeeklyReview.alerts(week: week, workoutDays: sessions, protein: protein,
                                         kcal: [value(9, 28, 2_400), value(10, 2, 1_950)],
                                         sleep: [value(9, 30, 5.5), value(10, 2, 7)], notes: [], injured: [], calendar: calendar)
        #expect(alerts.map(\.title) == ["Protein under 120 g around 2 workouts", "Under 6 h of sleep before 1 workout",
                                        "Under 2,200 kcal on 1 training day"])
        // The lower of the day before and the day of.
        #expect(alerts[0].detail == "Sunday 104 g and Wednesday 112 g.")
        #expect(alerts[2].detail == "Friday 1,950.")
    }

    @Test func samePainAreaThreeTimes() {
        let notes = [(date(9, 21), "left knee a bit sore on the way down"), (date(9, 30), "knee pain on squats"),
                     (date(10, 3), "knee tight again"), (date(10, 1), "great session, knee felt fine"),
                     (date(8, 20), "knee ached"), (date(10, 2), "lower back tight")]
        let alerts = WeeklyReview.alerts(week: week, workoutDays: [], protein: [], kcal: [], sleep: [], notes: notes,
                                         injured: [], calendar: calendar)
        #expect(alerts.map(\.title) == ["Knee came up in 3 notes"])
        #expect(alerts[0].area == "knee")
        #expect(alerts[0].detail.hasPrefix("Sep 21, Sep 30 and Oct 3."))
        // Already an injury: nothing to propose.
        #expect(WeeklyReview.alerts(week: week, workoutDays: [], protein: [], kcal: [], sleep: [], notes: notes,
                                    injured: ["knees"], calendar: calendar).isEmpty)
    }

    /// The prototype's check-in after week 8 of 16: pull-ups ahead, weight behind.
    @Test func checkInEveryFourWeeks() {
        let pullups = WeeklyReview.checkIn(from: 6, now: 9, target: 10, pace: .ahead, forecast: 12, step: 1, week: 7, weeks: 16)
        #expect(pullups == WeeklyReview.CheckIn(proposed: 12, ahead: true, weeksLeft: 8))
        let weight = WeeklyReview.checkIn(from: 201, now: 194.6, target: 180, pace: .behind, forecast: 188.2, step: 5, week: 7, weeks: 16)
        #expect(weight == WeeklyReview.CheckIn(proposed: 190, ahead: false, weeksLeft: 8))
        // Ahead but the forecast is only just past the goal: still a step up.
        #expect(WeeklyReview.checkIn(from: 6, now: 9, target: 10, pace: .ahead, forecast: 10.2, step: 1, week: 7, weeks: 16)?.proposed == 11)
        #expect(WeeklyReview.checkIn(from: 6, now: 9, target: 10, pace: .ahead, forecast: 12, step: 1, week: 6, weeks: 16) == nil)
        #expect(WeeklyReview.checkIn(from: 6, now: 9, target: 10, pace: .ahead, forecast: 12, step: 1, week: 11, weeks: 14) == nil)
        #expect(WeeklyReview.checkIn(from: 201, now: 194.6, target: 180, pace: .onPace, forecast: 181, step: 5, week: 7, weeks: 16) == nil)
    }
}
