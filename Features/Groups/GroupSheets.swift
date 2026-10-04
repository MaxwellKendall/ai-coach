import SwiftUI
import SwiftData

/// FIT-16: a group starts with its shared goal, relative so people at different weights compare ("lose 10 lb").
struct NewGroupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Goal.createdAt) private var goals: [Goal]
    let done: (Cloud.GroupSummary) -> Void

    @State private var name = ""
    @State private var option: String?
    @State private var amount: Double?
    @State private var deadline = Calendar.current.date(byAdding: .month, value: 2, to: .now)!
    @State private var you = YourName()
    @State private var working = false
    @State private var failure: String?

    /// The goal you're already working on comes first.
    private var picked: GoalOption {
        option.flatMap(GoalOption.with(id:))
            ?? goals.filter { $0.status == .active }.lazy.compactMap { goal in GoalOption.all.first { $0.metric == goal.metric } }.first
            ?? GoalOption.all[0]
    }

    /// Lose 10 lb, add 20 lb to a max, 5 more reps.
    private static func defaultAmount(_ option: GoalOption) -> Double {
        switch option.measure {
        case .body: -10
        case .load: 20
        case .reps: 5
        }
    }

    var body: some View {
        let option = picked
        let amount = amount ?? Self.defaultAmount(option)
        Form {
            Section {
                TextField("Group Name", text: $name, prompt: Text("Family"))
                    .textInputAutocapitalization(.words)
            }
            Section {
                Picker("Goal", selection: Binding(get: { option.id }, set: { self.option = $0; self.amount = nil })) {
                    ForEach(GoalOption.all) { Text($0.title).tag($0.id) }
                }
                Stepper(GroupProgress.title(metric: option.metric, goal: amount, mode: .relative),
                        value: Binding(get: { abs(amount) }, set: { self.amount = option.measure == .body ? -$0 : $0 }),
                        in: option.step...500, step: option.measure == .load ? 5 : 1)
                DatePicker("By", selection: $deadline, in: Date.now..., displayedComponents: .date)
            } footer: {
                Text("Everyone's progress counts from where they are when they join.")
            }
            you.section
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
                    Button("Create") { create(option, amount) }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || !you.isReady)
                }
            }
        }
    }

    private func create(_ option: GoalOption, _ amount: Double) {
        working = true
        failure = nil
        Task {
            defer { working = false }
            do {
                try await you.save()
                let group = try await Cloud.createGroup(name: name.trimmingCharacters(in: .whitespaces), metric: option.metric,
                                                        target: amount, deadline: deadline)
                done(group)
            } catch {
                failure = "Couldn't create the group. Check your connection and try again."
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
