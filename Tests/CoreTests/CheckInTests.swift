import Foundation
import SwiftData
import Testing
@testable import AICoach

/// FIT-204: the check-in writes the rows log_daily writes, one weight and one sleep a day, and carries the note.
@MainActor
struct CheckInTests {
    private let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 7))!

    @Test func itReplacesTheDaysWeightAndSleep() throws {
        let context = ModelContext(try AppSchema.container(inMemory: true))
        try CheckIn.save(weight: 184, sleep: 6, note: "", on: now, in: context, now: now)
        try CheckIn.save(weight: 183.5, sleep: nil, note: " Knee is a bit sore ", on: now, in: context, now: now + 60)

        let rows = try CheckIn.entries(on: now, in: context)
        #expect(rows.filter { $0.kind == .bodyweight }.map { $0.measurements.first?.value } == [183.5])
        #expect(rows.filter { $0.kind == .sleep }.map { $0.measurements.first?.value } == [6])
        // The note rides on the sleep row, the day's check-in.
        #expect(rows.first { $0.kind == .sleep }?.note == "Knee is a bit sore")
        #expect(CheckIn.summary(rows) == "183.5 lb · 6 h sleep")

        // As synced: a bodyweight row with weight_lb, as log_daily writes it.
        let unit = try #require(try SyncUnits.all(in: context)["log#2026-10-22"])
        let synced = try SyncUnits.decode([SyncUnits.LogRow].self, unit)
        #expect(synced.contains { $0.kind == .bodyweight && $0.measurements == [Measurement(metric: "weight_lb", value: 183.5, unit: "lb")] })
    }

    @Test func aNoteOnItsOwnIsntAWeighIn() throws {
        let context = ModelContext(try AppSchema.container(inMemory: true))
        try CheckIn.save(weight: nil, sleep: nil, note: "Travelling, back Monday", on: now, in: context, now: now)
        let rows = try CheckIn.entries(on: now, in: context)
        #expect(rows.count == 1 && rows[0].measurements.isEmpty && rows[0].note == "Travelling, back Monday")
        #expect(CheckIn.summary(rows) == "Note sent")
    }
}
