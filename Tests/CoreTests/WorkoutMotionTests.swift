import Foundation
import Testing
@testable import AICoach

/// TKL-934: motion pass 1 — unit checks for banking chip labels, hold-to-repeat stepper acceleration,
/// rest level & final countdown, celebration goal-hit detection and flecks, and reverse banking on undo.
struct WorkoutMotionTests {
    @Test func stepperRepeatAcceleratesWhileHeld() {
        let initial = StepperRepeat.interval(after: 0)
        let early = StepperRepeat.interval(after: 2)
        let mid = StepperRepeat.interval(after: 4)
        let fast = StepperRepeat.interval(after: 8)
        #expect(initial == .milliseconds(380))
        #expect(early == .milliseconds(380))
        #expect(mid == .milliseconds(180))
        #expect(fast == .milliseconds(90))
        #expect(initial > mid)
        #expect(mid > fast)
    }

    @Test func chipLabelFormatsSingleSupersetAndBodyweightSets() {
        let squat = SetRow(exercise: "back-squat", metric: "reps", value: 5, loadMetric: "load_lb", load: 170)
        #expect(WorkoutModeView.chipLabel([squat]) == "5 × 170")

        let bench = SetRow(exercise: "bench-press", metric: "reps", value: 8, loadMetric: "load_lb", load: 135)
        let row = SetRow(exercise: "barbell-row", metric: "reps", value: 8, loadMetric: "load_lb", load: 115)
        #expect(WorkoutModeView.chipLabel([bench, row]) == "8 × 135 + 8 × 115")

        let pullup = SetRow(exercise: "pull-up", metric: "reps", value: 10, loadMetric: nil, load: nil)
        #expect(WorkoutModeView.chipLabel([pullup]) == "10 reps")

        let plank = SetRow(exercise: "plank", metric: "duration_s", value: 45, loadMetric: nil, load: nil)
        #expect(WorkoutModeView.chipLabel([plank]) == "45 s")
    }

    @Test func bankCarriesLabelAndReverseDirectionForUndo() {
        let forward = Bank(target: 0, from: CGPoint(x: 100, y: 300), label: "5 × 170")
        #expect(forward.label == "5 × 170")
        #expect(forward.reverse == false)

        let undo = Bank(target: 0, from: CGPoint(x: 100, y: 300), label: "5 × 170", reverse: true)
        #expect(undo.label == "5 × 170")
        #expect(undo.reverse == true)
    }

    @Test func restCountdownIdentifiesFinalThreeSecondsAndClampsLevel() {
        #expect(!RestMotion.isFinalCountdown(4))
        #expect(RestMotion.isFinalCountdown(3))
        #expect(RestMotion.isFinalCountdown(2))
        #expect(RestMotion.isFinalCountdown(1))
        #expect(!RestMotion.isFinalCountdown(0))

        #expect(RestMotion.levelFraction(remaining: 60, total: 120) == 0.5)
        #expect(RestMotion.levelFraction(remaining: 150, total: 120) == 1.0)
        #expect(RestMotion.levelFraction(remaining: -5, total: 120) == 0.0)
        #expect(RestMotion.levelFraction(remaining: 10, total: 0) == 0.0)
    }

    @Test func celebrationDistinguishesGoalHitAndPersonalBestRange() {
        let pr = WinItem(kind: .pr, date: .now, key: "pr:squat:175", metric: "back-squat.1rm_lb",
                         unit: "lb", value: 175, previous: 165, trend: [155, 165, 175])
        #expect(!CelebrationMotion.isGoalHit(pr))
        #expect(CelebrationMotion.countRange(for: pr).from == 165)
        #expect(CelebrationMotion.countRange(for: pr).to == 175)

        let goalHit = WinItem(kind: .milestone, date: .now, key: "m:squat:100", metric: "back-squat.1rm_lb",
                              unit: "lb", value: 200, start: 150, target: 200, percent: 100, trend: [150, 175, 200])
        #expect(CelebrationMotion.isGoalHit(goalHit))

        let halfway = WinItem(kind: .milestone, date: .now, key: "m:squat:50", metric: "back-squat.1rm_lb",
                              unit: "lb", value: 175, start: 150, target: 200, percent: 50, trend: [150, 175])
        #expect(!CelebrationMotion.isGoalHit(halfway))

        #expect(!CelebrationMotion.showsBackFace(angle: 0))
        #expect(!CelebrationMotion.showsBackFace(angle: 89.9))
        #expect(CelebrationMotion.showsBackFace(angle: 90))
        #expect(CelebrationMotion.showsBackFace(angle: 180))
    }

    @Test func flecksGenerateDeterministicDepthOfFieldParticles() {
        let a = CelebrationFlecks.makeParticles(count: 46, seed: 42)
        let b = CelebrationFlecks.makeParticles(count: 46, seed: 42)
        #expect(a.count == 46)
        #expect(a == b)
        #expect(a.allSatisfy { $0.depth >= 0 && $0.depth <= 1 })
        #expect(a.allSatisfy { $0.vy < 0 })
        #expect(a.contains { $0.accent })
        #expect(a.contains { !$0.accent })
    }
}
