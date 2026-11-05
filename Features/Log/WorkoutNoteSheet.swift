import SwiftData
import SwiftUI

/// A note on a saved workout, added or changed any time after ("that was hard: slept 5 hours"). It's the session
/// summary's note, the one the finish screen and the MCP's add_note write, so the coach's triage and the weekly
/// review read it too.
struct WorkoutNoteSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @FocusState private var typing: Bool
    let summary: LogEntry
    @State private var note: String

    init(summary: LogEntry, note: String) {
        self.summary = summary
        _note = State(initialValue: note)
    }

    var body: some View {
        Form {
            TextField("How it went, and why", text: $note, axis: .vertical).lineLimit(4...12).focused($typing)
        }
        .navigationTitle("Note")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
        }
        .onAppear { typing = true }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        summary.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        summary.updatedAt = .now
        try? context.save()
        dismiss()
    }
}
