import Foundation

/// FIT-233: a goal an athlete adds after onboarding, from the options onboarding offers. It starts from where they are
/// (their logs since the program started, else their starting set or weight) and suggests a target a step or two on;
/// the date is the program's end. It syncs as any goal does (`goal#…`), so their coach sees it.
enum NewGoal {
    /// The options they don't already have as an active goal.
    static func options(besides goals: [Goal]) -> [GoalOption] {
        let have = Set(goals.filter { $0.status == .active }.map(\.metric))
        return GoalOption.all.filter { !have.contains($0.metric) }
    }

    /// Where the goal starts: logged since `since`, else the starting set they gave (an estimated max, or reps), else
    /// their weight for a weight goal. Nil when nothing's known.
    static func baseline(_ option: GoalOption, sets: [LoggedSet], weighIns: [DatedValue], starts: [StartingSet],
                         weight: Double?, since: Date) -> Double? {
        if let logged = GoalProgress.current(option.metric, sets: sets, weighIns: weighIns, since: since) { return logged }
        if option.measure == .body { return weight }
        guard let start = starts.first(where: { $0.exercise == option.exercise }) else { return nil }
        if option.measure == .reps { return start.value("reps") }
        guard let load = start.value("load_lb"), let reps = start.value("reps") else { return nil }
        return ProgramPlan.estimatedMax(load: load, reps: reps).rounded()
    }

    /// A first target to nudge from: about 10% on for a max, 3 more reps, 10 lb lighter, a minute faster; or a round
    /// number when there's no start.
    static func suggested(_ option: GoalOption, from start: Double?) -> Double {
        guard let start else {
            return ["squat": 225, "bench": 185, "deadlift": 275, "pullups": 10, "pushups": 30, "weight": 180][option.id]
                ?? (option.meters.map { $0 * 0.3 } ?? 100)
        }
        switch option.measure {
        case .load: return TrainingGenerator.roundTo5(start * 1.1)
        case .reps: return start + 3
        case .body: return (start - 10).rounded()
        case .time: return max(60, start - 60)
        }
    }

    /// TKL-845: the date a program built from a goal is suggested to end: twelve weeks from this week's start.
    static func suggestedDate(now: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: 7 * 12 - 1, to: Week.start(of: now, calendar: calendar))!
    }

    /// TKL-927: a goal they have, with its target, so two on one lift read apart: "Squat more · 275 lb".
    static func label(_ goal: Goal) -> String {
        guard let option = GoalOption.all.first(where: { $0.metric == goal.metric }) else {
            return "\(Goal.label(goal.metric)) · \(Coach.number(goal.target)) \(goal.unit)".trimmingCharacters(in: .whitespaces)
        }
        return "\(option.title) · \(option.format(goal.target)) \(option.shownUnit)".trimmingCharacters(in: .whitespaces)
    }

    /// TKL-927: a date builds the weeks around a goal they have only while there's still no program (one may have
    /// synced in while the sheet was open) and the goal is still active and theirs.
    static func canBuildProgram(for goal: Goal, profile: Profile?) -> Bool {
        guard let profile, profile.program == nil else { return false }
        return goal.status == .active && !goal.isDeleted
    }
}
