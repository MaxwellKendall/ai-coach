import Testing
@testable import AICoach

@Suite("FIT-297: the warm-up ramp on Today")
struct WarmupRampTests {
    @Test func rampsFromTheBarToTheWorkingWeight() {
        #expect(WarmupRamp.steps(to: 170) == [.init(load: 45, reps: 10), .init(load: 95, reps: 5), .init(load: 130, reps: 3), .init(load: 155, reps: 2)])
        #expect(WarmupRamp.minutes(to: 170) == 9)
    }

    @Test func aLightLiftRampsInFewerSteps() {
        // 55% of 95 rounds to 50, then 70 and 85: all heavier than the step before and lighter than 95.
        #expect(WarmupRamp.steps(to: 95).map(\.load) == [45, 50, 70, 85])
        // 75% of 60 is 45, no heavier than the bar, so it's left out.
        #expect(WarmupRamp.steps(to: 60).map(\.load) == [45, 55])
    }

    @Test func noRampAtOrBelowTheBar() {
        #expect(WarmupRamp.steps(to: 45).isEmpty)
        #expect(WarmupRamp.steps(to: 0).isEmpty)
    }
}

@Suite("FIT-297: a session named by its lifts")
@MainActor
struct SessionTitleTests {
    @Test func liftsByTheWordPeopleSay() {
        #expect(TodayScreen.short("Back Squat") == "squat")
        #expect(TodayScreen.short("Bent Over Barbell Row") == "row")
        #expect(TodayScreen.short("Bench Press") == "bench press")
        #expect(TodayScreen.short("Deadlift") == "deadlift")
        #expect(TodayScreen.short("Dumbbell Row (single-arm)") == "row")
    }

    // TKL-797: two lifts that shorten to the same word each take the word that tells them apart.
    @Test func collidingLiftsTakeTheWordThatTellsThemApart() {
        #expect(TodayScreen.title(lifts: ["Bench Press", "Incline Bench Press"]) == "Bench press, incline bench press")
        #expect(TodayScreen.title(lifts: ["Bench Press", "Dumbbell Bench Press", "Pull-Up"]) == "Bench press, dumbbell bench press, pull-up")
        #expect(TodayScreen.title(lifts: ["Back Squat", "Front Squat"]) == "Back squat, front squat")
    }

    @Test func aThreeWayCollision() {
        #expect(TodayScreen.title(lifts: ["Incline Bench Press", "Bench Press", "Close-Grip Bench Press"])
                == "Incline bench press, bench press, close-grip bench press")
        // The count still counts every lift.
        #expect(TodayScreen.title(lifts: ["Bench Press", "Incline Bench Press", "Dumbbell Bench Press", "Pull-Up", "Plank"])
                == "Bench press, incline bench press, dumbbell bench press + 2 more")
    }

    @Test func titlesWithNoCollisionAreUnchanged() {
        #expect(TodayScreen.title(lifts: ["Back Squat", "Bench Press", "Bent Over Barbell Row"]) == "Squat, bench press, row")
        #expect(TodayScreen.title(lifts: ["Back Squat", "Bench Press", "Bent Over Barbell Row", "Plank"]) == "Squat, bench press, row + 1 more")
        #expect(TodayScreen.title(lifts: ["Deadlift"]) == "Deadlift")
    }
}
