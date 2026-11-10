import SwiftUI
import SwiftData

/// FIT-346: the client changes their own goal (principle 6): its target, and its date or none. It syncs as the goal's
/// `goal#` unit, so the coach sees it.
enum GoalChange {
    @MainActor
    static func apply(_ goal: Goal, target: Double, deadline: Date?, in context: ModelContext, now: Date = .now) throws {
        goal.target = max(0, target)
        goal.deadline = deadline.map { Calendar.current.startOfDay(for: $0) }
        goal.updatedAt = now
        try context.save()
    }
}

/// A goal's target and date, from the ⋯ on its card; Drop is here too.
struct GoalChangeSheet: View {
    let goal: Goal
    let option: GoalOption
    var drop: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var target: Double?
    /// A race time's target, as a clock.
    @State private var clock: String
    @State private var dated: Bool
    @State private var deadline: Date
    @State private var dropping = false
    @State private var failure: String?

    init(goal: Goal, option: GoalOption, drop: @escaping () -> Void) {
        self.goal = goal
        self.option = option
        self.drop = drop
        _target = State(initialValue: goal.target)
        _clock = State(initialValue: Running.clock(goal.target))
        _dated = State(initialValue: goal.deadline != nil)
        _deadline = State(initialValue: goal.deadline ?? Calendar.current.date(byAdding: .month, value: 3, to: .now)!)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Target")
                        Spacer()
                        if option.measure == .time {
                            TextField("25:00", text: $clock).keyboardType(.numbersAndPunctuation)
                                .multilineTextAlignment(.trailing).frame(maxWidth: 110)
                        } else {
                            TextField("–", value: $target, format: .number).keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing).frame(maxWidth: 90)
                            Text(option.unit).foregroundStyle(.secondary)
                        }
                    }
                    Toggle("By a date", isOn: $dated.animation())
                    if dated {
                        DatePicker("Date", selection: $deadline, in: Date.now..., displayedComponents: .date)
                    }
                } header: {
                    Text(option.name)
                } footer: {
                    if let failure { Text(failure).foregroundStyle(.red) } else { Text("Your coach sees the change.") }
                }
                Section {
                    Button("Drop This Goal", role: .destructive) { dropping = true }
                }
            }
            .navigationTitle("Change Goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(value == nil) }
            }
            .confirmationDialog("Drop this goal?", isPresented: $dropping, titleVisibility: .visible) {
                Button("Drop", role: .destructive) {
                    drop()
                    dismiss()
                }
            } message: {
                Text("It stays in your history, and your coach sees you dropped it.")
            }
        }
        .presentationDetents([.medium])
    }

    private var value: Double? {
        let value = option.measure == .time ? Running.seconds(clock) : target
        return value.flatMap { $0 > 0 ? $0 : nil }
    }

    private func save() {
        guard let value else { return }
        do {
            try GoalChange.apply(goal, target: value, deadline: dated ? deadline : nil, in: context)
            dismiss()
        } catch {
            failure = "Couldn’t save that. Try again."
        }
    }
}
