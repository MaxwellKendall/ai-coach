import Foundation
import Testing
import UserNotifications
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
        workout.alarm = .none
        workout.names = ["back-squat": "Back Squat", "bent-over-barbell-row": "Barbell Row"]
        return workout
    }

    @Test func doneSetLogsTheSetAndStartsItsRest() {
        let workout = workout()
        workout.handle(.done, now: now)
        #expect(workout.draft.rows[0].done)
        #expect(workout.cursor.page == 1)
        #expect(workout.cursor.rest == WorkoutCursor.Rest(started: now, ends: now + 180, total: 180, page: 1))
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
        #expect(cursor.rest == WorkoutCursor.Rest(started: now, ends: now + 190, total: 190, page: 1))
        cursor = WorkoutCursor(page: 1)
        cursor.shiftRest(by: -30, on: 1, in: draft, now: now)
        #expect(cursor.rest == WorkoutCursor.Rest(started: now, ends: now + 150, total: 150, page: 1))
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

    /// A stand-in for iOS's notification center.
    @MainActor final class Alarms {
        var set: [(Date, String)] = []
        var cancels = 0
        var sounds = true
    }

    private func workout(alarms: Alarms) -> LiveWorkout {
        let workout = workout()
        workout.alarm = RestAlarm(set: { alarms.set.append(($0, $1)) }, cancel: { alarms.cancels += 1 }, sounds: { alarms.sounds })
        return workout
    }

    @Test func aRestSetsASystemAlarmForItsEnd() {
        // [verify] 1: a suspended app's timer can't run at the rest's end, so iOS itself sounds it.
        let alarms = Alarms()
        let workout = workout(alarms: alarms)
        workout.handle(.done, now: now)
        #expect(alarms.set.count == 1)
        #expect(alarms.set.last?.0 == now + 180)
        #expect(alarms.set.last?.1 == "Back Squat · 185×5") // the set the rest is before
        workout.handle(.more, now: now)
        #expect(alarms.set.count == 2 && alarms.set.last?.0 == now + 190)
        let cancels = alarms.cancels
        workout.handle(.skip, now: now)
        #expect(alarms.set.count == 2 && alarms.cancels > cancels)
    }

    @Test func theIslandAlertsOnlyWhenIOSWont() {
        // One sound at a rest's end: the system alarm's, or the island's own when notifications aren't allowed.
        #expect(!LiveWorkout.islandAlerts(background: false, alarmSounds: false))
        #expect(!LiveWorkout.islandAlerts(background: true, alarmSounds: true))
        #expect(LiveWorkout.islandAlerts(background: true, alarmSounds: false))
    }

    @Test(arguments: [true, false])
    func aRestEndShowsRestOverWithOrWithoutNotifications(allowed: Bool) throws {
        // TKL-1023, the rest-end rule decided 2026-11-21: the island and Lock Screen always say "Rest over" at a rest's
        // end, even with the app suspended; with notifications allowed, iOS also sounds it; denied, no sound is owed.
        let alarms = Alarms()
        alarms.sounds = allowed
        let workout = workout(alarms: alarms)
        workout.handle(.done, now: now)
        let state = workout.content(now: now)

        // Suspended: nothing in the app runs at the end. The content iOS holds goes stale then, and stale reads "Rest over".
        let content = WorkoutActivity.content(state)
        #expect(content.staleDate == now + 180)
        #expect(ActivityPhase(state, stale: false, now: now) == .resting(starts: now, ends: now + 180))
        #expect(ActivityPhase(state, stale: true, now: now) == .restOver)

        // Awake: the rest ends on its own and the island says so, in either permission state.
        #expect(workout.finishRest(now: now + 180))
        #expect(ActivityPhase(workout.content(now: now + 180), stale: false, now: now + 180) == .restOver)

        // The sound: iOS's own notification at the end, scheduled either way and heard only when allowed.
        #expect(alarms.set.first?.0 == now + 180)
        let request = RestAlarm.request(ends: now + 180, next: "Back Squat · 185×5", now: now)
        #expect(request.content.title == "Rest over")
        #expect(request.content.sound != nil)
        let trigger = try #require(request.trigger as? UNTimeIntervalNotificationTrigger)
        #expect(trigger.timeInterval == 180)
        // The island's own alert only stands in when notifications aren't allowed (best effort, when the app wakes).
        #expect(LiveWorkout.islandAlerts(background: true, alarmSounds: alarms.sounds) == !allowed)
    }

    @Test func anIslandButtonWithNoWorkoutEndsTheActivity() {
        // [verify] 2: the app was closed and iOS launched it just for the button: the workout is gone, so is the island.
        LiveWorkout.current = nil
        var ended = 0
        #expect(!LiveWorkout.perform("done", orphaned: { ended += 1 }))
        #expect(ended == 1)
        let workout = workout()
        LiveWorkout.current = workout
        #expect(LiveWorkout.perform("done", now: now, orphaned: { ended += 1 }))
        #expect(ended == 1 && workout.draft.rows[0].done)
        LiveWorkout.current = nil
    }
}
