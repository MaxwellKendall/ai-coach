import SwiftUI
import SwiftData

struct LogScreen: View {
    @Query(sort: \LogEntry.timestamp, order: .reverse) private var entries: [LogEntry]
    @Query private var templates: [Template]

    private var days: [(day: Date, entries: [LogEntry])] {
        let calendar = Calendar.current
        var result: [(day: Date, entries: [LogEntry])] = []
        for entry in entries {
            let day = calendar.startOfDay(for: entry.timestamp)
            if result.last?.day == day { result[result.count - 1].entries.append(entry) } else { result.append((day, [entry])) }
        }
        // Newest day first, but each day reads in the order it happened.
        return result.map { ($0.day, $0.entries.reversed()) }
    }

    var body: some View {
        let names = Dictionary(templates.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        NavigationStack {
            List(days, id: \.day) { day in
                Section(day.day.formatted(date: .complete, time: .omitted)) {
                    ForEach(day.entries) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.templateRef.flatMap { names[$0] }
                                 ?? (entry.kind == .meal && !entry.note.isEmpty ? entry.note : entry.kind.rawValue.capitalized))
                            Text(entry.measurements.map(\.display).joined(separator: " · "))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            // Workout notes repeat the session label on every set; meals already show theirs.
                            if ![.workout, .meal].contains(entry.kind), !entry.note.isEmpty {
                                Text(entry.note).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
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

extension Measurement {
    /// "5 reps", "155 lb", "58 g protein", "3/5".
    var display: String {
        let number = value.formatted(.number.precision(.fractionLength(0...1)))
        if unit == "g" { return "\(number) g \(metric.replacingOccurrences(of: "_g", with: ""))" }
        if unit.hasPrefix("/") { return number + unit }
        return "\(number) \(unit)"
    }
}
