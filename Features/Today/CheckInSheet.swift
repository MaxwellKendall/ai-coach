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

    /// FIT-345: the day's check-in as the sheet now says it, on any day: a field left empty clears what was there.
    /// Rows already there keep their ids and times, so the day's `log#` unit changes only where the check-in did.
    static func replace(weight: Double?, sleep: Double?, note: String, on day: Date, in context: ModelContext, now: Date = .now) throws {
        let rows = try entries(on: day, in: context)
        let at = Calendar.current.isDate(day, inSameDayAs: now) ? now : Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: day)!
        func set(_ kind: ActivityKind, _ measurement: Measurement?) -> LogEntry? {
            let existing = rows.filter { $0.kind == kind }
            guard let measurement else {
                existing.forEach(context.delete)
                return nil
            }
            existing.dropFirst().forEach(context.delete)
            let entry = existing.first ?? {
                let entry = LogEntry(kind: kind, timestamp: at, now: now)
                context.insert(entry)
                return entry
            }()
            entry.measurements = [measurement]
            entry.note = ""
            entry.updatedAt = now
            return entry
        }
        let weighed = set(.bodyweight, weight.map { Measurement(metric: "weight_lb", value: $0, unit: "lb") })
        let slept = set(.sleep, sleep.map { Measurement(metric: "sleep_h", value: $0, unit: "h") })
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty {
            let holder = slept ?? weighed ?? {
                let entry = LogEntry(kind: .bodyweight, timestamp: at, now: now)
                context.insert(entry)
                return entry
            }()
            holder.note = note
        }
        try context.save()
    }

    /// FIT-351: the day's note on its own, from Today's Note: on the check-in row (sleep, else weight), else a weight row
    /// with no weight. Empty clears it, and a row left with nothing in it goes.
    static func setNote(_ note: String, on day: Date, in context: ModelContext, now: Date = .now) throws {
        let rows = try entries(on: day, in: context)
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let holder = rows.first { $0.kind == .sleep && !$0.note.isEmpty } ?? rows.first { $0.kind == .bodyweight && !$0.note.isEmpty }
            ?? rows.first { $0.kind == .sleep } ?? rows.first { $0.kind == .bodyweight }
        if let holder {
            if note.isEmpty && holder.measurements.isEmpty { context.delete(holder) } else { holder.note = note; holder.updatedAt = now }
        } else if !note.isEmpty {
            let at = Calendar.current.isDate(day, inSameDayAs: now) ? now : Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: day)!
            let entry = LogEntry(kind: .bodyweight, timestamp: at, now: now)
            entry.note = note
            context.insert(entry)
        }
        try context.save()
    }

    /// What the day's check-in says, to fill the sheet: its weight, sleep and note.
    static func values(_ entries: [LogEntry]) -> (weight: Double?, sleep: Double?, note: String) {
        let weight = entries.first { $0.kind == .bodyweight }?.measurements.first { $0.metric == "weight_lb" }?.value
        let sleep = entries.first { $0.kind == .sleep }?.measurements.first { $0.metric == "sleep_h" }?.value
        let note = (entries.filter { $0.kind == .sleep } + entries.filter { $0.kind == .bodyweight }).map(\.note).first { !$0.isEmpty } ?? ""
        return (weight, sleep, note)
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
        // FIT-351: a note on its own is Today's Note, not a check-in.
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct CheckInSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    /// FIT-345: the day it's for: today, or a past day on Today.
    var day: Date = .now
    /// The last weight logged, as the field's hint.
    var lastWeight: Double?
    /// Whether the day had a check-in when the sheet opened, so emptying every field can clear it. FIT-351: the day's
    /// note is written from Today's Note, and kept as it was here.
    @State private var existed = false

    @State private var weight = ""
    @State private var sleep = ""
    @State private var note = ""
    @State private var failure: String?
    @FocusState private var focused: Field?

    enum Field { case weight, sleep }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    row("Weight", "lb", text: $weight, hint: lastWeight.map(Coach.number) ?? "180", field: .weight)
                    row("Sleep", "hours", text: $sleep, hint: "7.5", field: .sleep)
                } footer: {
                    Text(failure ?? "Your coach sees this with your training. Leave out anything you like.")
                        .foregroundStyle(failure == nil ? Color.secondary : Color.red)
                }
            }
            .navigationTitle(Calendar.current.isDateInToday(day) ? "Check In" : "Check In · \(TodayScreen.dayName(day))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!existed && number(weight) == nil && number(sleep) == nil)
                }
            }
            .onAppear(perform: fill)
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

    /// FIT-345: an existing check-in opens with what it said, to change or clear.
    private func fill() {
        let rows = (try? CheckIn.entries(on: day, in: context)) ?? []
        let values = CheckIn.values(rows)
        existed = rows.contains { !$0.measurements.isEmpty }
        weight = values.weight.map(Coach.number) ?? ""
        sleep = values.sleep.map(Coach.number) ?? ""
        note = values.note
        if !existed { focused = .weight }
    }

    private func save() {
        let weight = number(weight), sleep = number(sleep)
        if let weight, !(50...700).contains(weight) { failure = "Weight is in pounds, between 50 and 700."; return }
        if let sleep, !(0...24).contains(sleep) { failure = "Sleep is hours, 0 to 24."; return }
        do {
            try CheckIn.replace(weight: weight, sleep: sleep, note: note, on: day, in: context)
            dismiss()
        } catch {
            failure = "Couldn’t save that. Try again."
        }
    }
}

/// FIT-351: a note for the day, any day up to today, about anything ("knee felt off on the stairs", "travelling
/// Thursday"). Your coach sees it with the day, and a note that says something hurts is flagged for them.
struct DayNoteSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @FocusState private var typing: Bool
    var day: Date
    var coached: Bool
    @State private var note = ""
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Anything about today", text: $note, axis: .vertical).lineLimit(4...12).focused($typing)
                } footer: {
                    if let failure { Text(failure).foregroundStyle(.red) } else if coached { Text("Your coach sees this with your training.") }
                }
            }
            .navigationTitle(Calendar.current.isDateInToday(day) ? "Note" : "Note · \(TodayScreen.dayName(day))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
            .onAppear {
                note = CheckIn.values((try? CheckIn.entries(on: day, in: context)) ?? []).note
                typing = true
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        do {
            try CheckIn.setNote(note, on: day, in: context)
            dismiss()
        } catch {
            failure = "Couldn’t save that. Try again."
        }
    }
}
