import Foundation
import SwiftData
import Testing
@testable import AICoach

/// FIT-233: a goal added after onboarding starts where they are and suggests a target a little on.
struct NewGoalTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func offersOnlyTheGoalsTheyDoNotHave() {
        let bench = Goal(kind: .training, metric: "bench-press.1rm_lb", target: 225, unit: "lb")
        let dropped = Goal(kind: .training, metric: "pull-up.reps", target: 10, unit: "reps", status: .abandoned)
        let ids = NewGoal.options(besides: [bench, dropped]).map(\.id)
        #expect(!ids.contains("bench") && ids.contains("pullups") && ids.contains("squat"))
    }

    @Test func startsFromLogsThenTheStartingSetThenWeight() {
        let squat = GoalOption.with(id: "squat")!
        let logged = [LoggedSet(date: start.addingTimeInterval(86_400), exercise: "back-squat", pattern: nil,
                                measurements: [Measurement(metric: "load_lb", value: 225, unit: "lb"), Measurement(metric: "reps", value: 5, unit: "reps")])]
        #expect(NewGoal.baseline(squat, sets: logged, weighIns: [], starts: [], weight: nil, since: start) == 253)
        let set = StartingSet(exercise: "back-squat", measurements: [Measurement(metric: "load_lb", value: 185, unit: "lb"),
                                                                      Measurement(metric: "reps", value: 5, unit: "reps")])
        #expect(NewGoal.baseline(squat, sets: [], weighIns: [], starts: [set], weight: nil, since: start) == 208)
        #expect(NewGoal.baseline(squat, sets: [], weighIns: [], starts: [], weight: 190, since: start) == nil)
        #expect(NewGoal.baseline(GoalOption.with(id: "weight")!, sets: [], weighIns: [], starts: [], weight: 190, since: start) == 190)
    }

    @Test func suggestsATargetALittleOn() {
        #expect(NewGoal.suggested(GoalOption.with(id: "squat")!, from: 253) == 280)
        #expect(NewGoal.suggested(GoalOption.with(id: "pullups")!, from: 6) == 9)
        #expect(NewGoal.suggested(GoalOption.with(id: "weight")!, from: 190) == 180)
        #expect(NewGoal.suggested(GoalOption.with(id: "5k")!, from: 1800) == 1740)
        #expect(NewGoal.suggested(GoalOption.with(id: "bench")!, from: nil) == 185)
    }

    /// TKL-927: two goals on one lift read apart by their targets, in the chooser and before the date is saved.
    @Test func anExistingGoalReadsWithItsTarget() {
        let low = Goal(kind: .training, metric: "back-squat.1rm_lb", target: 225, unit: "lb")
        let high = Goal(kind: .training, metric: "back-squat.1rm_lb", target: 275, unit: "lb")
        #expect(NewGoal.label(low) == "Squat more · 225 lb")
        #expect(NewGoal.label(high) == "Squat more · 275 lb")
        #expect(NewGoal.label(low) != NewGoal.label(high))
        #expect(NewGoal.label(Goal(kind: .training, metric: "pull-up.reps", target: 12, unit: "reps")) == "More pull-ups · 12 reps")
        #expect(NewGoal.label(Goal(kind: .training, metric: Running.metric(meters: 5000), target: 1560, unit: "s")) == "Run a faster 5K · 26:00")
    }

    /// TKL-999: MCP accepts fractional targets, so the chooser and date step keep nearby targets apart.
    @Test func distinguishesNearbyFractionalSquatTargets() {
        let whole = Goal(kind: .training, metric: "back-squat.1rm_lb", target: 225, unit: "lb")
        let fractional = Goal(kind: .training, metric: "back-squat.1rm_lb", target: 225.4, unit: "lb")
        #expect(NewGoal.label(whole) == "Squat more · 225 lb")
        #expect(NewGoal.label(fractional) == "Squat more · 225.4 lb")
        #expect(NewGoal.label(whole) != NewGoal.label(fractional))
    }

    /// TKL-927, TKL-999: the date builds weeks only while there's still no program (one may sync in while the sheet is
    /// open) and the goal is still among the current active goals.
    @Test func aDateBuildsWeeksOnlyWithoutAProgramAndForAnActiveGoal() {
        let goal = Goal(kind: .training, metric: "back-squat.1rm_lb", target: 275, unit: "lb")
        let other = Goal(kind: .training, metric: "bench-press.1rm_lb", target: 225, unit: "lb")
        let profile = Profile(age: 40, weightLb: 190)
        profile.programStart = nil
        profile.targetDate = nil
        #expect(NewGoal.canBuildProgram(for: goal, in: [goal], profile: profile))
        #expect(!NewGoal.canBuildProgram(for: goal, in: [], profile: profile))
        #expect(!NewGoal.canBuildProgram(for: goal, in: [other], profile: profile))
        #expect(!NewGoal.canBuildProgram(for: goal, in: [goal], profile: nil))
        let synced = Profile(age: 40, weightLb: 190)
        synced.programStart = start
        synced.targetDate = start.addingTimeInterval(86_400 * 7 * 8)
        #expect(synced.program != nil)
        #expect(!NewGoal.canBuildProgram(for: goal, in: [goal], profile: synced))
        let dropped = Goal(kind: .training, metric: "back-squat.1rm_lb", target: 275, unit: "lb", status: .abandoned)
        #expect(!NewGoal.canBuildProgram(for: dropped, in: [dropped], profile: profile))
    }

    /// TKL-999: a saved sync deletion detaches a retained Goal and resets `isDeleted` to false; confirming the date
    /// must check current goal membership and leave Profile and Goal untouched.
    @MainActor
    @Test func confirmingDateAfterSavedSyncDeletionLeavesProgramAndGoalUntouched() throws {
        let container = try AppSchema.container(inMemory: true)
        let context = container.mainContext
        let profile = Profile(age: 40, weightLb: 190, now: start)
        profile.programStart = nil
        profile.targetDate = nil
        context.insert(profile)
        let goal = Goal(kind: .training, metric: "back-squat.1rm_lb", target: 245, unit: "lb", now: start)
        context.insert(goal)
        try context.save()

        // Before deletion, membership is checked explicitly even for an attached persisted goal.
        #expect(NewGoal.canBuildProgram(for: goal, in: try context.fetch(FetchDescriptor<Goal>()), profile: profile))
        #expect(!NewGoal.canBuildProgram(for: goal, in: [], profile: profile))

        // The date step holds `goal` while sync applies and saves a tombstone deletion for it.
        try SyncUnits.apply("goal#\(goal.id.uuidString)", body: nil, in: context)
        try context.save()

        #expect(!goal.isDeleted)
        #expect(goal.modelContext == nil)
        let remaining = try context.fetch(FetchDescriptor<Goal>())
        #expect(remaining.isEmpty)
        #expect(!NewGoal.canBuildProgram(for: goal, in: remaining, profile: profile))

        let confirmNow = start.addingTimeInterval(3600)
        let targetDate = NewGoal.suggestedDate(now: confirmNow)
        let started = try NewGoalSheet.confirmExisting(by: targetDate, goal: goal, in: context, now: confirmNow)
        #expect(!started)
        #expect(profile.program == nil)
        #expect(profile.programStart == nil)
        #expect(profile.targetDate == nil)
        #expect(profile.updatedAt == start)
        #expect(try context.fetch(FetchDescriptor<Goal>()).isEmpty)
        #expect(!context.hasChanges)
    }

    /// TKL-999: confirming the date for a persisted active goal that is still present starts the program; an unsaved
    /// deletion leaves Profile and Goal untouched.
    @MainActor
    @Test func confirmingDateForPersistedGoalRespectsLiveMembership() throws {
        let container = try AppSchema.container(inMemory: true)
        let context = container.mainContext
        let profile = Profile(age: 40, weightLb: 190, now: start)
        profile.programStart = nil
        profile.targetDate = nil
        context.insert(profile)
        let liveGoal = Goal(kind: .training, metric: "back-squat.1rm_lb", target: 225.4, unit: "lb", now: start)
        let deletedGoal = Goal(kind: .training, metric: "back-squat.1rm_lb", target: 225, unit: "lb", now: start)
        context.insert(liveGoal)
        context.insert(deletedGoal)
        try context.save()

        // Unsaved deletion also blocks confirming the date and leaves both Profile and Goal untouched.
        try SyncUnits.apply("goal#\(deletedGoal.id.uuidString)", body: nil, in: context)
        let confirmNow = start.addingTimeInterval(3600)
        let targetDate = NewGoal.suggestedDate(now: confirmNow)
        #expect(try !NewGoalSheet.confirmExisting(by: targetDate, goal: deletedGoal, in: context, now: confirmNow))
        #expect(profile.program == nil)
        #expect(profile.targetDate == nil)
        #expect(profile.updatedAt == start)
        #expect(deletedGoal.deadline == nil)
        #expect(deletedGoal.updatedAt == start)

        // Confirming the still-present active goal builds the program and sets its deadline.
        #expect(try NewGoalSheet.confirmExisting(by: targetDate, goal: liveGoal, in: context, now: confirmNow))
        #expect(profile.program != nil)
        #expect(profile.targetDate == Calendar.current.startOfDay(for: targetDate))
        #expect(liveGoal.deadline == Calendar.current.startOfDay(for: targetDate))
    }
}
