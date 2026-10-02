import SwiftUI
import SwiftData

/// Hand edit of one planned session (FIT-20): swap, retarget, remove or add exercises.
/// Works on a copy; nothing changes until Save, and changed items are marked "edited".
struct WorkoutEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Template.name) private var templates: [Template]
    let items: [PlannedActivity]
    @State private var rows: [Row]

    struct Row: Identifiable {
        var id = UUID()
        var original: PlannedActivity?
        var templateRef: UUID?
        var targets: [Measurement]
        var note: String
    }

    init(items: [PlannedActivity]) {
        self.items = items
        _rows = State(initialValue: items.sorted { $0.date < $1.date }.map {
            Row(original: $0, templateRef: $0.templateRef, targets: $0.targets, note: $0.note)
        })
    }

    var body: some View {
        let exercises = templates.filter { $0.kind == .exercise }
        Form {
            ForEach($rows) { $row in
                Section {
                    Picker("Exercise", selection: $row.templateRef) {
                        ForEach(exercises) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    ForEach($row.targets, id: \.metric) { $target in
                        Stepper(value: $target.value, in: 0...10_000, step: Self.step(target.metric)) {
                            LabeledContent(Self.label(target.metric), value: target.display)
                        }
                    }
                    if !row.note.isEmpty { Text(row.note).foregroundStyle(.secondary) }
                    Button("Remove", systemImage: "trash", role: .destructive) {
                        withAnimation { rows.removeAll { $0.id == row.id } }
                    }
                }
            }
            Section {
                Menu("Add exercise", systemImage: "plus") {
                    ForEach(exercises) { template in
                        Button(template.name) { add(template) }
                    }
                }
            }
        }
        .navigationTitle(items.first?.slot ?? "Workout")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(rows.isEmpty) }
        }
    }

    nonisolated static func step(_ metric: String) -> Double {
        switch metric {
        case "rpe": 0.5
        case "duration_s", "distance_m", "load_lb", "load_lb_hand": 5
        default: 1
        }
    }

    nonisolated static func label(_ metric: String) -> String {
        ["sets": "Sets", "reps": "Reps", "load_lb": "Load", "load_lb_hand": "Load per hand", "rpe": "RPE cap",
         "duration_s": "Time", "distance_m": "Distance"][metric] ?? Goal.label(metric)
    }

    /// New exercises start at 3×10 with the RPE cap of the session's other sets.
    private func add(_ template: Template) {
        let rpe = rows.lazy.compactMap { $0.targets.first { $0.metric == "rpe" } }.first
        let targets = [Measurement(metric: "sets", value: 3, unit: "sets"), Measurement(metric: "reps", value: 10, unit: "reps")]
            + (rpe.map { [$0] } ?? [])
        rows.append(Row(templateRef: template.id, targets: targets, note: ""))
    }

    private func save() {
        guard let first = items.min(by: { $0.date < $1.date }) else { return dismiss() }
        let kept = Set(rows.compactMap(\.original?.id))
        for item in items where !kept.contains(item.id) { context.delete(item) }
        for (order, row) in rows.enumerated() {
            // Second offsets keep the edited order, as the planner does.
            let date = first.date + TimeInterval(order)
            if let item = row.original {
                if item.templateRef != row.templateRef || item.targets != row.targets {
                    item.adjustedReason = "edited"
                }
                item.templateRef = row.templateRef
                item.targets = row.targets
                item.date = date
                item.updatedAt = .now
            } else {
                let item = PlannedActivity(kind: .workout, date: date, slot: first.slot, templateRef: row.templateRef,
                                           targets: row.targets, adjustedReason: "edited")
                item.plan = first.plan
                context.insert(item)
            }
        }
        dismiss()
    }
}
