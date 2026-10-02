import SwiftUI
import SwiftData

/// Proposed goals from the profile. Nothing is saved until the user picks and confirms.
struct SuggestedGoalsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @FocusState private var typing: Bool
    @State private var rows: [Row]
    var onDone: () -> Void = {}

    struct Row: Identifiable {
        let id = UUID()
        var seed: GoalSeed
        var selected = true
    }

    init(profile: Profile, existing: Set<String>, onDone: @escaping () -> Void = {}) {
        _rows = State(initialValue: GoalSuggestions.suggestions(
            age: profile.age, weightLb: profile.weightLb, targetWeightLb: profile.targetWeightLb,
            equipment: Set(profile.equipment), existing: existing).map { Row(seed: $0) })
        self.onDone = onDone
    }

    var body: some View {
        List {
            Section {
                ForEach($rows) { $row in
                    HStack {
                        Toggle(Goal.label(row.seed.metric), isOn: $row.selected)
                            .toggleStyle(CheckToggle())
                        TextField("Target", value: $row.seed.target, format: .number)
                            .keyboardType(.decimalPad).focused($typing)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                        Text(row.seed.unit).foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
                    }
                }
            } footer: {
                Text("From your age group's targets and body weight. Edit any number.")
            }
        }
        .overlay {
            if rows.isEmpty { ContentUnavailableView("You already have these goals", systemImage: "checkmark.circle") }
        }
        .navigationTitle("Suggested goals")
        .toolbar {
            ToolbarItem(placement: .keyboard) {
                HStack {
                    Spacer()
                    Button("Done") { typing = false }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                let count = rows.filter(\.selected).count
                Button(count == 0 ? "Skip" : "Add \(count)") { add() }
            }
        }
    }

    private func add() {
        for (index, row) in rows.enumerated() where row.selected {
            context.insert(Goal(kind: row.seed.kind, metric: row.seed.metric, target: row.seed.target, unit: row.seed.unit,
                                deadline: row.seed.deadline, now: .now + TimeInterval(index)))
        }
        onDone()
        dismiss()
    }
}

private struct CheckToggle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Label { configuration.label } icon: {
                Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(configuration.isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
