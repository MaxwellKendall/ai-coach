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
        #expect(CheckIn.summary(rows) == nil)
    }

    /// FIT-351: Today's Note writes the day's note where the check-in keeps it, changes it, and clears it.
    @Test func theDaysNoteIsSetChangedAndCleared() throws {
        let context = ModelContext(try AppSchema.container(inMemory: true))
        try CheckIn.setNote(" Knee felt off on the stairs ", on: now, in: context, now: now)
        var rows = try CheckIn.entries(on: now, in: context)
        #expect(rows.count == 1 && rows[0].kind == .bodyweight && rows[0].measurements.isEmpty)
        #expect(CheckIn.values(rows).note == "Knee felt off on the stairs")

        // A check-in after keeps the note, and the note moves to nothing new.
        try CheckIn.replace(weight: 182, sleep: 7, note: CheckIn.values(rows).note, on: now, in: context, now: now + 60)
        try CheckIn.setNote("Travelling Thursday", on: now, in: context, now: now + 120)
        rows = try CheckIn.entries(on: now, in: context)
        #expect(rows.count == 2 && CheckIn.values(rows).note == "Travelling Thursday" && CheckIn.values(rows).weight == 182)

        // Cleared: the weight and sleep stay; with no check-in, the empty row goes.
        try CheckIn.setNote("", on: now, in: context, now: now + 180)
        #expect(try CheckIn.entries(on: now, in: context).count == 2)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        try CheckIn.setNote("Rest", on: tomorrow, in: context, now: now)
        try CheckIn.setNote(" ", on: tomorrow, in: context, now: now)
        #expect(try CheckIn.entries(on: tomorrow, in: context).isEmpty)
    }

    /// FIT-345: a past day's check-in is saved to that day, and opened again it can be changed or cleared.
    @Test func aPastDaysCheckInIsSavedThereAndChangedThere() throws {
        let context = ModelContext(try AppSchema.container(inMemory: true))
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        try CheckIn.replace(weight: 182, sleep: 7, note: "Late night", on: yesterday, in: context, now: now)
        #expect(try CheckIn.entries(on: now, in: context).isEmpty)
        let rows = try CheckIn.entries(on: yesterday, in: context)
        #expect(rows.allSatisfy { Calendar.current.component(.hour, from: $0.timestamp) == 12 })
        let values = CheckIn.values(rows)
        #expect(values.weight == 182 && values.sleep == 7 && values.note == "Late night")
        #expect(CheckIn.summary(rows) == "182 lb · 7 h sleep")
        let ids = Set(rows.map(\.id))

        // Changed: the weight, the sleep cleared, the note kept; the rows left keep their ids.
        try CheckIn.replace(weight: 181.5, sleep: nil, note: "Late night", on: yesterday, in: context, now: now + 60)
        let changed = try CheckIn.entries(on: yesterday, in: context)
        #expect(changed.count == 1 && changed[0].kind == .bodyweight && ids.contains(changed[0].id))
        let after = CheckIn.values(changed)
        #expect(after.weight == 181.5 && after.sleep == nil && after.note == "Late night")
        let unit = try #require(try SyncUnits.all(in: context)["log#2026-10-21"])
        #expect(try SyncUnits.decode([SyncUnits.LogRow].self, unit).map(\.kind) == [.bodyweight])

        // Everything cleared: the day has no check-in, and no unit.
        try CheckIn.replace(weight: nil, sleep: nil, note: " ", on: yesterday, in: context, now: now + 120)
        #expect(try CheckIn.entries(on: yesterday, in: context).isEmpty)
        #expect(try SyncUnits.all(in: context)["log#2026-10-21"] == nil)
    }
}
