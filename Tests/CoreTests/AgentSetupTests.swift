import Foundation
import SwiftData
import Testing
@testable import AICoach

/// FIT-150: an account set up only by an agent (infra/lambda/mcp.ts, through set_profile, set_goal, propose_week, apply and
/// log_session) is what the app reads when it signs in. The units come from infra/test/mcp.test.ts, which keeps
/// Tests/Fixtures/agent-setup-units.json in step with the server.
@MainActor
struct AgentSetupTests {
    @Test func aPhoneSigningInReadsWhatTheAgentSetUp() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/agent-setup-units.json")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let context = ModelContext(try AppSchema.container(inMemory: true))
        for slug in ["back-squat", "plank", "dumbbell-bench-press", "pull-up"] {
            context.insert(Template(kind: .exercise, name: slug, slug: slug))
        }
        // Exercises first, as SyncEngine applies them, so the plans that name them find them.
        for (key, value) in json.sorted(by: { ($0.key.hasPrefix("template#") ? 0 : 1, $0.key) < ($1.key.hasPrefix("template#") ? 0 : 1, $1.key) }) {
            let body = String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
            try SyncUnits.apply(key, body: body, in: context)
        }
        try context.save()

        let profile = try #require(try context.fetch(FetchDescriptor<Profile>()).first)
        #expect(profile.age == 41)
        #expect(profile.trainingDays == [0, 2, 5])
        #expect(profile.workoutTime == 6 * 60 + 30)
        #expect(profile.avoidExercises == ["bench-press"])
        #expect(profile.starts.first?.exercise == "back-squat")

        // FIT-165: set_program's 16 weeks with a trip in week 4, as the Program tab lays them out (the server's
        // weeks are in the account's time zone, New York).
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let start = try #require(profile.programStart), target = try #require(profile.targetDate)
        let count = ProgramPlan.weekCount(start: start, target: target, calendar: calendar)
        let weeks = ProgramPlan.weeks(count: count, deloadEvery: AgeTier.of(age: profile.age).deloadEveryWeeks, travel: Set(profile.travelWeeks))
        #expect(count == 16)
        #expect(weeks.indices.filter { weeks[$0].kind == .deload } == [3, 8, 13])
        #expect(weeks[3].travel && weeks.last?.kind == .test)
        #expect(ProgramPlan.week(of: profile.programStart!, start: start, calendar: calendar) == 0)

        let goals = try context.fetch(FetchDescriptor<Goal>())
        #expect(Set(goals.map(\.metric)) == ["back-squat.1rm_lb", "pull-up.reps"])
        #expect(goals.allSatisfy { $0.status == .active })
        // FIT-167: set_goal starts a lift goal where the starting set puts it (185 × 5), as onboarding does.
        #expect(goals.first { $0.metric == "back-squat.1rm_lb" }?.baseline == 208)

        // FIT-173: create_exercise's Landmine Press is in the library and planned by name.
        let landmine = try #require(try context.fetch(FetchDescriptor<Template>()).first { $0.slug == "landmine-press" })
        #expect(landmine.name == "Landmine Press" && landmine.values("movement_pattern") == ["push"])
        let units = try SyncUnits.all(in: context)
        #expect(units.keys.filter { $0.hasPrefix("template#") } == ["template#landmine-press"])
        let sent = try JSONSerialization.jsonObject(with: Data(units["template#landmine-press"]!.utf8)) as? NSDictionary
        #expect(sent == json["template#landmine-press"] as? NSDictionary)

        let planned = try context.fetch(FetchDescriptor<PlannedActivity>())
        #expect(planned.count == 5)
        #expect(planned.contains { $0.templateRef == landmine.id })
        #expect(planned.allSatisfy { $0.pinned && $0.templateRef != nil })
        #expect(Set(planned.compactMap(\.slot)) == ["Lower A", "Upper A"])

        let logged = try context.fetch(FetchDescriptor<LogEntry>())
        #expect(logged.filter { $0.kind == .workout && $0.templateRef != nil }.count == 7)
        #expect(logged.contains { $0.templateRef == nil && $0.note == "Knees fine." })

        // FIT-166: log_daily's weigh-in, sleep and meal, as the Progress tab's weigh-ins read them (WeekReport).
        let weighIns = logged.filter { $0.kind == .bodyweight }.compactMap { entry in
            entry.measurements.first { $0.metric == "weight_lb" }.map { DatedValue(date: entry.timestamp, value: $0.value) }
        }
        #expect(GoalProgress.current("weight_lb", sets: [], weighIns: weighIns, since: .distantPast) == 195.4)
        #expect(logged.first { $0.kind == .sleep }?.measurements.map(\.metric) == ["sleep_h", "sleep_quality"])
        let meal = try #require(logged.first { $0.kind == .meal })
        #expect(meal.note == "Oats and whey" && meal.measurements.first { $0.metric == "protein_g" }?.value == 40)
    }
}
