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
        for (key, value) in json {
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

        let planned = try context.fetch(FetchDescriptor<PlannedActivity>())
        #expect(planned.count == 4)
        #expect(planned.allSatisfy { $0.pinned && $0.templateRef != nil })
        #expect(Set(planned.compactMap(\.slot)) == ["Lower A", "Upper A"])

        let logged = try context.fetch(FetchDescriptor<LogEntry>())
        #expect(logged.filter { $0.templateRef != nil }.count == 7)
        #expect(logged.contains { $0.templateRef == nil && $0.note == "Knees fine." })
    }
}
