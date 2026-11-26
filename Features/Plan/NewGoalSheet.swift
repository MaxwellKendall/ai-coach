import SwiftData
import SwiftUI

/// FIT-233: Progress › Goals' "Add a goal": pick one of onboarding's goals they don't have, then its target, saved as a
/// goal of theirs (NewGoal), which their coach sees once it syncs.
struct NewGoalSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var profiles: [Profile]
    @Query private var goals: [Goal]
    @Query private var entries: [LogEntry]
    @Query private var templates: [Template]
    /// TKL-845: from the Program tab without a program: the target step also asks a date, and the goal and date make the
    /// program (Planner.startProgram).
    var building = false
    var existingGoals: [Goal] = []
    var onAdd: (Goal) -> Void = { _ in }

    @State private var picked: GoalOption?
    @State private var existing: Goal?
    @State private var existingLabel = ""
    @State private var target: Double = 0
    @State private var start: Double?
    @State private var by = NewGoal.suggestedDate(now: .now)

    var body: some View {
        NavigationStack {
            Group {
                if let existing {
                    existingDateStep(existing)
                } else if !currentExistingGoals.isEmpty {
                    List(currentExistingGoals) { goal in
                        Button(NewGoal.label(goal)) {
                            by = max(earliest, goal.deadline ?? NewGoal.suggestedDate(now: .now))
                            existingLabel = NewGoal.label(goal)
                            existing = goal
                        }
                    }
                    .navigationTitle("Choose a goal")
                } else if let picked {
                    targetStep(picked)
                } else {
                    optionList
                }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private var currentExistingGoals: [Goal] {
        existingGoals.filter { goal in
            !goal.isDeleted && goals.contains {
                ($0 === goal || $0.persistentModelID == goal.persistentModelID) && $0.status == .active && !$0.isDeleted
            }
        }
    }

    static func title(for goal: Goal) -> String {
        GoalOption.all.first { $0.metric == goal.metric }?.title ?? Goal.label(goal.metric)
    }

    /// TKL-999: confirm the date step for a selected saved goal only while the context still has a profile without a
    /// program and the goal is still a current active goal. Returns false and leaves Profile and Goal untouched when
    /// a sync deleted or dropped the goal, or synced a program in, while the sheet was open.
    @discardableResult
    static func confirmExisting(by date: Date, goal: Goal, in context: ModelContext, now: Date = .now,
                                calendar: Calendar = .current) throws -> Bool {
        let profile = try context.fetch(FetchDescriptor<Profile>()).first
        let currentGoals = try context.fetch(FetchDescriptor<Goal>())
        guard NewGoal.canBuildProgram(for: goal, in: currentGoals, profile: profile), let profile else {
            return false
        }
        try Planner.startProgram(by: date, goal: goal, profile: profile, in: context, now: now, calendar: calendar)
        return true
    }

    private func existingDateStep(_ goal: Goal) -> some View {
        let live = goals.first { ($0 === goal || $0.persistentModelID == goal.persistentModelID) && !$0.isDeleted }
        let heading = live.map(NewGoal.label) ?? existingLabel
        return VStack(alignment: .leading) {
            Text(heading).font(.title2.weight(.bold))
            DatePicker("By", selection: $by, in: earliest..., displayedComponents: .date)
                .font(.body.weight(.semibold))
                .padding(.top, 28)
            Spacer()
            Button {
                // A program that synced in meanwhile, or a goal dropped/deleted meanwhile, keeps what it has.
                if (try? Self.confirmExisting(by: by, goal: goal, in: context)) == true {
                    onAdd(goal)
                }
                dismiss()
            } label: {
                Text("Build My Weeks").font(.headline).frame(maxWidth: .infinity, minHeight: 54)
            }
            .buttonStyle(.primary)
            .accessibilityIdentifier("goal.build")
        }
        .padding(24)
        .navigationTitle("Set a date")
    }

    private var optionList: some View {
        List(NewGoal.options(besides: goals)) { option in
            Button { pick(option) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title).font(.body.weight(.semibold))
                    Text(option.why).font(.footnote).foregroundStyle(Color.inkMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .navigationTitle(building ? "Set a goal" : "Add a goal")
    }

    private func targetStep(_ option: GoalOption) -> some View {
        let unit = option.measure == .time ? "" : option.unit
        return VStack(alignment: .leading, spacing: 0) {
            Text(option.name).font(.title2.weight(.bold))
            Text(start.map { "From \(option.format($0)) \(unit) now".trimmingCharacters(in: .whitespaces) } ?? "Your target")
                .font(.body).foregroundStyle(Color.inkMuted).padding(.top, 6)
            Nudge(label: "\(option.format(target)) \(unit)".trimmingCharacters(in: .whitespaces),
                  lessLabel: "Lower the target", moreLabel: "Raise the target",
                  less: { target = max(option.step, target - option.step) }, more: { target += option.step })
                .padding(.top, 24)
            if building {
                DatePicker("By", selection: $by, in: earliest..., displayedComponents: .date)
                    .font(.body.weight(.semibold))
                    .padding(.top, 28)
            }
            Spacer()
            Button { save(option) } label: {
                Text(building ? "Build My Weeks" : "Add the Goal").font(.headline).frame(maxWidth: .infinity, minHeight: 54)
            }
            .buttonStyle(.primary)
            .accessibilityIdentifier(building ? "goal.build" : "goal.add")
        }
        .padding(24)
    }

    private func pick(_ option: GoalOption) {
        let profile = profiles.first
        let since = profile?.programStart ?? .distantPast
        let weighIns = entries.filter { $0.kind == .bodyweight }.compactMap { entry in
            entry.measurements.first { $0.metric == "weight_lb" }.map { DatedValue(date: entry.timestamp, value: $0.value) }
        }
        start = NewGoal.baseline(option, sets: Planner.loggedSets(entries, templates: templates), weighIns: weighIns,
                                 starts: profile?.starts ?? [], weight: profile?.weightLb, since: since)
        target = NewGoal.suggested(option, from: start)
        withAnimation(.tap) { picked = option }
    }

    private func save(_ option: GoalOption) {
        let profile = profiles.first
        // Without a profile there's no program to build; the goal still keeps its date.
        let deadline = building ? Calendar.current.startOfDay(for: by) : profile?.targetDate ?? profile?.program.flatMap { weeks in
            profile?.programStart.map { ProgramPlan.monday(weeks.count, start: $0) }
        }
        let goal = Goal(kind: option.kind, metric: option.metric, target: target, unit: option.unit, deadline: deadline)
        goal.baseline = start
        context.insert(goal)
        if building, let profile {
            try? Planner.startProgram(by: by, goal: goal, profile: profile, in: context)
        }
        try? context.save()
        onAdd(goal)
        dismiss()
    }

    /// A program is at least two weeks: the date is no sooner than next week's end.
    private var earliest: Date { Calendar.current.date(byAdding: .day, value: 13, to: Week.start(of: .now))! }
}
