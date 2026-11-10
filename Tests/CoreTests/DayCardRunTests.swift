import Foundation
import SwiftData
import Testing
@testable import AICoach

/// A planned run stays open when the lifts beside it are saved, so it can still be started in run mode.
@MainActor
struct DayCardRunTests {
    let day = Date(timeIntervalSince1970: 1_793_800_000)
    let lunge = Template(kind: .exercise, name: "Walking Lunge", slug: "bodyweight-walking-lunge")
    let trail = Template(kind: .exercise, name: "Trail Running", slug: Running.outdoor)

    private func card(entries: [LogEntry]) -> (DayCard, PlannedActivity) {
        let warmUp = PlannedActivity(kind: .workout, date: day, now: day)
        warmUp.templateRef = lunge.id
        let run = PlannedActivity(kind: .workout, date: day + 1, now: day)
        run.templateRef = trail.id
        let context = DayCard.Context(templates: [lunge, trail], sessionMinutes: 30, deload: false, tier: .of(age: 36))
        return (DayCard.make(day: day, planned: [warmUp, run], entries: entries, next: nil, context: context), run)
    }

    private func set(_ template: Template) -> LogEntry {
        LogEntry(kind: .workout, timestamp: day, templateRef: template.id, measurements: [Measurement(metric: "reps", value: 10, unit: "reps")])
    }

    @Test func aSavedWarmUpLeavesThePlannedRunToStart() throws {
        let (card, run) = card(entries: [set(lunge)])
        guard case .done(let done) = card else { Issue.record("expected done"); return }
        #expect(done.pendingRun?.id == run.id)
        #expect(done.ran.isEmpty)
    }

    @Test func aRunLoggedAfterTheWarmUpClosesIt() throws {
        let (card, _) = card(entries: [set(lunge), set(trail)])
        guard case .done(let done) = card else { Issue.record("expected done"); return }
        #expect(done.pendingRun == nil)
        #expect(done.ran.count == 1)
    }
}
