import Foundation
import Testing
@testable import AICoach

/// FIT-111: what a shared program says, and that it never carries weights.
@MainActor struct SharedProgramTests {
    @Test func theBriefsPhasesWithTheirWeeksAndNoWeights() throws {
        let profile = Profile(age: 36, weightLb: 200, trainingDays: [0, 2, 4])
        profile.equipment = ["barbell", "rack", "dumbbells"]
        profile.programStart = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 5))
        profile.targetDate = Calendar.current.date(byAdding: .weekOfYear, value: 12, to: profile.programStart!)
        let brief = ProgramBrief(phases: [
            .init(phase: "base", focus: "Volume and technique", mainLifts: ["Back Squat", "Bench Press"], mainReps: 8, accessoryReps: 12),
            .init(phase: "build", focus: "Heavier", mainLifts: ["Back Squat", "Bench Press"], mainReps: 5, accessoryReps: 8),
        ])
        profile.brief = ProgramBrief.Stored(brief: brief, key: "k", model: "test")
        let shared = try #require(SharedProgram.make(profile: profile, goals: [], thisWeek: [], templates: [], invite: "A1B2C3D4"))
        #expect(shared.equipment == "Full gym")
        #expect(shared.days == 3)
        #expect(shared.phases.map(\.phase) == ["base", "build"])
        #expect(shared.phases[0].from == 1)
        #expect(shared.phases[0].to < shared.phases[1].from)
        let json = String(decoding: try JSONEncoder().encode(shared), as: UTF8.self)
        #expect(!json.contains("load"))
    }

    @Test func noBriefNothingToShare() {
        #expect(SharedProgram.make(profile: Profile(age: 36, weightLb: 200), goals: [], thisWeek: [], templates: [], invite: nil) == nil)
    }
}
