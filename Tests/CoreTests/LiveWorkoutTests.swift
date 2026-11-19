import Foundation
import Testing
@testable import AICoach

/// TKL-801: the Live Activity's Done set, −10s, +10s and Skip change the live workout through the same code as the
/// workout screen's own buttons, so they work from the Dynamic Island and the Lock Screen with the app in the background.
@MainActor struct LiveWorkoutTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// Squat 3 × 185 lb × 5 (3:00 rests), then Row 2 × 95 lb × 5.
    private func draft(warmups: [WorkoutDraft.Warmup] = []) -> WorkoutDraft {
        func set(_ load: Double) -> SessionPlan.PlannedSet {
            SessionPlan.PlannedSet(targets: [Measurement(metric: "reps", value: 5, unit: "reps"), Measurement(metric: "load_lb", value: load, unit: "lb")])
        }
        let squat = SessionPlan.Movement(exercise: "back-squat", sets: [set(185), set(185), set(185)])
        let row = SessionPlan.Movement(exercise: "bent-over-barbell-row", sets: [set(95), set(95)])
        var draft = WorkoutDraft(session: "Lower", plan: SessionPlan(blocks: [SessionPlan.Block(movements: [squat]), SessionPlan.Block(movements: [row])]))
        draft.warmups = warmups
        return draft
    }

    private func workout(warmups: [WorkoutDraft.Warmup] = []) -> LiveWorkout {
        let workout = LiveWorkout(draft: draft(warmups: warmups))
        workout.names = ["back-squat": "Back Squat", "bent-over-barbell-row": "Barbell Row"]
        return workout
    }

    @Test func doneSetLogsTheSetAndStartsItsRest() {
        let workout = workout()
        workout.handle(.done, now: now)
        #expect(workout.draft.rows[0].done)
        #expect(workout.cursor.page == 1)
        #expect(workout.cursor.rest == WorkoutCursor.Rest(ends: now + 180, total: 180, page: 1))
    }

    @Test func doneSetIsTheScreensDone() {
        // The island's button and the screen's Done end in the same place.
        let island = workout()
        island.handle(.done, now: now)
        var draft = draft()
        var cursor = WorkoutCursor()
        cursor.forward(&draft, now: now)
        #expect(island.draft.rows.map(\.done) == draft.rows.map(\.done) && island.cursor == cursor)
    }

    @Test func doneSetOnAWarmUpStepGoesToTheNextStep() {
        let workout = workout(warmups: [.init(exercise: nil, dose: "5 min")])
        workout.handle(.done, now: now)
        #expect(workout.cursor.warmStep == 1 && workout.cursor.page == 0)
        #expect(!workout.draft.rows[0].done)
    }

    @Test func tenSecondsMoreAndLess() {
        let workout = workout()
        workout.handle(.done, now: now)
        workout.handle(.more, now: now + 20)
        #expect(workout.cursor.rest?.ends == now + 190)
        #expect(workout.cursor.rest?.total == 180) // 170 left + 10 is still inside the 3:00 bar
        workout.handle(.less, now: now + 20)
        workout.handle(.less, now: now + 20)
        #expect(workout.cursor.rest?.ends == now + 170)
        for _ in 0..<14 { workout.handle(.less, now: now + 20) }
        #expect(workout.cursor.rest?.ends == now + 30)
        // Never before now: a rest cut to nothing ends there, and moves on.
        workout.handle(.less, now: now + 25)
        #expect(workout.cursor.rest?.ends == now + 25)
        workout.handle(.more, now: now + 25)
        #expect(workout.cursor.rest == nil && workout.cursor.page == 2)
    }

    @Test func moreStretchesTheBarPastItsStart() {
        let workout = workout()
        workout.handle(.done, now: now)
        workout.handle(.more, now: now)
        #expect(workout.cursor.rest?.total == 190)
    }

    @Test func skipEndsTheRestAndGoesToTheNextSet() {
        let workout = workout()
        workout.handle(.done, now: now)
        workout.handle(.skip, now: now + 30)
        #expect(workout.cursor.rest == nil)
        #expect(workout.cursor.page == 2)
    }

    @Test func aRestThatRanOutMovesOnBeforeTheNextDone() {
        // The app was asleep when the rest ended: Done set from the island does the set after it.
        let workout = workout()
        workout.handle(.done, now: now)
        workout.handle(.done, now: now + 200)
        #expect(workout.draft.rows[1].done)
        #expect(workout.cursor.page == 3)
        #expect(workout.cursor.rest?.ends == now + 380)
    }

    @Test func restButtonsOnARestNotStartedStartIt() {
        // A rest card reached from the list shows its rest without running it; −/+ start it, as on screen.
        let draft = draft()
        var cursor = WorkoutCursor(page: 1)
        cursor.shiftRest(by: 10, on: 1, in: draft, now: now)
        #expect(cursor.rest == WorkoutCursor.Rest(ends: now + 190, total: 190, page: 1))
        cursor = WorkoutCursor(page: 1)
        cursor.shiftRest(by: -30, on: 1, in: draft, now: now)
        #expect(cursor.rest == WorkoutCursor.Rest(ends: now + 150, total: 150, page: 1))
        cursor = WorkoutCursor(page: 1)
        cursor.shiftRest(by: -200, on: 1, in: draft, now: now)
        #expect(cursor.rest == nil && cursor.page == 2)
    }

    @Test func restEndsOnItsOwn() {
        let workout = workout()
        workout.handle(.done, now: now)
        #expect(!workout.finishRest(now: now + 100))
        #expect(workout.finishRest(now: now + 180))
        #expect(workout.cursor.page == 2 && workout.cursor.rest == nil)
        #expect(workout.restsFinished == 1)
        #expect(workout.content(now: now + 180).restOver)
        // Doing the set clears it.
        workout.handle(.done, now: now + 200)
        #expect(!workout.content(now: now + 200).restOver)
    }

    @Test func theIslandShowsWhereTheWorkoutIs() {
        let workout = workout()
        var state = workout.content(now: now)
        #expect(state.title == "Back Squat")
        #expect(state.set == "185×5")
        #expect(state.liftIndex == 1 && state.lifts == 2)
        #expect(state.setsDone == 0 && state.sets == 3)
        #expect(state.next == "Next: Squat 185×5")
        #expect(state.restEnds == nil && !state.isDone)

        workout.handle(.done, now: now)
        state = workout.content(now: now)
        #expect(state.restEnds == now + 180 && state.restTotal == 180)
        #expect(state.setsDone == 1)
        #expect(state.step == "2/3") // the set after the rest

        workout.handle(.skip, now: now)
        workout.handle(.done, now: now)
        workout.handle(.skip, now: now)
        state = workout.content(now: now)
        #expect(state.next == "Next: Row 95×5") // the last squat set: next is the row

        for _ in 0..<5 { workout.handle(.done, now: now); workout.handle(.skip, now: now) }
        state = workout.content(now: now)
        #expect(state.isDone && state.progress == 1)
    }
}
