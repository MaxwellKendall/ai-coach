import Foundation
import Testing
@testable import AICoach

/// TKL-1097: the live workout's swipes. Left does the card's button, right goes back, up skips a set (nothing logged,
/// its rest skipped too), and a short or diagonal drag springs home.
struct WorkoutSwipeTests {
    private let bench = SessionPlan.Item(id: UUID(), exercise: "bench-press", targets: [
        Measurement(metric: "sets", value: 2, unit: "sets"), Measurement(metric: "reps", value: 5, unit: "reps"),
        Measurement(metric: "load_lb", value: 185, unit: "lb")], note: "")

    @Test func leftIsForwardRightIsBackUpIsSkip() {
        #expect(WorkoutSwipe.action(translation: CGSize(width: -150, height: 10), predicted: CGSize(width: -260, height: 10),
                                    velocity: .zero) == .forward)
        #expect(WorkoutSwipe.action(translation: CGSize(width: 150, height: -10), predicted: CGSize(width: 260, height: -10),
                                    velocity: .zero) == .back)
        #expect(WorkoutSwipe.action(translation: CGSize(width: 10, height: -150), predicted: CGSize(width: 10, height: -260),
                                    velocity: .zero) == .skip)
    }

    @Test func aFlickCountsAsMuchAsALongDrag() {
        #expect(WorkoutSwipe.action(translation: CGSize(width: -40, height: 0), predicted: CGSize(width: -60, height: 0),
                                    velocity: CGSize(width: -900, height: 0)) == .forward)
        #expect(WorkoutSwipe.action(translation: CGSize(width: 0, height: -40), predicted: CGSize(width: 0, height: -60),
                                    velocity: CGSize(width: 0, height: -900)) == .skip)
    }

    @Test func shortDragsAndDownSpringHome() {
        #expect(WorkoutSwipe.action(translation: CGSize(width: -30, height: 0), predicted: CGSize(width: -50, height: 0),
                                    velocity: .zero) == .stay)
        #expect(WorkoutSwipe.action(translation: CGSize(width: 0, height: -30), predicted: CGSize(width: 0, height: -50),
                                    velocity: .zero) == .stay)
        // Down is the cover's own dismiss gesture (guarded by "Leave this workout?"); the card does nothing with it.
        #expect(WorkoutSwipe.action(translation: CGSize(width: 0, height: 300), predicted: CGSize(width: 0, height: 500),
                                    velocity: CGSize(width: 0, height: 900)) == .stay)
    }

    @Test func theCardFollowsTheFingerOnOneAxisAndOnlyUpVertically() {
        #expect(WorkoutSwipe.offset(CGSize(width: -80, height: 20)) == CGSize(width: -80, height: 0))
        #expect(WorkoutSwipe.offset(CGSize(width: 10, height: -80)) == CGSize(width: 0, height: -80))
        #expect(WorkoutSwipe.offset(CGSize(width: 10, height: 80)) == .zero)
    }

    @Test func skippingASetLandsOnTheNextSetPastItsRest() {
        let draft = WorkoutDraft(session: "Push day", plan: SessionPlan([bench]))
        // Cards: set 1, rest, set 2.
        #expect(draft.cards.count == 3)
        #expect(draft.afterSkipping(0) == 2)
        // The last set skips to the finish card.
        #expect(draft.afterSkipping(2) == 3)
        // A rest card skips to the set after it.
        #expect(draft.afterSkipping(1) == 2)
    }

    @Test func skippingLogsNothing() {
        let draft = WorkoutDraft(session: "Push day", plan: SessionPlan([bench]))
        _ = draft.afterSkipping(0)
        #expect(draft.rows.allSatisfy { !$0.done })
    }
}
