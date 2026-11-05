import Foundation
import Testing
@testable import AICoach

/// A saved workout carries its summary row, so its note can be added or changed after.
@MainActor
struct DayCardNoteTests {
    let day = Date(timeIntervalSince1970: 1_793_800_000)
    let bench = Template(kind: .exercise, name: "Bench Press", slug: "bench-press")

    private func done(note: String) throws -> (DayCard.Done, LogEntry) {
        let planned = PlannedActivity(kind: .workout, date: day, slot: "Upper", templateRef: bench.id, now: day)
        let set = LogEntry(kind: .workout, timestamp: day, templateRef: bench.id, measurements: [Measurement(metric: "reps", value: 5, unit: "reps")])
        let summary = LogEntry(kind: .workout, timestamp: day + 1, measurements: [Measurement(metric: "effort", value: 8, unit: "/10")], note: note)
        let context = DayCard.Context(templates: [bench], sessionMinutes: 45, deload: false, tier: .of(age: 36))
        guard case .done(let done) = DayCard.make(day: day, planned: [planned], entries: [set, summary], next: nil, context: context) else {
            throw CancellationError()
        }
        return (done, summary)
    }

    @Test func aSavedWorkoutKeepsItsSummaryForANote() throws {
        let (done, summary) = try done(note: "That was hard: slept 5 hours")
        #expect(done.summary?.id == summary.id)
        #expect(done.note == "That was hard: slept 5 hours")
    }

    @Test func aWorkoutWithoutANoteCanStillTakeOne() throws {
        let (done, summary) = try done(note: "")
        #expect(done.summary?.id == summary.id)
        #expect(done.note.isEmpty)
    }
}
