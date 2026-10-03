import Testing
@testable import AICoach

struct SaidChecksTests {
    let library = ["Back Squat", "Split Squat", "Bench Press", "Pull-up", "Dumbbell Row (Single-Arm)", "Plank (Forearm)", "Dead Bug"]

    @Test func namedExercisesAreWholeNames() {
        #expect(SaidChecks.named(in: "Give me squats and split squat for today", library: library) == ["Split Squat"])
        #expect(SaidChecks.named(in: "Skip the bench press", library: library) == ["Bench Press"])
        #expect(SaidChecks.named(in: "just pull-ups and planks", library: library) == ["Pull-up", "Plank (Forearm)"])
        #expect(SaidChecks.named(in: "Drop the dead bugs", library: library) == ["Dead Bug"])
        // A kind of day isn't an exercise.
        for said in ["Plan me a pull day", "Make it a leg day", "Give me a quick core workout", "Dumbbells only today", "Regenerate today's workout"] {
            #expect(SaidChecks.named(in: said, library: library).isEmpty, "\(said)")
        }
    }

    @Test func aWorkoutIsAskedForByItsKind() {
        for said in ["Make it a leg day", "Upper body only today", "Nothing for legs today", "Plan me a pull day", "Give me a workout",
                     "Dumbbells only today", "Mix it up, I'm bored of this one", "Regenerate this workout", "Give me a 30 minute dumbbell workout",
                     "Give me a completely different workout today", "Give me a full body workout instead"] {
            #expect(SaidChecks.asksForAWorkout(said), "\(said)")
        }
        #expect(!SaidChecks.asksForAWorkout("Give me squats and split squat for today"))
        #expect(!SaidChecks.asksForAWorkout("I want to do pull-ups and push-ups"))
    }

    @Test func everyAndJust() {
        #expect(SaidChecks.meansEvery("Make everything 4 sets"))
        #expect(SaidChecks.meansEvery("every exercise 4 sets"))
        #expect(SaidChecks.meansEvery("all of them 3 sets"))
        #expect(!SaidChecks.meansEvery("Drop the dead bugs and add planks"))
        #expect(!SaidChecks.meansEvery("Add a set to deadlifts"))
        #expect(SaidChecks.meansJustThese("Just bench and plank"))
        #expect(SaidChecks.meansJustThese("only pull-ups"))
        #expect(!SaidChecks.meansJustThese("Skip the bench, just kidding"))
        #expect(!SaidChecks.meansJustThese("Upper body only today"))
    }

    @Test func nothingForLegs() {
        #expect(SaidChecks.rulesOutLegs("Nothing for legs today"))
        #expect(SaidChecks.rulesOutLegs("No lower body today"))
        #expect(SaidChecks.rulesOutLegs("skip legs"))
        #expect(!SaidChecks.rulesOutLegs("Make it a leg day"))
        #expect(!SaidChecks.rulesOutLegs("No bench today, legs instead"))
        #expect(!SaidChecks.rulesOutLegs("Give me squats and lunges"))
    }

    /// Each phrase the evals use gets the tool that makes its change (and few others: every tool costs about 0.4 s).
    @Test func eachRequestGetsItsTool() {
        let cases: [(said: String, needs: String, today: Bool)] = [
            ("Swap deadlifts for RDLs", "swap_exercise", true), ("RDLs instead of deadlifts today", "swap_exercise", true),
            ("Replace bench with push-ups", "swap_exercise", true), ("Do dumbbell bench instead of barbell", "swap_exercise", true),
            ("Um can we do back squats instead of goblet squats", "swap_exercise", true), ("Swap the goblet squat for lunges", "swap_exercise", true),
            ("No bench today", "remove_exercises", true), ("Skip the bench press", "remove_exercises", true), ("No pull-ups today", "remove_exercises", true),
            ("Drop the dead bugs and add planks", "remove_exercises", true), ("Drop the dead bugs and add planks", "add_exercise", true),
            ("Just pull-ups and rows today", "only_these", true), ("Just bench and plank", "only_these", true),
            ("Give me squats and split squat for today", "only_these", true), ("Give me squats and split squat for today", "only_these", false),
            ("I want to do pull-ups and push-ups", "only_these", false),
            ("Add some curls at the end", "add_exercise", true), ("Add farmer carries", "add_exercise", true), ("Add face pulls", "add_exercise", true),
            ("Deadlift 3 sets of 5 at 225", "add_exercise", false),
            ("Make everything 4 sets", "change_exercise", true), ("Add a set to deadlifts", "change_exercise", true),
            ("Only two sets of bench", "change_exercise", true), ("Bump the deadlift to 225", "change_exercise", true),
            ("I want to do 8 reps on goblet squats", "change_exercise", true), ("Make the plank a minute", "change_exercise", true),
            ("Bench 165 today", "change_exercise", true),
            ("Make it a leg day", "new_workout", true), ("Upper body only today", "new_workout", true), ("Nothing for legs today", "new_workout", true),
            ("Regenerate today's workout", "new_workout", true), ("Mix it up, I'm bored of this one", "new_workout", true),
            ("Dumbbells only today", "new_workout", true), ("Plan me a pull day", "new_workout", false), ("Give me a quick core workout", "new_workout", false),
            ("Give me a 30 minute dumbbell workout", "new_workout", false), ("Give me a completely different workout today", "new_workout", true),
            ("Give me a harder workout", "harder_or_easier", true), ("Make it easier today", "harder_or_easier", true),
        ]
        for (said, needs, today) in cases {
            let tools = SaidChecks.tools(for: said, today: today)
            #expect(tools.contains(needs), "\(said): \(tools)")
            #expect(Set(tools).isSubset(of: SaidChecks.all(today)), "\(said): \(tools)")
        }
        // Words that point at nothing get every tool, and a rest day never gets a tool that needs today's workout.
        #expect(SaidChecks.tools(for: "hmm okay", today: true) == SaidChecks.all(true))
        #expect(SaidChecks.all(false) == ["add_exercise", "only_these", "new_workout"])
        #expect(SaidChecks.tools(for: "Swap deadlifts for RDLs", today: true) == ["swap_exercise"])
        #expect(SaidChecks.tools(for: "Nothing for legs today", today: true) == ["new_workout"])
    }
}
