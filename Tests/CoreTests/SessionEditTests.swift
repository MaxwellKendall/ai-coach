import Foundation
import Testing
@testable import AICoach

/// FIT-46: "give me squats and split squats today".
struct SessionEditTests {
    private let saturday = Date(timeIntervalSince1970: 1_784_552_400 + 5 * 86_400) // 2026-07-25 07:00 New York
    private let library = ["back-squat": "Back Squat", "goblet-squat": "Goblet Squat", "bench-press": "Bench Press",
                           "deadlift": "Deadlift", "dumbbell-romanian-deadlift": "Dumbbell Romanian Deadlift",
                           "dumbbell-row": "Dumbbell Row (Single-Arm)", "dead-bug": "Dead Bug", "pull-up": "Pull-up"]
    private var catalog: [Exercise] {
        [("back-squat", "squat", true), ("goblet-squat", "squat", false), ("bench-press", "push", true),
         ("deadlift", "hinge", true), ("dumbbell-romanian-deadlift", "hinge", false), ("dumbbell-row", "pull", false),
         ("dead-bug", "core", false), ("pull-up", "pull", false), ("split-squat", "squat", false)].map {
            Exercise(slug: $0.0, attributes: [TemplateAttribute(key: "movement_pattern", values: [$0.1]),
                                              TemplateAttribute(key: "tags", values: $0.2 ? ["goal_lift"] : [])])!
        }
    }
    private let settings = TrainingSettings(age: 36, daysPerWeek: 3, sessionMinutes: 45, trainingDays: [0, 2, 4], workoutTime: 7 * 60,
                                            equipment: [], maxWeeklySets: 60, warmups: false)

    private func row(_ exercise: String, sets: Double, load: Double? = nil, note: String? = nil) -> PlannedWorkout {
        PlannedWorkout(date: saturday, session: "Lower", exercise: exercise,
                       targets: [Measurement(metric: "sets", value: sets, unit: "sets")]
                           + (load.map { [Measurement(metric: "load_lb", value: $0, unit: "lb")] } ?? []), note: note)
    }

    private var lower: [PlannedWorkout] {
        [row("back-squat", sets: 1, load: 110, note: TrainingGenerator.warmupNote), row("back-squat", sets: 4, load: 185),
         row("goblet-squat", sets: 3, load: 50), row("deadlift", sets: 3, load: 225), row("dead-bug", sets: 3)]
    }

    private func resolve(_ names: [String], _ said: String, today: Set<String> = []) -> SessionEdit.Resolved {
        SessionEdit.resolve(names, said: said, library: library, catalog: catalog, today: today)
    }

    @Test func namesAreMatchedToTheLibraryOnlyWhenSaid() {
        let said = "Give me squats and split squat for today"
        // A plain "squats" is the one already today, else the goal lift; split squat isn't in the library.
        #expect(resolve(["Squats", "Split Squat"], said, today: ["goblet-squat"]) == .init(slugs: ["goblet-squat"], unknown: ["Split Squat"]))
        #expect(resolve(["squats", "split squats"], said) == .init(slugs: ["back-squat"], unknown: ["split squats"]))
        #expect(resolve(["Back Squat"], said).slugs == ["back-squat"])
        // The model mapped RDLs to the library; the initials were said.
        #expect(resolve(["Dumbbell Romanian Deadlift"], "swap deadlifts for RDLs").slugs == ["dumbbell-romanian-deadlift"])
        #expect(resolve(["Deadlift"], "no deadlifts today").slugs == ["deadlift"])
        #expect(resolve(["Pull-up", "Dumbbell Row (Single-Arm)"], "just pull-ups and rows").slugs == ["pull-up", "dumbbell-row"])
        // Embellished by the model: only the words said count.
        #expect(resolve(["Bent-over Row"], "just pull-ups and rows today").slugs == ["dumbbell-row"])
        #expect(resolve(["Bulgarian Split Squat"], "give me split squats").unknown == ["Split Squat"])
        // Never said: dropped, whether in the library or not.
        #expect(resolve(["Bench Press", "Lunge", "Bulgarian Split Squat"], said) == .init(unknown: ["Split Squat"]))
    }

    @Test func anAskedExerciseTakesTheSamePatternsPlace() {
        let rebuilt = SessionEdit.rebuild(lower, add: ["back-squat", "split-squat"], remove: [], only: false, date: saturday,
                                          session: "Lower", catalog: catalog, settings: settings, history: [])
        // Back squat was already there and stays; split squat takes the goblet squat's place and its 3 sets.
        #expect(rebuilt.map(\.exercise) == ["back-squat", "back-squat", "split-squat", "deadlift", "dead-bug"])
        let split = rebuilt[2]
        #expect(split.target("sets") == 3 && split.target("reps") != nil && split.target("load_lb") == nil)
        #expect(split.session == "Lower" && split.date == saturday && split.adjustedReason == "asked for split-squat")
        #expect(rebuilt[1].target("load_lb") == 185) // untouched rows keep their targets
    }

    @Test func swapsRemovesAndOnly() {
        func rebuild(_ add: [String], remove: Set<String> = [], only: Bool = false) -> [String] {
            SessionEdit.rebuild(lower, add: add, remove: remove, only: only, date: saturday, session: "Lower",
                                catalog: catalog, settings: settings, history: []).map(\.exercise)
        }
        #expect(rebuild(["dumbbell-romanian-deadlift"], remove: ["deadlift"])
                == ["back-squat", "back-squat", "goblet-squat", "dumbbell-romanian-deadlift", "dead-bug"])
        #expect(rebuild([], remove: ["back-squat"]) == ["goblet-squat", "deadlift", "dead-bug"]) // its warm-up goes too
        #expect(rebuild(["pull-up"]) == ["back-squat", "back-squat", "goblet-squat", "deadlift", "dead-bug", "pull-up"])
        #expect(rebuild(["pull-up", "dumbbell-row"], only: true) == ["pull-up", "dumbbell-row"])
        // A rest day: just what was asked for.
        let rest = SessionEdit.rebuild([], add: ["back-squat"], remove: [], only: false, date: saturday, session: "Workout",
                                       catalog: catalog, settings: settings, history: [])
        #expect(rest.map(\.exercise) == ["back-squat"] && rest[0].target("sets") == 3)
    }

    @Test func codeCatchesAnExerciseTheModelLeftOut() {
        func mentioned(_ said: String, covered: [String]) -> [String] {
            SessionEdit.mentioned(said, library: library, catalog: catalog, today: [], covered: covered)
        }
        #expect(mentioned("just pull-ups and rows today", covered: ["pull-up"]) == ["dumbbell-row"])
        // Its words are already in a listed name: the model's pick stands.
        #expect(mentioned("give me squats and split squat for today", covered: ["goblet-squat", "Split Squat"]) == [])
        #expect(mentioned("swap deadlifts for RDLs", covered: ["dumbbell-romanian-deadlift", "deadlift"]) == [])
        #expect(mentioned("no bench today", covered: ["bench-press"]) == [])
        #expect(mentioned("give me squats", covered: []) == ["back-squat"])
    }

    @Test func aSwapSaysWhatGoes() {
        #expect(SessionEdit.swappedOut("swap deadlifts for RDLs") == "deadlifts")
        #expect(SessionEdit.swappedOut("Replace the bench press with push-ups today") == "bench press")
        #expect(SessionEdit.swappedOut("RDLs instead of deadlifts today") == "deadlifts")
        #expect(SessionEdit.swappedOut("give me squats and split squat for today") == nil)
        #expect(resolve(["deadlifts"], "swap deadlifts for RDLs").slugs == ["deadlift"])
    }

    @Test func anExerciseListedBothWaysIsSettledByTheWords() {
        // The model's lists for "just pull-ups and rows": the rows are also in its removals.
        #expect(SessionEdit.settle(add: ["pull-up", "dumbbell-row"], remove: ["dumbbell-row", "deadlift"], only: true,
                                   said: "just pull-ups and rows") == (["pull-up", "dumbbell-row"], []))
        #expect(SessionEdit.settle(add: ["bench-press"], remove: ["bench-press"], only: false, said: "no bench today") == ([], ["bench-press"]))
        #expect(SessionEdit.settle(add: ["bench-press"], remove: ["bench-press"], only: false, said: "don't skip bench") == ([], ["bench-press"]))
        #expect(SessionEdit.settle(add: ["back-squat"], remove: ["back-squat", "deadlift"], only: false, said: "give me squats")
                == (["back-squat"], ["deadlift"]))
    }

    @Test func aKindOfDayTradesDaysButNamedExercisesRebuildToday() {
        #expect(FocusSwap.asksForADay("Make today a squat day"))
        #expect(FocusSwap.asksForADay("can I do legs today"))
        #expect(!FocusSwap.asksForADay("swap deadlifts for RDLs"))
        #expect(!FocusSwap.asksForADay("give me squats and split squat for today"))
        #expect(!FocusSwap.asksForADay("just pull-ups and rows today"))
    }

    @Test func aDraftedExerciseKeepsOnlyWhatThePlannerKnows() {
        let seed = NewExercise.seed(NewExerciseDraft(name: "Split Squat", pattern: "squat", equipment: ["dumbbells", "kettlebell"],
                                                     muscles: ["quads", "glutes", "soul"], timed: false), said: "split squats")
        #expect(seed.slug == "split-squat")
        #expect(seed.name == "Split Squat")
        let exercise = Exercise(slug: seed.slug, attributes: seed.attributes)
        #expect(exercise?.pattern == "squat" && exercise?.equipment == ["dumbbells"] && exercise?.muscles == ["quads", "glutes"])
        #expect(NewExercise.seed(NewExerciseDraft(name: "Bulgarian Split Squat", pattern: "squat", equipment: [], muscles: [], timed: false),
                                 said: "split squat").name == "Split Squat") // nothing added that wasn't said
    }
}
