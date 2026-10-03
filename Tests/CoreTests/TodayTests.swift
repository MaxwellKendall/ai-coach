import Foundation
import Testing
@testable import AICoach

private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}

private func date(_ day: Int, hour: Int = 12) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 6, day: day, hour: hour))!
}

private func set(_ day: Int, _ load: Double, _ reps: Double, rpe: Double? = 7, exercise: String = "back-squat") -> LoggedSet {
    LoggedSet(date: date(day), exercise: exercise, pattern: "squat",
              measurements: [Measurement(metric: "load_lb", value: load, unit: "lb"),
                             Measurement(metric: "reps", value: reps, unit: "reps")]
                  + (rpe.map { [Measurement(metric: "rpe", value: $0, unit: "RPE")] } ?? []))
}

struct TodayTests {
    @Test func trendIsBestPerDayAndNeverRegresses() {
        let sets = [set(1, 135, 5), set(1, 155, 5), set(3, 145, 5), set(5, 175, 5, rpe: 9), set(8, 165, 5),
                    set(8, 300, 5, exercise: "deadlift")]
        let trend = Training.estimated1RMTrend(sets, exercise: "back-squat", calendar: calendar)
        #expect(trend.map(\.date) == [1, 3, 8].map { calendar.startOfDay(for: date($0)) })
        #expect(trend.map { Int($0.value.rounded()) } == [174, 174, 186]) // day 5 is RPE 9, so no estimate
    }

    @Test func dailyTotalsSumPerDayAndSkipUnloggedDays() {
        let protein = { (grams: Double) in [Measurement(metric: "protein_g", value: grams, unit: "g")] }
        let totals = Daily.totals([(date(2, hour: 8), protein(40)), (date(1), protein(30)), (date(2, hour: 19), protein(60)),
                                   (date(3), [Measurement(metric: "kcal", value: 500, unit: "kcal")])],
                                  metric: "protein_g", calendar: calendar)
        #expect(totals == [DatedValue(date: calendar.startOfDay(for: date(1)), value: 30),
                           DatedValue(date: calendar.startOfDay(for: date(2)), value: 100)])
    }

    @Test(arguments: [
        ([Measurement(metric: "sets", value: 3, unit: "sets"), Measurement(metric: "reps", value: 5, unit: "reps"),
          Measurement(metric: "load_lb", value: 155, unit: "lb")], "3×5 @ 155 lb"),
        ([Measurement(metric: "sets", value: 3, unit: "sets"), Measurement(metric: "duration_s", value: 45, unit: "s")],
         "3 sets 45 s"),
        ([], ""),
        ([Measurement(metric: "sets", value: 3, unit: "sets"), Measurement(metric: "reps", value: 5, unit: "reps"),
          Measurement(metric: "rpe", value: 8, unit: "RPE")], "3×5 RPE 8"),
    ])
    func plannedTargetsRead(_ targets: [AICoach.Measurement], _ expected: String) {
        #expect(Coach.targets(targets) == expected)
    }
}
