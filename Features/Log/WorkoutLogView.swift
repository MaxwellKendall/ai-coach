import SwiftUI
import SwiftData

/// "Did Session B": the planned sets pre-filled. Tick what you did, fix any numbers, rate the session, Save.
struct WorkoutLogView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var templates: [Template]
    @State var draft: WorkoutDraft
    let date: Date
    @FocusState private var typing: Bool

    var body: some View {
        let names = Dictionary(templates.map { ($0.slug, $0.name) }, uniquingKeysWith: { first, _ in first })
        let groups = Dictionary(grouping: draft.rows.indices, by: { draft.rows[$0].exercise })
        let order = draft.rows.map(\.exercise).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        Form {
            ForEach(order, id: \.self) { exercise in
                Section(names[exercise] ?? exercise) {
                    ForEach(groups[exercise] ?? [], id: \.self) { index in row($draft.rows[index]) }
                }
            }
            Section {
                Stepper("Effort \(Int(draft.effort ?? 7))/10", value: rating(\.effort, 7), in: 1...10)
                Stepper("Energy \(Int(draft.energy ?? 3))/5", value: rating(\.energy, 3), in: 1...5)
                Stepper("Form \(Int(draft.form ?? 3))/5", value: rating(\.form, 3), in: 1...5)
                LabeledContent("Completed", value: draft.completion.formatted(.percent.precision(.fractionLength(0))))
            } header: {
                Text("How did it go")
            }
        }
        .navigationTitle(draft.session)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save).disabled(!draft.rows.contains(where: \.done))
            }
            ToolbarItem(placement: .bottomBar) {
                Button("Mark all done") { for index in draft.rows.indices { draft.rows[index].done = true } }
            }
            ToolbarItem(placement: .keyboard) {
                HStack {
                    Spacer()
                    Button("Done") { typing = false }
                }
            }
        }
    }

    /// The form shows a starting value, and saves it as shown.
    private func rating(_ key: WritableKeyPath<WorkoutDraft, Double?>, _ start: Double) -> Binding<Double> {
        Binding(get: { draft[keyPath: key] ?? start }, set: { draft[keyPath: key] = $0 })
    }

    private func row(_ row: Binding<SetRow>) -> some View {
        HStack(spacing: 10) {
            Button {
                row.wrappedValue.done.toggle()
            } label: {
                Image(systemName: row.wrappedValue.done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(row.wrappedValue.done ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)
            field(row.value, unit: SetRow.units[row.wrappedValue.metric] ?? "")
            if row.wrappedValue.loadMetric != nil { field(row.load, unit: SetRow.units[row.wrappedValue.loadMetric!] ?? "") }
            field(row.rpe, unit: "RPE")
        }
    }

    private func field(_ value: Binding<Double?>, unit: String) -> some View {
        HStack(spacing: 3) {
            TextField("–", value: value, format: .number)
                .keyboardType(.decimalPad)
                .focused($typing)
                .multilineTextAlignment(.trailing)
            Text(unit).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func save() {
        draft.effort = draft.effort ?? 7
        draft.energy = draft.energy ?? 3
        draft.form = draft.form ?? 3
        draft.save(at: date, templates: templates, in: context)
        dismiss()
    }
}

extension WorkoutDraft {
    /// One entry per done set, seconds apart so they keep their order (as the history import does),
    /// then the session summary with the user's note. Unrated sets take the session's feel as their RPE.
    /// Shared by the form and workout mode.
    func save(at date: Date, templates: [Template], in context: ModelContext) {
        let ids = Dictionary(templates.map { ($0.slug, $0.id) }, uniquingKeysWith: { first, _ in first })
        for (index, var row) in rows.filter(\.done).enumerated() {
            row.rpe = row.rpe ?? feel?.rpe
            context.insert(LogEntry(kind: .workout, timestamp: date + TimeInterval(index), plannedRef: row.plannedRef,
                                    templateRef: ids[row.exercise], measurements: row.measurements, note: session))
        }
        context.insert(LogEntry(kind: .workout, timestamp: date + TimeInterval(rows.count), measurements: summary,
                                note: note.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
}
