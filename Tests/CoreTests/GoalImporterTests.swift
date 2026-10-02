import Foundation
import Testing
@testable import AICoach

struct GoalImporterTests {
    @Test func readsNumericTargetsFromProse() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let result = GoalImporter.goals(profileJSON: #"""
            { "generated_at": "2026-07-12",
              "active_goals": {
                "body_composition": { "target": "180 lb, waist ≤ 34\" (athletic-lean for 6ft male)", "unit": "lbs" },
                "squat": { "target": "250 lb back squat (1.25× bodyweight)", "unit": "lbs" },
                "pull": { "target": "10 unbroken pull-ups", "unit": "reps" },
                "cardio": { "target": "5K under 25 min", "unit": "min" },
                "mobility": { "target": "hip mobility pass; no chronic postural compensation" },
                "timeline_weeks_remaining": 7 } }
            """#, calendar: calendar)
        #expect(result.goals.map(\.metric) == ["back-squat.1rm_lb", "pull-up.reps", "5k.duration_min", "weight_lb", "waist_in"])
        #expect(result.goals.map(\.target) == [250, 10, 25, 180, 34])
        #expect(result.goals.map(\.kind) == [.training, .training, .training, .body, .body])
        #expect(result.skipped == ["mobility: no numeric target (hip mobility pass; no chronic postural compensation)"])
        #expect(calendar.dateComponents([.year, .month, .day], from: result.goals[0].deadline!)
            == DateComponents(year: 2026, month: 8, day: 30))
    }

    @Test func badProfileIsReportedNotFatal() {
        #expect(GoalImporter.goals(profileJSON: "{ nope").skipped == ["profile.json: no active_goals"])
    }

    @Test(arguments: [
        ("back-squat.1rm_lb", "Back Squat 1RM"), ("pull-up.reps", "Pull Up reps"),
        ("weight_lb", "Body weight"), ("5k.duration_min", "5k time"), ("custom_thing", "custom_thing"),
    ])
    func label(metric: String, label: String) {
        #expect(Goal.label(metric) == label)
    }
}
