import SwiftUI
import SwiftData

/// A relative group goal being set (FIT-16): what, how much, by when. "Lose 10 lb by Dec 5".
struct GoalDraft: Equatable {
    var option: GoalOption.ID
    var amount: Double
    var deadline: Date

    init(_ option: GoalOption, deadline: Date = Calendar.current.date(byAdding: .month, value: 2, to: .now)!) {
        self.option = option.id
        amount = Self.defaultAmount(option)
        self.deadline = deadline
    }

    var goal: GoalOption { GoalOption.with(id: option) ?? GoalOption.all[0] }

    /// Lose 10 lb, add 20 lb to a max, 5 more reps.
    static func defaultAmount(_ option: GoalOption) -> Double {
        switch option.measure {
        case .body: -10
        case .load: 20
        case .reps: 5
        }
    }
}

/// The goal's three fields, shared by New Group and Add Goal.
struct GoalFields: View {
    @Binding var draft: GoalDraft

    var body: some View {
        let goal = draft.goal
        Section {
            Picker("Goal", selection: Binding(get: { draft.option }, set: { draft = GoalDraft(GoalOption.with(id: $0)!, deadline: draft.deadline) })) {
                ForEach(GoalOption.all) { Text($0.title).tag($0.id) }
            }
            Stepper(GroupProgress.title(metric: goal.metric, goal: draft.amount, mode: .relative),
                    value: Binding(get: { abs(draft.amount) }, set: { draft.amount = goal.measure == .body ? -$0 : $0 }),
                    in: goal.step...500, step: goal.measure == .load ? 5 : 1)
            DatePicker("By", selection: $draft.deadline, in: Date.now..., displayedComponents: .date)
        } footer: {
            Text("Everyone's progress counts from where they are when they join.")
        }
    }
}

/// FIT-16: a group starts with its first goal, relative so people at different weights compare ("lose 10 lb").
struct NewGroupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Goal.createdAt) private var goals: [Goal]
    let done: (Cloud.GroupSummary) -> Void

    @State private var name = ""
    @State private var goal: GoalDraft?
    @State private var you = YourName()
    @State private var working = false
    @State private var failure: String?

    /// Decision (author, 2026-10-05): live workouts are shared by default, so say so before joining.
    static let sharing = "The group sees your progress on its goals, and your sets live while you train. Turn off live sharing in the group's ⋯ menu."

    /// The goal you're already working on comes first.
    private var suggested: GoalDraft {
        GoalDraft(goals.filter { $0.status == .active }.lazy.compactMap { goal in GoalOption.all.first { $0.metric == goal.metric } }.first
                  ?? GoalOption.all[0])
    }

    var body: some View {
        Form {
            Section {
                TextField("Group Name", text: $name, prompt: Text("Family"))
                    .textInputAutocapitalization(.words)
            }
            GoalFields(draft: Binding(get: { goal ?? suggested }, set: { goal = $0 }))
            you.section
            Section {} footer: { Text(Self.sharing) }
            if let failure { Section { Text(failure).foregroundStyle(.red) } }
        }
        .navigationTitle("New Group")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(working)
        .task { await you.load() }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                if working { ProgressView() } else {
                    Button("Create") { create(goal ?? suggested) }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || !you.isReady)
                }
            }
        }
    }

    private func create(_ goal: GoalDraft) {
        working = true
        failure = nil
        Task {
            defer { working = false }
            do {
                try await you.save()
                let group = try await Cloud.createGroup(name: name.trimmingCharacters(in: .whitespaces), metric: goal.goal.metric,
                                                        target: goal.amount, deadline: goal.deadline)
                done(group)
            } catch {
                failure = "Couldn't create the group. Check your connection and try again."
            }
        }
    }
}

/// FIT-16: any member can add another goal to the group.
struct AddGoalSheet: View {
    @Environment(\.dismiss) private var dismiss
    let groupId: String
    /// Metrics the group already has, so the suggestion is something new.
    let existing: [String]
    let done: (String) -> Void

    @State private var goal: GoalDraft?
    @State private var working = false
    @State private var failure: String?

    private var suggested: GoalDraft {
        GoalDraft(GoalOption.all.first { !existing.contains($0.metric) } ?? GoalOption.all[0])
    }

    var body: some View {
        Form {
            GoalFields(draft: Binding(get: { goal ?? suggested }, set: { goal = $0 }))
            if let failure { Section { Text(failure).foregroundStyle(.red) } }
        }
        .navigationTitle("Add Goal")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(working)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                if working { ProgressView() } else { Button("Add") { add(goal ?? suggested) } }
            }
        }
    }

    private func add(_ goal: GoalDraft) {
        working = true
        failure = nil
        Task {
            defer { working = false }
            do {
                done(try await Cloud.addGoal(to: groupId, metric: goal.goal.metric, target: goal.amount, deadline: goal.deadline))
            } catch {
                failure = "Couldn't add the goal. Check your connection and try again."
            }
        }
    }
}

/// FIT-16/58: join with the code from an invite.
struct JoinGroupSheet: View {
    @Environment(\.dismiss) private var dismiss
    var code = ""
    let done: (Cloud.GroupSummary) -> Void

    @State private var typed: String?
    @State private var you = YourName()
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        let entered = typed ?? code
        Form {
            Section {
                TextField("Invite Code", text: Binding(get: { entered }, set: { typed = $0.uppercased() }))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
            } footer: {
                Text("The 8-letter code from your invite.")
            }
            you.section
            Section {} footer: { Text(NewGroupSheet.sharing) }
            if let failure { Section { Text(failure).foregroundStyle(.red) } }
        }
        .navigationTitle("Join Group")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(working)
        .task { await you.load() }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                if working { ProgressView() } else {
                    Button("Join") { join(entered) }
                        .disabled(entered.trimmingCharacters(in: .whitespaces).count < 8 || !you.isReady)
                }
            }
        }
    }

    private func join(_ code: String) {
        working = true
        failure = nil
        Task {
            defer { working = false }
            do {
                try await you.save()
                done(try await Cloud.join(code: code))
            } catch {
                failure = error.localizedDescription.localizedCaseInsensitiveContains("not found")
                    ? "No group has that code. Check it with whoever invited you."
                    : "Couldn't join. Check your connection and try again."
            }
        }
    }
}

/// The name other members see. Asked for only when the account has none (Apple often shares no name).
@MainActor @Observable
final class YourName {
    var text = ""
    private(set) var needed = false

    var isReady: Bool { !needed || !text.trimmingCharacters(in: .whitespaces).isEmpty }

    func load() async {
        needed = (try? await Cloud.profile())??.displayName?.isEmpty ?? true
    }

    func save() async throws {
        let name = text.trimmingCharacters(in: .whitespaces)
        if needed, !name.isEmpty { try await Cloud.setDisplayName(name) }
    }

    @ViewBuilder var section: some View {
        if needed {
            Section {
                TextField("Your Name", text: Binding(get: { self.text }, set: { self.text = $0 }))
                    .textContentType(.givenName)
            } footer: {
                Text("Shown to people in your groups.")
            }
        }
    }
}
