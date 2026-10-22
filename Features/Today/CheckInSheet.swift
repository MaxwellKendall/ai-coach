import SwiftUI
import SwiftData

/// FIT-204: the day's check-in for the coach: body weight, hours slept and a note, each optional. Saved as the same
/// rows the MCP's log_daily writes (a `bodyweight` row with weight_lb, a `sleep` row with sleep_h), one of each a day.
@MainActor
enum CheckIn {
    /// Replaces the day's weight and sleep with what's given; what's left out stays as it was. The note rides on the
    /// day's check-in row (sleep, else weight), since a day has nowhere else for one without a workout.
    static func save(weight: Double?, sleep: Double?, note: String, on day: Date, in context: ModelContext, now: Date = .now) throws {
        let today = try entries(on: day, in: context)
        let at = Calendar.current.isDate(day, inSameDayAs: now) ? now : Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: day)!
        func replace(_ kind: ActivityKind, _ measurement: Measurement?) -> LogEntry? {
            guard let measurement else { return today.first { $0.kind == kind } }
            today.filter { $0.kind == kind }.forEach(context.delete)
            let entry = LogEntry(kind: kind, timestamp: at, measurements: [measurement], now: now)
            context.insert(entry)
            return entry
        }
        let weighed = replace(.bodyweight, weight.map { Measurement(metric: "weight_lb", value: $0, unit: "lb") })
        let slept = replace(.sleep, sleep.map { Measurement(metric: "sleep_h", value: $0, unit: "h") })
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty {
            let holder = slept ?? weighed ?? {
                // A note on its own: a weight row with no weight, which nothing counts as a weigh-in.
                let entry = LogEntry(kind: .bodyweight, timestamp: at, now: now)
                context.insert(entry)
                return entry
            }()
            holder.note = note
            holder.updatedAt = now
        }
        try context.save()
    }

    /// The day's weight and sleep rows.
    static func entries(on day: Date, in context: ModelContext) throws -> [LogEntry] {
        let start = Calendar.current.startOfDay(for: day), end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        return try context.fetch(FetchDescriptor<LogEntry>(predicate: #Predicate { $0.timestamp >= start && $0.timestamp < end }))
            .filter { $0.kind == .bodyweight || $0.kind == .sleep }
    }

    /// "182 lb · 7 h", what today's check-in said, or nil before one.
    static func summary(_ entries: [LogEntry]) -> String? {
        let weight = entries.first { $0.kind == .bodyweight }?.measurements.first { $0.metric == "weight_lb" }?.value
        let sleep = entries.first { $0.kind == .sleep }?.measurements.first { $0.metric == "sleep_h" }?.value
        let parts = [weight.map { "\(Coach.number($0)) lb" }, sleep.map { "\(Coach.number($0)) h sleep" }].compactMap { $0 }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        return entries.contains { !$0.note.isEmpty } ? "Note sent" : nil
    }
}

struct CheckInSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    /// The last weight logged, as the field's hint.
    var lastWeight: Double?

    @State private var weight = ""
    @State private var sleep = ""
    @State private var note = ""
    @State private var failure: String?
    @FocusState private var focused: Field?

    enum Field { case weight, sleep, note }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    row("Weight", "lb", text: $weight, hint: lastWeight.map(Coach.number) ?? "180", field: .weight)
                    row("Sleep", "hours", text: $sleep, hint: "7.5", field: .sleep)
                    TextField("How are you feeling? Anything sore?", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                        .focused($focused, equals: .note)
                } footer: {
                    Text(failure ?? "Your coach sees this with your training. Leave out anything you like.")
                        .foregroundStyle(failure == nil ? Color.secondary : Color.red)
                }
            }
            .navigationTitle("Check In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(number(weight) == nil && number(sleep) == nil && note.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { focused = .weight }
        }
        .presentationDetents([.medium])
    }

    private func row(_ name: String, _ unit: String, text: Binding<String>, hint: String, field: Field) -> some View {
        HStack {
            Text(name)
            Spacer()
            TextField(hint, text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 90)
                .focused($focused, equals: field)
            Text(unit).foregroundStyle(.secondary)
        }
    }

    private func number(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
    }

    private func save() {
        let weight = number(weight), sleep = number(sleep)
        if let weight, !(50...700).contains(weight) { failure = "Weight is in pounds, between 50 and 700."; return }
        if let sleep, !(0...24).contains(sleep) { failure = "Sleep is hours, 0 to 24."; return }
        do {
            try CheckIn.save(weight: weight, sleep: sleep, note: note, on: .now, in: context)
            dismiss()
        } catch {
            failure = "Couldn’t save that. Try again."
        }
    }
}
