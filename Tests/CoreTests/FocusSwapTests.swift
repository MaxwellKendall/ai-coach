import Foundation
import Testing
@testable import AICoach

/// FIT-33: "make today a squat day".
struct FocusSwapTests {
    private let friday = Date(timeIntervalSince1970: 1_784_552_400 + 4 * 86_400) // 2026-07-24 07:00 New York
    private var sunday: Date { friday + 2 * 86_400 }
    private let names = ["back-squat": "Back Squat", "goblet-squat": "Goblet Squat", "bench-press": "Bench Press",
                         "deadlift": "Deadlift", "dumbbell-row": "Dumbbell Row (Single-Arm)", "dead-bug": "Dead Bug",
                         "pull-up": "Pull-up"]
    private var catalog: [Exercise] {
        [("back-squat", "squat", true), ("goblet-squat", "squat", false), ("bench-press", "push", true),
         ("deadlift", "hinge", true), ("dumbbell-row", "pull", false), ("dead-bug", "core", false), ("pull-up", "pull", false)].map {
            Exercise(slug: $0.0, attributes: [TemplateAttribute(key: "movement_pattern", values: [$0.1]),
                                              TemplateAttribute(key: "tags", values: $0.2 ? ["goal_lift"] : [])])!
        }
    }

    private func workout(_ exercise: String, _ date: Date, session: String, load: Double? = nil) -> PlannedWorkout {
        PlannedWorkout(date: date, session: session, exercise: exercise,
                       targets: [Measurement(metric: "sets", value: 3, unit: "sets")]
                           + (load.map { [Measurement(metric: "load_lb", value: $0, unit: "lb")] } ?? []))
    }

    private var week: TrainingWeek {
        TrainingWeek(workouts: [workout("bench-press", friday, session: "Session B", load: 140),
                                workout("deadlift", friday, session: "Session B", load: 225),
                                workout("back-squat", sunday, session: "Session A", load: 185),
                                workout("pull-up", sunday, session: "Session A")], deload: false, warnings: [])
    }

    @Test func readsWhatWasAskedFor() {
        func wanted(_ text: String) -> Set<String>? { FocusSwap.wanted(text, catalog: catalog, names: names) }
        #expect(wanted("Make today a squat day") == ["back-squat", "goblet-squat"])
        #expect(wanted("can I do legs today") == ["back-squat", "goblet-squat", "deadlift"])
        #expect(wanted("switch to deadlifts today") == ["deadlift"])
        #expect(wanted("I'd rather do bench") == ["bench-press"])
        #expect(wanted("I only have thirty minutes") == nil)
        #expect(wanted("did squats, all five") == nil) // saying what was done, not asking
        #expect(wanted("move it to Saturday instead") == nil)
    }

    @Test func todayTradesPlacesWithTheDayThatHasIt() {
        let result = FocusSwap.swap(week, on: friday, wanted: ["back-squat", "goblet-squat"], catalog: catalog)
        guard case .swapped(let swapped, let other) = result else { Issue.record("\(result)"); return }
        #expect(other == sunday)
        #expect(swapped.workouts.filter { $0.date == friday }.map(\.exercise) == ["back-squat", "pull-up"])
        #expect(swapped.workouts.filter { $0.date == sunday }.map(\.exercise) == ["bench-press", "deadlift"])
        #expect(swapped.workouts.first { $0.exercise == "back-squat" }?.target("load_lb") == 185) // loads stay
    }

    @Test func alreadyThereOrNowhereElse() {
        #expect(FocusSwap.swap(week, on: friday, wanted: ["deadlift"], catalog: catalog) == .already)
        let result = FocusSwap.swap(week, on: friday, wanted: ["goblet-squat", "dead-bug"], catalog: catalog)
        guard case .replaced(let replaced, let slug) = result else { Issue.record("\(result)"); return }
        #expect(slug == "dead-bug") // neither is a goal lift, so alphabetical
        #expect(replaced.workouts.filter { $0.date == friday }.map(\.exercise) == ["dead-bug", "deadlift"])
        #expect(replaced.workouts[0].target("load_lb") == nil) // the bench load doesn't transfer
        let squat = FocusSwap.swap(TrainingWeek(workouts: Array(week.workouts.prefix(2)), deload: false, warnings: []),
                                   on: friday, wanted: ["back-squat", "goblet-squat"], catalog: catalog)
        guard case .replaced(_, let main) = squat else { Issue.record("\(squat)"); return }
        #expect(main == "back-squat") // the goal lift first
    }
}

extension FocusSwapTests {
    @Test func aRestDayGetsTheRotationSessionThatHasIt() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let saturday = calendar.date(from: DateComponents(year: 2026, month: 7, day: 25, hour: 9))!
        let settings = TrainingSettings(age: 36, daysPerWeek: 3, sessionMinutes: 45, trainingDays: [0, 2, 4], workoutTime: 7 * 60,
                                        equipment: [], maxWeeklySets: 60, warmups: false)
        // Squat was trained Monday, so the plan would reach Session B next; asking for squats gets Session A.
        let history = [LoggedSet(date: saturday - 5 * 86_400, exercise: "back-squat", pattern: "squat",
                                 measurements: [Measurement(metric: "reps", value: 5, unit: "reps"),
                                                Measurement(metric: "load_lb", value: 185, unit: "lb"),
                                                Measurement(metric: "rpe", value: 7, unit: "RPE")])]
        let squat = TrainingGenerator.session(on: saturday, wanting: ["back-squat"], settings: settings, catalog: catalog,
                                              history: history, weeksSinceDeload: 1, calendar: calendar)
        #expect(squat?.first?.session == "Session A")
        #expect(squat?.allSatisfy { calendar.isDate($0.date, inSameDayAs: saturday) } == true)
        #expect(squat?.first { $0.exercise == "back-squat" }?.target("load_lb") == 190) // progressed from Monday
        let bench = TrainingGenerator.session(on: saturday, wanting: ["bench-press"], settings: settings, catalog: catalog,
                                              history: history, weeksSinceDeload: 1, calendar: calendar)
        #expect(bench?.first?.session == "Session B")
        #expect(TrainingGenerator.session(on: saturday, wanting: ["farmer-carry"], settings: settings, catalog: catalog,
                                          history: history, weeksSinceDeload: 1, calendar: calendar) == nil)
    }
}
