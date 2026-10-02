import SwiftUI
import SwiftData

/// One editor for any kind of entry: unplanned ones, planned meals/cooks/grocery runs, and explicit edits
/// of saved entries. Nothing is written until Save.
struct EntryEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Template.name) private var templates: [Template]
    @FocusState private var typing: Bool

    private let existing: LogEntry?
    private let plannedRef: UUID?
    @State private var kind: ActivityKind
    @State private var timestamp: Date
    @State private var templateRef: UUID?
    @State private var rows: [Row]
    @State private var note: String

    struct Row: Identifiable {
        let id = UUID()
        var metric: String
        var value: Double?
        var unit: String
    }

    /// New entry, optionally from a planned item.
    init(kind: ActivityKind = .meal, planned: PlannedActivity? = nil) {
        existing = nil
        plannedRef = planned?.id
        let kind = planned?.kind ?? kind
        _kind = State(initialValue: kind)
        _timestamp = State(initialValue: .now)
        _templateRef = State(initialValue: planned?.templateRef)
        let measurements = planned.map { $0.targets.filter { $0.metric != "sets" } } ?? LogPresets.measurements(for: kind)
        _rows = State(initialValue: Self.rows(measurements, blankZeros: planned == nil))
        _note = State(initialValue: planned?.slot ?? "")
    }

    /// Explicit edit of a saved entry.
    init(editing entry: LogEntry) {
        existing = entry
        plannedRef = entry.plannedRef
        _kind = State(initialValue: entry.kind)
        _timestamp = State(initialValue: entry.timestamp)
        _templateRef = State(initialValue: entry.templateRef)
        _rows = State(initialValue: Self.rows(entry.measurements, blankZeros: false))
        _note = State(initialValue: entry.note)
    }

    private static func rows(_ measurements: [Measurement], blankZeros: Bool) -> [Row] {
        measurements.map { Row(metric: $0.metric, value: blankZeros && $0.value == 0 ? nil : $0.value, unit: $0.unit) }
    }

    var body: some View {
        Form {
            Section {
                Picker("Kind", selection: $kind) {
                    ForEach(ActivityKind.allCases, id: \.self) { Text($0.rawValue.capitalized) }
                }
                .onChange(of: kind) { _, kind in
                    if rows.allSatisfy({ $0.value == nil }) { rows = Self.rows(LogPresets.measurements(for: kind), blankZeros: true) }
                }
                DatePicker("When", selection: $timestamp)
                if kind == .workout {
                    Picker("Exercise", selection: $templateRef) {
                        Text("None").tag(UUID?.none)
                        ForEach(templates.filter { $0.kind == .exercise }) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                }
                TextField(kind == .meal ? "What you ate" : "Note", text: $note, axis: .vertical)
            }
            Section("Measurements") {
                ForEach($rows) { $row in
                    HStack {
                        TextField("metric", text: $row.metric).textInputAutocapitalization(.never)
                        TextField("–", value: $row.value, format: .number)
                            .keyboardType(.decimalPad).focused($typing).multilineTextAlignment(.trailing)
                        TextField("unit", text: $row.unit).textInputAutocapitalization(.never).frame(width: 56)
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete { rows.remove(atOffsets: $0) }
                Button("Add measurement", systemImage: "plus") { rows.append(Row(metric: "", value: nil, unit: "")) }
            }
        }
        .navigationTitle(existing == nil ? "Log \(kind.rawValue)" : "Edit entry")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(measurements.isEmpty) }
            ToolbarItem(placement: .keyboard) {
                HStack {
                    Spacer()
                    Button("Done") { typing = false }
                }
            }
        }
    }

    private var measurements: [Measurement] {
        rows.compactMap { row in
            let metric = CatalogImporter.snakeCase(row.metric)
            guard !metric.isEmpty, let value = row.value else { return nil }
            return Measurement(metric: metric, value: value, unit: row.unit.trimmingCharacters(in: .whitespaces))
        }
    }

    private func save() {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing {
            existing.kind = kind
            existing.timestamp = timestamp
            existing.templateRef = templateRef
            existing.measurements = measurements
            existing.note = trimmed
            existing.updatedAt = .now
        } else {
            context.insert(LogEntry(kind: kind, timestamp: timestamp, plannedRef: plannedRef, templateRef: templateRef,
                                    measurements: measurements, note: trimmed))
        }
        dismiss()
    }
}
