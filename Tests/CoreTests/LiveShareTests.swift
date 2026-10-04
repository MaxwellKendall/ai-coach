import Foundation
import Testing
@testable import AICoach

/// FIT-53: what a group sees of a workout in progress.
struct LiveShareTests {
    private let bench = SessionPlan.Item(id: UUID(), exercise: "bench-press", targets: [
        Measurement(metric: "sets", value: 3, unit: "sets"), Measurement(metric: "reps", value: 5, unit: "reps"),
        Measurement(metric: "load_lb", value: 185, unit: "lb")], note: "")
    private let plank = SessionPlan.Item(id: UUID(), exercise: "plank", targets: [
        Measurement(metric: "sets", value: 2, unit: "sets"), Measurement(metric: "duration_s", value: 50, unit: "s")], note: "")
    private let names = ["bench-press": "Bench Press", "plank": "Plank"]

    @Test func setCardIsWorkingAndItsRestIsResting() {
        var draft = WorkoutDraft(session: "Push day", plan: SessionPlan([bench, plank]))
        #expect(draft.live(at: 0, names: names)
                == LiveSnapshot(exercise: "Bench Press", setIndex: 1, setCount: 3, loadLb: 185, reps: 5, state: "working"))
        draft.tick([0])
        // Card 1 is the rest after set 1.
        #expect(draft.live(at: 1, names: names)?.state == "resting")
        #expect(draft.live(at: 1, names: names)?.setIndex == 1)
        #expect(draft.live(at: 2, names: names)?.setIndex == 2)
    }

    @Test func timedSetsSendSecondsAndNoLoad() {
        let draft = WorkoutDraft(session: "Core", plan: SessionPlan([plank]))
        let live = draft.live(at: 0, names: names)
        #expect(live?.seconds == 50)
        #expect(live?.reps == nil)
        #expect(live?.loadLb == nil)
    }

    @Test func nothingOnTheFinishCard() {
        let draft = WorkoutDraft(session: "Push day", plan: SessionPlan([bench]))
        #expect(draft.live(at: draft.cards.count, names: names) == nil)
    }

    @Test func summaryNamesTheHeaviestLoggedSet() {
        var draft = WorkoutDraft(session: "Push day", plan: SessionPlan([bench, plank]))
        #expect(draft.top(names: names) == nil)
        draft.tick([0])
        draft.rows[1].load = 195
        draft.tick([1])
        #expect(draft.top(names: names) == "Bench Press 195 × 5")
    }

    @Test func viewersSeeTheSetAndTheRestClock() {
        let set = Cloud.LiveSet(groupId: "g", uid: "dad", workout: "Push day", exercise: "Bench Press", setIndex: 3, setCount: 5,
                                loadLb: 185, reps: 5, seconds: nil, rpe: nil, state: "resting",
                                startedAt: "2026-10-03T11:50:00.000Z", updatedAt: "2026-10-03T12:00:00.000Z")
        let now = Cloud.date("2026-10-03T12:01:12.000Z")!
        #expect(set.setLine == "Bench Press · set 3 of 5")
        #expect(set.what(now: now) == "185 lb × 5 · resting 1:12")
        #expect(set.isLive(now: now))
        #expect(!set.isLive(now: now + 3 * 3600))
        var done = set
        done.state = "done"
        #expect(!done.isLive(now: now))
    }
}
