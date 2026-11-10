import SwiftUI
import SwiftData
import UserNotifications

extension WeeklyCheckIn {
    /// The week's check-in rows, Sunday to Saturday.
    @MainActor static func entries(weekOf date: Date, in context: ModelContext) throws -> [LogEntry] {
        let start = Week.start(of: date), end = Calendar.current.date(byAdding: .day, value: 7, to: start)!
        return try context.fetch(FetchDescriptor<LogEntry>(predicate: #Predicate { $0.timestamp >= start && $0.timestamp < end }))
            .filter { $0.kind == .checkin }
            .sorted { $0.timestamp < $1.timestamp }
    }

    /// One a week: the week's check-in is changed, or made on `day` (now, when that's today). Ratings are 1–5.
    @MainActor static func save(_ values: [String: Double], wentWell: String, wasHard: String, on day: Date, in context: ModelContext,
                                now: Date = .now) throws {
        let rows = try entries(weekOf: day, in: context)
        let at = Calendar.current.isDate(day, inSameDayAs: now) ? now : Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: day)!
        rows.dropFirst().forEach(context.delete)
        let entry = rows.first ?? {
            let entry = LogEntry(kind: .checkin, timestamp: at, now: now)
            context.insert(entry)
            return entry
        }()
        entry.measurements = ratings.compactMap { rating in
            values[rating.metric].map { Measurement(metric: rating.metric, value: min(5, max(1, $0.rounded())), unit: "/5") }
        }
        entry.note = note(wentWell: wentWell, wasHard: wasHard)
        entry.updatedAt = now
        try context.save()
    }

    static let reminderID = "weekly-checkin"

    /// The weekly reminder on the check-in day, while they have a coach. Never asks for permission itself (FIT-59): it's
    /// set once notifications are allowed, as joining a coach asks.
    @MainActor static func remind(_ day: Int?, coached: Bool) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [reminderID])
        guard coached, await center.notificationSettings().authorizationStatus == .authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "Time for your weekly check-in"
        content.body = "A minute on how the week went, for your coach."
        let trigger = UNCalendarNotificationTrigger(dateMatching: reminder(day ?? defaultDay), repeats: true)
        try? await center.add(UNNotificationRequest(identifier: reminderID, content: content, trigger: trigger))
    }
}

/// FIT-344: the weekly check-in: four ratings and two optional answers. This week's weight and sessions are shown,
/// worked out from the logs, not asked.
struct WeeklyCheckInSheet: View {
    /// The day it's saved on: today.
    var day: Date = .now

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \LogEntry.timestamp) private var entries: [LogEntry]
    @Query private var planned: [PlannedActivity]
    @State private var values: [String: Double] = [:]
    @State private var wentWell = ""
    @State private var wasHard = ""
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("This week") {
                    Text(thisWeek).foregroundStyle(.secondary)
                }
                Section {
                    ForEach(WeeklyCheckIn.ratings) { rating in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(rating.name)
                            Picker(rating.name, selection: score(rating.metric)) {
                                ForEach(1...5, id: \.self) { Text("\($0)").tag(Optional($0)) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            HStack {
                                Text(rating.low)
                                Spacer()
                                Text(rating.high)
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                Section {
                    TextField("What went well?", text: $wentWell, axis: .vertical).lineLimit(1...4)
                    TextField("What was hard?", text: $wasHard, axis: .vertical).lineLimit(1...4)
                } footer: {
                    Text(failure ?? "Your coach sees this with your training.")
                        .foregroundStyle(failure == nil ? Color.secondary : Color.red)
                }
            }
            .navigationTitle("Weekly Check-in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(WeeklyCheckIn.ratings.contains { values[$0.metric] == nil })
                }
            }
            .onAppear(perform: fill)
        }
        .presentationDetents([.large])
    }

    private func score(_ metric: String) -> Binding<Int?> {
        Binding(get: { values[metric].map { Int($0) } }, set: { values[metric] = $0.map(Double.init) })
    }

    /// "178.2 lb · 4 of 5 sessions": the week's last weigh-in, and days trained of days planned. A goal's test isn't a
    /// session (FIT-343).
    private var thisWeek: String {
        let calendar = Calendar.current
        let start = Week.start(of: day), end = calendar.date(byAdding: .day, value: 7, to: start)!
        let inWeek = { (date: Date) in date >= start && date < end }
        let weight = entries.last { $0.kind == .bodyweight && inWeek($0.timestamp) }?.measurements.first { $0.metric == "weight_lb" }?.value
        let done = Set(entries.filter { $0.kind == .workout && !GoalUpdate.isTest($0.measurements) && inWeek($0.timestamp) }
            .map { calendar.startOfDay(for: $0.timestamp) })
        let plannedDays = Set(planned.filter { $0.kind == .workout && inWeek($0.date) }.map { calendar.startOfDay(for: $0.date) })
        let total = plannedDays.union(done).count
        let sessions = total == 0 ? "No sessions planned" : "\(done.count) of \(total) session\(total == 1 ? "" : "s") done"
        return [weight.map { "\(Coach.number($0)) lb" } ?? "No weigh-in yet", sessions].joined(separator: " · ")
    }

    /// The week's check-in, opened again to change.
    private func fill() {
        guard let entry = try? WeeklyCheckIn.entries(weekOf: day, in: context).first else { return }
        values = Dictionary(entry.measurements.map { ($0.metric, $0.value) }, uniquingKeysWith: { a, _ in a })
        let answers = WeeklyCheckIn.answers(entry.note)
        wentWell = answers.wentWell
        wasHard = answers.wasHard
    }

    private func save() {
        do {
            try WeeklyCheckIn.save(values, wentWell: wentWell, wasHard: wasHard, on: day, in: context)
            dismiss()
        } catch {
            failure = "Couldn’t save that. Try again."
        }
    }
}
