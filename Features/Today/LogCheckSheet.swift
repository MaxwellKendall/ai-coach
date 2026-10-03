import SwiftUI
import SwiftData

/// FIT-9 check sheet: one editable card per entry, and Save is the only save.
struct LogCheckSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State var entries: [LogDraftEntry]
    @State private var removed: LogDraftEntry?
    @FocusState private var typing: Bool

    private var savable: [LogDraftEntry] { entries.filter(\.isValid) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach($entries) { $entry in
                        card($entry)
                    }
                    if let removed {
                        Button("Removed \(title(removed)). Undo", systemImage: "arrow.uturn.backward") {
                            entries.append(removed)
                            self.removed = nil
                        }
                        .font(.subheadline)
                    }
                }
                .padding(16)
            }
            .background(Color(.secondarySystemBackground))
            .navigationTitle("Check")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .keyboard) { Button("Done") { typing = false } }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    savable.forEach { context.insert($0.makeEntry()) }
                    dismiss()
                } label: {
                    Text(savable.count == 1 ? "Save entry" : "Save \(savable.count) entries")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(savable.isEmpty)
                .padding(16)
            }
        }
    }

    private func title(_ entry: LogDraftEntry) -> String {
        entry.note.isEmpty ? entry.kind == .bodyweight ? "weight" : entry.kind.rawValue : entry.note
    }

    private func card(_ entry: Binding<LogDraftEntry>) -> some View {
        let kind = entry.wrappedValue.kind
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(kind == .bodyweight ? "Weight" : kind == .grocery ? "Groceries" : kind.rawValue.capitalized,
                      systemImage: Self.icon(kind))
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.tint)
                Spacer()
                DatePicker("When", selection: entry.timestamp).labelsHidden()
                Button("Remove", systemImage: "xmark") {
                    removed = entry.wrappedValue
                    entries.removeAll { $0.id == entry.wrappedValue.id }
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            if kind == .meal {
                TextField("What you ate", text: entry.note).font(.headline).focused($typing)
                if entry.wrappedValue.templateRef == nil {
                    Text("Not in your catalog. Add calories and protein if you know them, or leave them blank.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(entry.fields) { $field in
                FieldRow(field: $field, focus: $typing)
            }
        }
        .padding(14)
        .background(.background, in: .rect(cornerRadius: 16))
    }

    static func icon(_ kind: ActivityKind) -> String {
        switch kind {
        case .sleep: "moon.fill"
        case .bodyweight: "scalemass"
        case .grocery: "cart"
        default: "fork.knife"
        }
    }
}

/// A number with −/+. Blank and inferred values are drawn dashed until the user touches them.
private struct FieldRow: View {
    @Binding var field: LogDraftEntry.Field
    var focus: FocusState<Bool>.Binding

    var body: some View {
        HStack {
            Text(field.label).foregroundStyle(.secondary)
            Spacer()
            Button("Less", systemImage: "minus") { nudge(-field.step) }
            TextField("–", value: Binding(get: { field.value }, set: { field.value = $0; field.inferred = false }),
                      format: .number.precision(.fractionLength(0...1)))
                .keyboardType(.decimalPad).focused(focus).multilineTextAlignment(.center)
                .frame(width: 72).padding(.vertical, 6)
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: field.value == nil || field.inferred ? [4, 3] : [])))
            Button("More", systemImage: "plus") { nudge(field.step) }
            Text(field.unit).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.6).frame(width: 52, alignment: .leading)
        }
        .labelStyle(.iconOnly).buttonStyle(.bordered)
    }

    private func nudge(_ delta: Double) {
        field.value = max(0, (field.value ?? 0) + delta)
        field.inferred = false
    }
}
