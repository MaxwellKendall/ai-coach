import SwiftUI
import SwiftData

/// FIT-179: log a run, by hand: distance, time, heart rate and what kind of run. It's a workout entry on one of the
/// catalog's runs (Running.runs) with distance_m, duration_s and hr_avg, as the server's log_run saves it, and a
/// race-time goal follows it. Nothing is written until Save.
struct RunLogSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var templates: [Template]
    @FocusState private var typing: Bool

    private let planned: PlannedActivity?
    @State private var date: Date
    @State private var km: Double?
    @State private var time: String
    @State private var heartRate: Int?
    @State private var kind: String
    @State private var treadmill: Bool
    @State private var note = ""

    static let kinds = ["easy", "long", "tempo", "intervals", "race"]

    /// A run of your own, or the planned one with its distance and time filled in.
    init(planned: PlannedActivity? = nil, templates: [Template] = []) {
        self.planned = planned
        let distance = planned?.targets.first { $0.metric == "distance_m" }?.value
        let seconds = planned?.targets.first { $0.metric == "duration_s" }?.value
        _date = State(initialValue: planned.map { Calendar.current.isDateInToday($0.date) ? .now : $0.date } ?? .now)
        _km = State(initialValue: distance.map { $0 / 1000 })
        _time = State(initialValue: seconds.map(Running.clock) ?? "")
        _kind = State(initialValue: planned.flatMap { Self.kinds.contains($0.note) ? $0.note : nil } ?? "easy")
        _treadmill = State(initialValue: planned?.templateRef.flatMap { id in templates.first { $0.id == id }?.slug } == "running-treadmill")
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Distance") {
                    HStack(spacing: 4) {
                        TextField("0", value: $km, format: .number).keyboardType(.decimalPad).focused($typing).multilineTextAlignment(.trailing)
                            .frame(width: 90)
                        Text("km").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Time") {
                    TextField("48:30", text: $time).keyboardType(.numbersAndPunctuation).focused($typing).multilineTextAlignment(.trailing)
                        .frame(width: 120)
                }
                LabeledContent("Avg heart rate") {
                    HStack(spacing: 4) {
                        TextField("–", value: $heartRate, format: .number).keyboardType(.numberPad).focused($typing).multilineTextAlignment(.trailing)
                            .frame(width: 90)
                        Text("bpm").foregroundStyle(.secondary)
                    }
                }
            } footer: {
                if let seconds, let km, km > 0 { Text(Running.pace(seconds: seconds, meters: km * 1000)) }
            }
            Section {
                Picker("Kind", selection: $kind) {
                    ForEach(Self.kinds, id: \.self) { Text($0.capitalized) }
                }
                Toggle("Treadmill", isOn: $treadmill)
                DatePicker("When", selection: $date)
                TextField("How it felt", text: $note, axis: .vertical)
            }
        }
        .navigationTitle("Log a run")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(seconds == nil || (km ?? 0) <= 0) }
            ToolbarItem(placement: .keyboard) {
                HStack {
                    Spacer()
                    Button("Done") { typing = false }
                }
            }
        }
    }

    private var seconds: Double? { Running.seconds(time) }

    private func save() {
        guard let seconds, let km, km > 0 else { return }
        let slug = treadmill ? "running-treadmill" : Running.outdoor
        var measurements = [Measurement(metric: "distance_m", value: (km * 1000).rounded(), unit: "m"),
                            Measurement(metric: "duration_s", value: seconds, unit: "s")]
        if let heartRate, heartRate > 0 { measurements.append(Measurement(metric: "hr_avg", value: Double(heartRate), unit: "bpm")) }
        let said = note.trimmingCharacters(in: .whitespacesAndNewlines)
        context.insert(LogEntry(kind: .workout, timestamp: date, plannedRef: planned?.id,
                                templateRef: templates.first { $0.slug == slug }?.id, measurements: measurements,
                                note: said.isEmpty ? kind : "\(kind): \(said)"))
        dismiss()
    }
}
