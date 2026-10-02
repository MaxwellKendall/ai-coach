import SwiftUI
import SwiftData

/// Any metric, target and optional deadline, e.g. "Grocery spend" 120 $/week.
struct GoalEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @FocusState private var typing: Bool
    @State private var kind = GoalKind.training
    @State private var name = ""
    @State private var target: Double?
    @State private var unit = ""
    @State private var hasDeadline = false
    @State private var deadline = Calendar.current.date(byAdding: .month, value: 3, to: .now)!

    var body: some View {
        Form {
            Picker("Kind", selection: $kind) {
                ForEach(GoalKind.allCases, id: \.self) { Text($0.rawValue.capitalized) }
            }
            TextField("What to track, e.g. Grocery spend", text: $name)
            LabeledContent("Target") {
                TextField("Number", value: $target, format: .number).keyboardType(.decimalPad).focused($typing).multilineTextAlignment(.trailing)
            }
            TextField("Unit, e.g. $/week", text: $unit).textInputAutocapitalization(.never)
            Toggle("Deadline", isOn: $hasDeadline)
            if hasDeadline { DatePicker("By", selection: $deadline, displayedComponents: .date) }
        }
        .navigationTitle("New goal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .keyboard) {
                HStack {
                    Spacer()
                    Button("Done") { typing = false }
                }
            }
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    context.insert(Goal(kind: kind, metric: CatalogImporter.snakeCase(name), target: target ?? 0,
                                        unit: unit.trimmingCharacters(in: .whitespaces), deadline: hasDeadline ? deadline : nil))
                    dismiss()
                }
                .disabled(CatalogImporter.snakeCase(name).isEmpty || target == nil)
            }
        }
    }
}
