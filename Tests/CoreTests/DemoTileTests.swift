import Foundation
import Testing
@testable import AICoach

/// TKL-793: how-to demos one tap away. A session row leads with a demo tile; the how-to sheet pages through the
/// session's exercises; the demo plays, pauses, slows down, and stops for Reduce Motion.
struct DemoTileTests {
    private func movement(_ slug: String, working: Int) -> SessionPlan.Movement {
        let set = SessionPlan.PlannedSet(plannedRef: UUID(), targets: [Measurement(metric: "reps", value: 5, unit: "reps")],
                                         note: "", adjustedReason: nil)
        return SessionPlan.Movement(exercise: slug, sets: Array(repeating: set, count: working))
    }

    /// The tile is the clip when there is one, else the first photo, else nothing (the dashed placeholder).
    @Test func tileIsClipThenPhotoThenNothing() throws {
        #expect(DemoTileContent.of("back-squat") == .clip)
        let photoOnly = try #require(ExercisePhotos.bundled.keys.sorted().first { !ExerciseDemos.bundled.contains($0) })
        #expect(DemoTileContent.of(photoOnly) == .photo(ExercisePhotos.urls(photoOnly)[0]))
        #expect(DemoTileContent.of("not-an-exercise") == .none)
    }

    /// The how-to pages are the session's lifts in order, each once; the written warm-up isn't among them.
    @Test func pagesAreTheSessionsLiftsInOrder() {
        let warmup = SessionPlan.Block(movements: [movement("rowing-machine", working: 0)])
        let squat = SessionPlan.Block(movements: [movement("back-squat", working: 3)])
        let superset = SessionPlan.Block(movements: [movement("bench-press", working: 3), movement("barbell-row", working: 3)])
        let again = SessionPlan.Block(movements: [movement("back-squat", working: 1)])
        #expect(SessionPlan(blocks: [warmup, squat, superset, again]).howToOrder == ["back-squat", "bench-press", "barbell-row"])
    }

    /// Slow is half speed; a paused clip or Reduce Motion shows the poster, not the loop.
    @Test func playback() {
        #expect(DemoPlayback.rate(slow: false) == 1)
        #expect(DemoPlayback.rate(slow: true) == 0.5)
        #expect(DemoPlayback.loops(reduceMotion: false, paused: false))
        #expect(!DemoPlayback.loops(reduceMotion: true, paused: false))
        #expect(!DemoPlayback.loops(reduceMotion: false, paused: true))
    }

    /// No connection (not a missing file on the site) is what the sheet calls offline.
    @Test func offlineIsNoConnection() {
        #expect(DemoPlayback.offline(URLError(.notConnectedToInternet)))
        #expect(DemoPlayback.offline(URLError(.networkConnectionLost)))
        #expect(DemoPlayback.offline(URLError(.timedOut)))
        #expect(!DemoPlayback.offline(URLError(.fileDoesNotExist)))
        #expect(!DemoPlayback.offline(CocoaError(.fileWriteUnknown)))
    }

    /// "How to Do It" leaves the … menu for an exercise with a tile; one with only steps or a YouTube link keeps it.
    @Test func menuKeepsHowToOnlyWithoutATile() {
        #expect(!BlockEditor.menuHowTo("back-squat", steps: ["Stand tall"]))
        #expect(BlockEditor.menuHowTo("not-an-exercise", steps: ["Stand tall"]))
        #expect(!BlockEditor.menuHowTo("not-an-exercise", steps: []))
    }
}
