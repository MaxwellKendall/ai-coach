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
    var onAdd: (Goal) -> Void = { _ in }

    @State private var picked: GoalOption?
    @State private var target: Double = 0
    @State private var start: Double?

    var body: some View {
        NavigationStack {
            Group {
                if let picked { targetStep(picked) } else { optionList }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
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
        .navigationTitle("Add a goal")
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
            Spacer()
            Button { save(option) } label: {
                Text("Add the Goal").font(.headline).frame(maxWidth: .infinity, minHeight: 54)
            }
            .buttonStyle(.primary)
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
        withAnimation(.snappy) { picked = option }
    }

    private func save(_ option: GoalOption) {
        let profile = profiles.first
        let deadline = profile?.targetDate ?? profile?.program.flatMap { weeks in
            profile?.programStart.map { ProgramPlan.monday(weeks.count, start: $0) }
        }
        let goal = Goal(kind: option.kind, metric: option.metric, target: target, unit: option.unit, deadline: deadline)
        goal.baseline = start
        context.insert(goal)
        try? context.save()
        onAdd(goal)
        dismiss()
    }
}
