import Foundation
@testable import AICoach

/// FIT-97: how the 12-week probe logs each designed week: like a person, not exactly as planned, so the scores show
/// whether the model adjusts (FIT-96). Deterministic, so every model is scored on the same weeks.
enum ProbeLog {
    static let description = "Logged like a person: about one session in four skipped, and every third week the main lifts' last set a rep short at RPE 9.5."

    /// A session is skipped when its week and its place in the week add up to 3, 7, 11…: about one in four.
    static func skips(week index: Int, session position: Int) -> Bool { (index + position) % 4 == 3 }

    /// Every third week, a hard one.
    static func falls(short index: Int) -> Bool { index % 3 == 2 }

    static func log(_ week: TrainingWeek, index: Int, patterns: [String: String]) -> [LoggedSet] {
        let rows = week.workouts.filter { $0.note != TrainingGenerator.warmupNote }
        let days = Set(rows.map(\.date)).sorted()
        var logged: [LoggedSet] = []
        for (position, day) in days.enumerated() where !skips(week: index, session: position) {
            for row in rows where row.date == day {
                let sets = Int(row.target("sets") ?? 0)
                for set in 0..<sets {
                    var measurements = row.targets.filter { $0.metric != "sets" }
                    if row.main, falls(short: index), set == sets - 1 {
                        measurements = measurements.map { $0.metric == "reps" ? Measurement(metric: "reps", value: max(1, $0.value - 1), unit: "reps") : $0 }
                            .filter { $0.metric != "rpe" } + [Measurement(metric: "rpe", value: 9.5, unit: "RPE")]
                    }
                    logged.append(LoggedSet(date: row.date, exercise: row.exercise, pattern: patterns[row.exercise], measurements: measurements))
                }
            }
        }
        return logged
    }
}
