import Foundation
import SwiftData
import Testing
@testable import AICoach

/// FIT-376: a coach changes a client's goal or profile with the client's own editors, on their units; only what
/// changed goes back, with the coach's name on it, and the client changing it again takes the name off.
@MainActor
struct ClientScratchTests {
    private let squat = "goal#3F2504E0-4F89-11D3-9A0C-0305E82C3301"
    private let bench = "goal#6BA7B810-9DAD-11D1-80B4-00C04FD430C8"

    private func units() throws -> [String: String] {
        let profile = Profile(age: 35, weightLb: 180)
        profile.trainingDays = [0, 2, 4]
        return [
            squat: SyncUnits.encode(SyncUnits.GoalBody(kind: .training, metric: "back-squat.1rm_lb", target: 300, unit: "lb", deadline: nil,
                                                       baseline: 250, status: .active)),
            bench: SyncUnits.encode(SyncUnits.GoalBody(kind: .training, metric: "bench-press.1rm_lb", target: 200, unit: "lb", deadline: nil,
                                                       baseline: nil, status: .active)),
            "profile": SyncUnits.encode(SyncUnits.profileBody(profile)),
        ]
    }

    @Test func nothingChangedSendsNothing() throws {
        #expect(try ClientScratch(units: units(), templates: []).changes(by: "Sam").isEmpty)
    }

    @Test func aChangedGoalIsItsUnitAloneSetByTheCoach() throws {
        let scratch = try ClientScratch(units: units(), templates: [])
        try GoalChange.apply(try #require(scratch.goal(squat)), target: 315, deadline: nil, in: scratch.context)
        let changes = try scratch.changes(by: "Sam")
        #expect(Array(changes.keys) == [squat])
        let body = try SyncUnits.decode(SyncUnits.GoalBody.self, try #require(changes[squat] ?? nil))
        #expect(body.target == 315 && body.by == "Sam")
    }

    @Test func theProfileToo() throws {
        let scratch = try ClientScratch(units: units(), templates: [])
        try #require(scratch.profile).injuredAreas = ["knee"]
        let changes = try scratch.changes(by: "Sam")
        let body = try SyncUnits.decode(SyncUnits.ProfileBody.self, try #require(changes["profile"] ?? nil))
        #expect(Array(changes.keys) == ["profile"] && body.injuredAreas == ["knee"] && body.by == "Sam")
    }

    @Test func onTheirPhoneTheNameShowsUntilTheyChangeItThemselves() throws {
        let scratch = try ClientScratch(units: units(), templates: [])
        try GoalChange.apply(try #require(scratch.goal(squat)), target: 315, deadline: nil, in: scratch.context)
        let sent = try #require(try scratch.changes(by: "Sam")[squat] ?? nil)

        let phone = ModelContext(try AppSchema.container(inMemory: true))
        try SyncUnits.apply(squat, body: sent, in: phone)
        let goal = try #require(try phone.fetch(FetchDescriptor<Goal>()).first)
        #expect(goal.setBy == "Sam")
        try GoalChange.apply(goal, target: 320, deadline: nil, in: phone)
        #expect(goal.setBy == nil)
        // A goal nobody coached is the same bytes as before FIT-376.
        #expect(try !#require(SyncUnits.all(in: phone)[squat]).contains("\"by\""))
    }
}
