import SwiftUI

/// FIT-188: a logged run: its route on a map you can move around, the numbers, its kind and note, and each mile's
/// split when run mode recorded them. Runs logged by hand or by an agent have no route, so they show the numbers.
struct RunDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let run: LogEntry

    var body: some View {
        let facts = RunFacts(run)
        List {
            if let route = facts.route {
                Section {
                    RouteMap(points: route, interactive: true).frame(height: 320).listRowInsets(EdgeInsets())
                }
            }
            Section {
                if let meters = facts.meters { LabeledContent("Distance", value: Running.distance(meters)) }
                if let seconds = facts.seconds { LabeledContent("Time", value: Running.clock(seconds)) }
                if let meters = facts.meters, let seconds = facts.seconds, meters > 0 {
                    LabeledContent("Avg pace", value: Running.pace(seconds: seconds, meters: meters))
                }
                if let bpm = facts.heartRate { LabeledContent("Avg heart rate", value: "\(Int(bpm.rounded())) bpm") }
                if let kind = facts.kind { LabeledContent("Kind", value: kind.capitalized) }
            }
            if !facts.splits.isEmpty {
                Section("Splits") {
                    ForEach(Array(facts.splits.enumerated()), id: \.offset) { index, split in
                        LabeledContent("Mile \(index + 1)", value: Running.clock(split)).monospacedDigit()
                    }
                }
            }
            if let said = facts.said {
                Section("How it felt") { Text(said) }
            }
        }
        .navigationTitle("Run")
        .navigationSubtitle(run.timestamp.formatted(.dateTime.weekday(.wide).month().day().hour().minute()))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}

/// A run logged that day, as a row: its route (or a runner when it has none) and its numbers. Tapping opens the run.
struct RunRow: View {
    let run: LogEntry
    var open: () -> Void

    var body: some View {
        let facts = RunFacts(run)
        Button(action: open) {
            HStack(spacing: 12) {
                if let route = facts.route {
                    RouteMap(points: route).frame(width: 64, height: 64).clipShape(.rect(cornerRadius: 12)).allowsHitTesting(false)
                } else {
                    Image(systemName: "figure.run").font(.title2).frame(width: 64, height: 64)
                        .background(Color.surface, in: .rect(cornerRadius: 12))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Label("Ran", systemImage: "checkmark.circle.fill").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    Text(facts.line).font(.subheadline).foregroundStyle(.primary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// What a run's log entry says, read once.
struct RunFacts {
    var meters: Double?
    var seconds: Double?
    var heartRate: Double?
    var splits: [Double]
    var route: [Polyline.Point]?
    var kind: String?
    var said: String?

    init(_ run: LogEntry) {
        func value(_ metric: String) -> Double? { run.measurements.first { $0.metric == metric }?.value }
        meters = value("distance_m")
        seconds = value("duration_s")
        heartRate = value("hr_avg")
        splits = run.measurements.filter { $0.metric == "split_s" }.map(\.value)
        route = run.route.flatMap(Polyline.decode).flatMap { $0.count > 1 ? $0 : nil }
        // The note is "kind" or "kind: what they said", as the run sheet, run mode and the server write it.
        let first = run.note.prefix(while: \.isLetter).lowercased()
        kind = RunLogSheet.kinds.contains(first) ? first : nil
        let rest = kind.map { String(run.note.dropFirst($0.count)).trimmingCharacters(in: CharacterSet(charactersIn: ": ").union(.whitespaces)) } ?? run.note
        said = rest.isEmpty ? nil : rest
    }

    /// "3.1 mi in 25:00, 8:03/mi".
    var line: String {
        guard let meters, let seconds, meters > 0 else { return meters.map(Running.distance) ?? "Run logged" }
        return "\(Running.distance(meters)) in \(Running.clock(seconds)), \(Running.pace(seconds: seconds, meters: meters))"
    }
}
