import Foundation
import SwiftData
import Testing
@testable import AICoach

/// FIT-377: a coach's note on a day's session rides on its workout rows, reaches the client's phone with the plan
/// unit, and survives an edit that removes a row.
@MainActor
struct SessionNoteTests {
    private let at = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 18))!

    private func row(_ slug: String, kind: ActivityKind = .workout, offset: TimeInterval = 0) -> SyncUnits.PlanRow {
        SyncUnits.PlanRow(id: UUID(), kind: kind, at: at + offset, slot: "Lower", template: slug, targets: [], note: "", adjustedReason: nil,
                          group: nil, main: offset == 0, pinned: true)
    }

    @Test func itsOnEveryWorkoutRowOneShortLine() {
        let plan = [row("back-squat"), row("romanian-deadlift", offset: 1), row("dinner", kind: .meal, offset: 2)]
        let noted = ClientDay.noted(plan, "  Keep the bar speed up. " + String(repeating: "x", count: 200))
        #expect(noted.prefix(2).allSatisfy { $0.sessionNote?.hasPrefix("Keep the bar speed up.") == true && $0.sessionNote?.count == 140 })
        #expect(noted[2].sessionNote == nil)
        #expect(ClientDay.sessionNote(noted)?.count == 140)
        #expect(ClientDay.sessionNote(ClientDay.noted(noted, " ")) == nil)
    }

    @Test func itReachesTheirPhoneAndOutlivesARemovedLift() throws {
        let rows = ClientDay.noted([row("back-squat"), row("romanian-deadlift", offset: 1)], "Stop at RPE 8")
        let phone = ModelContext(try AppSchema.container(inMemory: true))
        try SyncUnits.apply("plan#2026-11-12", body: SyncUnits.encode(rows), in: phone)
        let items = try phone.fetch(FetchDescriptor<PlannedActivity>())
        #expect(PlannedActivity.sessionNote(items) == "Stop at RPE 8")
        try SyncUnits.apply("plan#2026-11-12", body: SyncUnits.encode([rows[1]]), in: phone)
        #expect(PlannedActivity.sessionNote(try phone.fetch(FetchDescriptor<PlannedActivity>())) == "Stop at RPE 8")
    }

    @Test func aDayWithNoNoteIsTheSameBytes() {
        #expect(!SyncUnits.encode([row("back-squat")]).contains("sessionNote"))
    }
}
