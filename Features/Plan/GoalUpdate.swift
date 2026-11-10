import SwiftUI
import SwiftData

/// FIT-343: a goal brought up to date by a test: a single or a rep max, the most reps in a row, a race or a timed run,
/// or a weigh-in. Each is an ordinary log row that the goal's progress already reads (GoalProgress.current), dated the
/// day it's recorded, in that day's `log#` unit; nothing is stored on the goal (principle 6). A lift, reps or a run is
/// a `workout` row on its exercise, marked as a test so it isn't taken for the day's session; a weigh-in is Check in's
/// own row.
enum GoalUpdate {
    enum Result: Equatable {
        case lift(load: Double, reps: Double)
        case reps(Double)
        /// Distance in meters, time in seconds.
        case run(meters: Double, seconds: Double)
        case weight(Double)
    }

    enum Failure: Error { case noExercise }

    /// What marks a row as a test, not a session: DayCard leaves it out of the day's session, and the coach's
    /// notification says it was a test (infra/lambda/push.ts).
    static let marker = Measurement(metric: "test", value: 1, unit: "")

    static func isTest(_ measurements: [Measurement]) -> Bool { measurements.contains { $0.metric == marker.metric } }

    /// Saves the test as a log row for the goal's exercise (a run on Running.outdoor), or as the day's weigh-in.
    @MainActor
    static func save(_ option: GoalOption, _ result: Result, note: String, on day: Date = .now, in context: ModelContext,
                     now: Date = .now) throws {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug: String
        let measurements: [Measurement]
        switch result {
        case .weight(let weight):
            try CheckIn.save(weight: weight, sleep: nil, note: note, on: day, in: context, now: now)
            return
        case .lift(let load, let reps):
            guard let exercise = option.exercise else { throw Failure.noExercise }
            slug = exercise
            measurements = [Measurement(metric: "load_lb", value: load, unit: "lb"), Measurement(metric: "reps", value: reps, unit: "reps"), marker]
        case .reps(let reps):
            guard let exercise = option.exercise else { throw Failure.noExercise }
            slug = exercise
            measurements = [Measurement(metric: "reps", value: reps, unit: "reps"), marker]
        case .run(let meters, let seconds):
            slug = Running.outdoor
            measurements = [Measurement(metric: "distance_m", value: meters.rounded(), unit: "m"),
                            Measurement(metric: "duration_s", value: seconds.rounded(), unit: "s"), marker]
        }
        let wanted = slug
        guard let template = try context.fetch(FetchDescriptor<Template>(predicate: #Predicate { $0.slug == wanted })).first else {
            throw Failure.noExercise
        }
        let at = Calendar.current.isDate(day, inSameDayAs: now) ? now : Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: day)!
        context.insert(LogEntry(kind: .workout, timestamp: at, templateRef: template.id, measurements: measurements, note: note, now: now))
        try context.save()
    }
}

/// FIT-343: Update on a goal card, asking for what fits the goal.
struct GoalUpdateSheet: View {
    let goal: Goal
    let option: GoalOption
    /// After a save, with what to say.
    var saved: (String) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var load: Double?
    @State private var reps: Double?
    @State private var miles: Double?
    @State private var time = ""
    @State private var note = ""
    @State private var failure: String?
    @FocusState private var typing: Bool

    init(goal: Goal, option: GoalOption, saved: @escaping (String) -> Void) {
        self.goal = goal
        self.option = option
        self.saved = saved
        // A race goal's own distance to start from, and a single for a max.
        _miles = State(initialValue: option.meters.map { ($0 / Running.mile * 100).rounded() / 100 })
        _reps = State(initialValue: option.measure == .load ? 1 : nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    switch option.measure {
                    case .load:
                        field("Weight", unit: "lb", value: $load)
                        field("Reps", unit: "", value: $reps)
                    case .reps:
                        field("Most in a row", unit: "reps", value: $reps)
                    case .time:
                        field("Distance", unit: "mi", value: $miles)
                        HStack {
                            Text("Time")
                            Spacer()
                            TextField("24:10", text: $time).keyboardType(.numbersAndPunctuation).focused($typing)
                                .multilineTextAlignment(.trailing).frame(maxWidth: 110)
                        }
                    case .body:
                        field("Weight", unit: "lb", value: $load)
                    }
                    TextField("A note for your coach (optional)", text: $note, axis: .vertical).lineLimit(1...3)
                } header: {
                    Text(option.name)
                } footer: {
                    Text(failure ?? footer).foregroundStyle(failure == nil ? Color.secondary : Color.red)
                }
            }
            .navigationTitle("Update")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(result == nil) }
            }
            .onAppear { typing = true }
        }
        .presentationDetents([.medium])
    }

    private var footer: String {
        switch option.measure {
        case .load: "A single, or the most you lifted for a few reps. Saved for today; your coach sees it."
        case .reps: "Strict, in one set. Saved for today; your coach sees it."
        case .time: "A race or a timed run. Saved for today; your coach sees it."
        case .body: "Today’s weigh-in, the same as Check in. Your coach sees it."
        }
    }

    private func field(_ name: String, unit: String, value: Binding<Double?>) -> some View {
        HStack {
            Text(name)
            Spacer()
            TextField("–", value: value, format: .number).keyboardType(.decimalPad).focused($typing)
                .multilineTextAlignment(.trailing).frame(maxWidth: 90)
            if !unit.isEmpty { Text(unit).foregroundStyle(.secondary) }
        }
    }

    /// What was entered, once it's enough to save.
    private var result: GoalUpdate.Result? {
        switch option.measure {
        case .load:
            guard let load, load > 0, let reps, reps >= 1 else { return nil }
            return .lift(load: load, reps: reps.rounded())
        case .reps:
            guard let reps, reps >= 1 else { return nil }
            return .reps(reps.rounded())
        case .time:
            guard let miles, miles > 0, let seconds = Running.seconds(time), seconds > 0 else { return nil }
            return .run(meters: miles * Running.mile, seconds: seconds)
        case .body:
            guard let load, load > 0 else { return nil }
            return .weight(load)
        }
    }

    private func save() {
        guard let result else { return }
        if case .weight(let weight) = result, !(50...700).contains(weight) { failure = "Weight is in pounds, between 50 and 700."; return }
        if case .lift(_, let reps) = result, reps > 12 { failure = "Up to 12 reps: past that a max can’t be estimated."; return }
        do {
            try GoalUpdate.save(option, result, note: note, in: context)
            saved("Saved. Your coach sees it too.")
            dismiss()
        } catch {
            failure = "Couldn’t save that. Try again."
        }
    }
}
