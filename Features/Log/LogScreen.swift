import SwiftUI
import SwiftData

struct LogScreen: View {
    @Query(sort: \LogEntry.timestamp, order: .reverse) private var entries: [LogEntry]

    var body: some View {
        NavigationStack {
            List(entries) { entry in
                LabeledContent(entry.kind.rawValue.capitalized,
                               value: entry.timestamp.formatted(date: .abbreviated, time: .shortened))
            }
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView("Nothing logged yet", systemImage: "square.and.pencil")
                }
            }
            .navigationTitle("Log")
        }
    }
}
