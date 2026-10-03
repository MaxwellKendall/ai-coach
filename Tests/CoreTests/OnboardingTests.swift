import Foundation
import Testing
@testable import AICoach

private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}

private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
}

private func exercise(_ slug: String, _ pattern: String, _ equipment: [String] = [], tags: [String] = []) -> Exercise {
    Exercise(slug: slug, attributes: [
        TemplateAttribute(key: "movement_pattern", values: [pattern]),
        TemplateAttribute(key: "equipment", values: equipment),
        TemplateAttribute(key: "tags", values: tags),
    ])!
}

/// The bundled catalog's shape.
private let catalog = [
    exercise("back-squat", "squat", ["barbell", "rack"], tags: ["goal_lift"]),
    exercise("bench-press", "push", ["barbell", "bench", "rack"], tags: ["goal_lift"]),
    exercise("deadlift", "hinge", ["barbell"], tags: ["goal_lift"]),
    exercise("dumbbell-bench-press", "push", ["dumbbells"]),
    exercise("dumbbell-romanian-deadlift", "hinge", ["dumbbells"]),
    exercise("dumbbell-row", "pull", ["dumbbells"]),
    exercise("goblet-squat", "squat", ["dumbbells"]),
    exercise("plank", "core", tags: ["isometric"]),
    exercise("pull-up", "pull", ["pull_up_bar"], tags: ["goal_lift"]),
    exercise("push-up", "push", tags: ["goal_lift"]),
]
private let names = ["back-squat": "Back Squat", "bench-press": "Bench Press", "deadlift": "Deadlift",
                     "dumbbell-bench-press": "Dumbbell Bench Press", "dumbbell-romanian-deadlift": "Dumbbell Romanian Deadlift",
                     "dumbbell-row": "Dumbbell Row (Single-Arm)", "goblet-squat": "Goblet Squat", "plank": "Plank (Forearm)",
                     "pull-up": "Pull-up", "push-up": "Push-up"]

private func set(_ values: [(String, Double)]) -> StartingSet {
    StartingSet(exercise: "", measurements: values.map { Measurement(metric: $0.0, value: $0.1, unit: "") })
}

struct OnboardingTests {
    @Test func rowsFollowGoalsThenPatterns() {
        var answers = OnboardingAnswers()
        answers.goals = ["pullups", "weight"]
        #expect(answers.startRows(catalog).map(\.id) == ["age", "weight", "pull-up", "back-squat", "deadlift", "bench-press"])
        // No barbell: the rows are what's left, measured their own way.
        answers.equipment = ["dumbbells", "pull_up_bar"]
        answers.avoid = ["goblet-squat"]
        let rows = answers.startRows(catalog)
        #expect(rows.map(\.id) == ["age", "weight", "pull-up", "dumbbell-romanian-deadlift", "push-up"])
        #expect(rows.map(\.measure) == [.age, .body, .reps, .load, .reps])
        #expect(OnboardingAnswers.measure(catalog[7]) == .hold)
    }

    @Test func suggestedTargets() {
        var answers = OnboardingAnswers()
        answers.age = 36
        answers.weight = 200
        answers.weeks = 16
        let weight = GoalOption.with(id: "weight")!, squat = GoalOption.with(id: "squat")!, pullups = GoalOption.with(id: "pullups")!
        // A pound a week: 184 → 185.
        #expect(answers.suggestedTarget(weight) == 185)
        // No starting point: the 30–39 tier, 1.25 × body weight.
        #expect(answers.suggestedTarget(squat) == 250)
        #expect(answers.suggestedTarget(pullups) == 10)
        answers.starts["back-squat"] = set([("load_lb", 150), ("reps", 5)])
        answers.starts["pull-up"] = set([("reps", 5)])
        #expect(answers.baseline(squat) == 169)
        // +16%: 196 → 195. Reps: 5 + 8, at most double.
        #expect(answers.suggestedTarget(squat) == 195)
        #expect(answers.suggestedTarget(pullups) == 10)
        answers.targets["pullups"] = 12
        #expect(answers.target(pullups) == 12)
        #expect(pullups.title(target: 12) == "12 pull-ups")
    }

    @Test func recentBestFromLogs() {
        let squat = catalog[0], pullUp = catalog[8]
        func logged(_ exercise: String, _ day: Int, _ values: [(String, Double)]) -> LoggedSet {
            LoggedSet(date: date(2026, 7, day), exercise: exercise, pattern: nil,
                      measurements: values.map { Measurement(metric: $0.0, value: $0.1, unit: "") })
        }
        let history = [logged("back-squat", 1, [("load_lb", 155), ("reps", 5), ("rpe", 8)]),
                       logged("back-squat", 8, [("load_lb", 165), ("reps", 5)]),
                       logged("back-squat", 9, [("load_lb", 135), ("reps", 10)]),
                       logged("pull-up", 8, [("reps", 6)]), logged("pull-up", 9, [("reps", 5)])]
        let best = OnboardingAnswers.recentBest(history, exercise: squat, before: date(2026, 10, 3), calendar: calendar)
        #expect(best?.value("load_lb") == 165)
        #expect(best?.value("rpe") == nil)
        #expect(OnboardingAnswers.recentBest(history, exercise: pullUp, before: date(2026, 10, 3), calendar: calendar)?.value("reps") == 6)
        #expect(OnboardingAnswers.recentBest(history, exercise: catalog[7], before: date(2026, 10, 3), calendar: calendar) == nil)
    }

    @Test func spokenDates() {
        let now = date(2026, 10, 3)
        #expect(SpokenDates.date(in: "by the end of February", after: now, calendar: calendar) == date(2027, 2, 28))
        #expect(SpokenDates.date(in: "by March 1st", after: now, calendar: calendar) == date(2027, 3, 1))
        #expect(SpokenDates.date(in: "start of December", after: now, calendar: calendar) == date(2026, 12, 1))
        #expect(SpokenDates.date(in: "in twelve weeks", after: now, calendar: calendar)
            == calendar.date(byAdding: .weekOfYear, value: 12, to: now))
        #expect(SpokenDates.date(in: "get to 180", after: now, calendar: calendar) == nil)
    }

    /// The prototype's sentence: goals and numbers said, a date that sets the length; a number not said is dropped.
    @Test func heardGoals() {
        var answers = OnboardingAnswers()
        answers.heardGoals([("weight", 180), ("pullups", 10), ("squat", 225), ("run", nil)],
                           in: "I want to get to 180 and do 10 strict pull-ups and squat more by the end of February",
                           now: date(2026, 10, 3), calendar: calendar)
        #expect(answers.goals == ["weight", "pullups", "squat"])
        #expect(answers.targets == ["weight": 180, "pullups": 10])
        #expect(answers.weeks == 22)
        #expect(answers.unconfirmed == ["goals", "target.weight", "target.pullups", "weeks"])
    }

    @Test func heardExercises() {
        var answers = OnboardingAnswers()
        answers.heardExercises(without: ["front squats", "barbell"], with: ["Romanian deadlifts", "push-ups"], catalog: catalog, names: names)
        #expect(!answers.equipment.contains("barbell"))
        #expect(answers.avoid.isEmpty)
        #expect(answers.unconfirmed == ["move.dumbbell-romanian-deadlift", "move.push-up"])
        answers.heardExercises(without: ["squats"], with: [], catalog: catalog, names: names)
        #expect(answers.avoid == ["back-squat", "goblet-squat"])
        #expect(OnboardingAnswers.equipment(named: "a pull-up bar") == "pull_up_bar")
        #expect(OnboardingAnswers.equipment(named: "bench press") == nil)
    }

    @Test func heardStarts() {
        var answers = OnboardingAnswers()
        answers.goals = ["pushups"]
        answers.heardStarts([("push-ups", nil, 25, nil), ("squat", 155, 5, nil), ("deadlift", 300, nil, nil), ("plank", nil, nil, 90)],
                            age: 36, bodyWeight: 200, in: "I'm 36 and 200 pounds, about 25 push-ups, and I squat 155 for 5",
                            catalog: catalog, names: names)
        #expect(answers.age == 36)
        #expect(answers.weight == 200)
        #expect(answers.starts["push-up"]?.value("reps") == 25)
        // "Squat" is the back squat, the row on screen; the deadlift and plank numbers weren't said.
        #expect(answers.starts["back-squat"]?.value("load_lb") == 155)
        #expect(answers.starts["goblet-squat"] == nil)
        #expect(answers.starts["deadlift"] == nil)
        #expect(answers.starts["plank"] == nil)
    }

    @Test func heardSchedule() {
        var answers = OnboardingAnswers()
        answers.heardSchedule("Monday, Wednesday, Friday, about 45 minutes. My left knee gets cranky")
        #expect(answers.days == [0, 2, 4])
        #expect(answers.minutes == 45)
        #expect(answers.hurts == ["knees"])
        answers.heardSchedule("an hour on Tuesdays and Saturdays, my lower back is tight")
        #expect(answers.days == [1, 5])
        #expect(answers.minutes == 60)
        #expect(answers.hurts == ["knees", "lower back"])
    }
}
