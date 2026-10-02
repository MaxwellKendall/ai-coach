import Foundation
import Testing
@testable import AICoach

struct SessionRecordTests {
    private func set(_ exercise: String, _ reps: Double, _ load: Double, rpe: Double? = 7) -> LoggedSet {
        LoggedSet(date: .now, exercise: exercise, pattern: nil,
                  measurements: [Measurement(metric: "reps", value: reps, unit: "reps"), Measurement(metric: "load_lb", value: load, unit: "lb")]
                    + (rpe.map { [Measurement(metric: "rpe", value: $0, unit: "RPE")] } ?? []))
    }

    @Test func supersetSetsBecomeRoundsAndSinglesStayBlocks() {
        let sets = [set("deadlift", 5, 200), set("deadlift", 5, 200),
                    set("db-row", 10, 50), set("db-bench", 10, 40), set("db-row", 10, 50), set("db-bench", 8, 40)]
        let record = SessionRecord(sets, groups: [nil, nil, 2, 2, 2, 2])
        #expect(record.blocks.count == 2)
        #expect(record.blocks[1].exercises == ["db-row", "db-bench"])
        #expect(record.blocks[1].rounds.map { $0.map(\.exercise) } == [["db-row", "db-bench"], ["db-row", "db-bench"]])
        #expect(record.setCount == 6)
        #expect(record.volume == 2000 + 500 + 400 + 500 + 320)
    }

    @Test func withoutGroupsConsecutiveExercisesAreBlocks() {
        let record = SessionRecord([set("bench", 5, 140), set("bench", 5, 140), set("row", 10, 50)], groups: [])
        #expect(record.blocks.map(\.exercises) == [["bench"], ["row"]])
    }

    @Test func blockFactsComeFromTheExistingRules() {
        let sets = [set("deadlift", 5, 195, rpe: 7), set("deadlift", 5, 200, rpe: 7)]
        #expect(SessionRecord.estimated1RM(sets).map { Int($0.rounded()) } == 225) // 200 × 36 / 32
        let tier = AgeTier.of(age: 35) // top RPE 8: RPE 7 is a full point under, so +5
        #expect(SessionRecord.nextLoad(sets, main: true, tier: tier).map { [$0.from, $0.to] } == [200, 205])
        #expect(SessionRecord.nextLoad(sets, main: false, tier: tier).map { [$0.from, $0.to] } == [200, 200])
    }

    @Test func lastSessionIsEverythingAfterThePreviousSummary() {
        // s = set, S = summary: two sessions logged the same day.
        let entries = Array("sssSssS")
        #expect(String(SessionRecord.lastSession(entries) { $0 == "S" }) == "ssS")
        #expect(String(SessionRecord.lastSession(Array("sss")) { $0 == "S" }) == "sss")
    }
}
