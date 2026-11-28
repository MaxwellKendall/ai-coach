import SwiftData
import SwiftUI

/// FIT-356: every past workout, newest first, each opening what was lifted that day. Progress's third tab. FIT-358:
/// above them, what the coach sees of you: each main lift's estimated max, sessions done of planned, and check-ins.
struct HistoryScreen: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \LogEntry.timestamp) private var entries: [LogEntry]
    @Query private var templates: [Template]
    @Query private var planned: [PlannedActivity]
    /// Your training as sync units, the coach's view's input; worked out again when the log changes.
    @State private var units: [String: String] = [:]

    private var names: [String: String] { Dictionary(templates.map { ($0.slug, $0.name) }, uniquingKeysWith: { first, _ in first }) }

    var body: some View {
        let sets = Planner.loggedSets(entries, templates: templates)
        let days = Self.days(entries, sets: sets, planned: planned), names = names
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ProgressCharts(units: units, sets: sets, names: names)
                ProgressCharts<EmptyView>.section("Workouts") {
                    if days.isEmpty {
                        Text("Each workout you log shows up here, with every set.").font(.subheadline).foregroundStyle(Color.inkMuted)
                    }
                    ForEach(days) { day in
                        NavigationLink {
                            HistoryDayView(date: day.date, names: names)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(Self.date(day.date)).font(.subheadline).foregroundStyle(.secondary)
                                    Text(TodayScreen.title(lifts: day.lifts.map { names[$0.exercise] ?? $0.exercise })).font(.headline)
                                        .multilineTextAlignment(.leading)
                                    Text("\(day.lifts.reduce(0) { $0 + $1.sets.count }) sets").font(.subheadline).foregroundStyle(.secondary)
                                    // TKL-1087: a day with a note says so, by its first line; a day without one is as before.
                                    if let note = day.note ?? day.coachNote {
                                        Label {
                                            Text(ExerciseHistory.firstLine(note)).lineLimit(1)
                                        } icon: {
                                            Image(systemName: day.note == nil ? "quote.opening" : "text.quote").foregroundStyle(Plate.current.mark)
                                        }
                                        .font(.subheadline).foregroundStyle(Color.inkMuted).padding(.top, 2)
                                        .accessibilityLabel((day.note == nil ? "Coach's note: " : "Your note: ") + ExerciseHistory.firstLine(note))
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        if day.id != days.last?.id { Divider() }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 32)
        }
        .task(id: entries.count) { units = (try? SyncUnits.all(in: context)) ?? [:] }
    }
}

extension HistoryScreen {
    /// TKL-1087: the workout days with their notes: the lifter's (each session summary's note, as Today shows it) and
    /// the coach's note on the day's session.
    @MainActor
    static func days(_ entries: [LogEntry], sets: [LoggedSet], planned: [PlannedActivity]) -> [ExerciseHistory.Day] {
        let calendar = Calendar.current
        let workouts = entries.filter { $0.kind == .workout }
        let setNotes = Dictionary(grouping: workouts.filter { $0.templateRef != nil && !$0.note.isEmpty }) { calendar.startOfDay(for: $0.timestamp) }
            .mapValues { Set($0.map(\.note)) }
        let slots = Dictionary(grouping: planned.filter { $0.kind == .workout }) { calendar.startOfDay(for: $0.date) }
        let notes = workouts.filter { $0.templateRef == nil && !$0.note.isEmpty }.compactMap { summary -> ExerciseHistory.Note? in
            let day = calendar.startOfDay(for: summary.timestamp)
            // Sessions saved before FIT-28 kept the session's name (or a set's note) in the summary's note, as DayCard skips.
            let legacy = setNotes[day, default: []].union((slots[day] ?? []).compactMap(\.slot)).union(["Workout"])
            return legacy.contains(summary.note) ? nil : ExerciseHistory.Note(date: summary.timestamp, text: summary.note)
        }
        let coachNotes = slots.compactMap { day, items in PlannedActivity.sessionNote(items).map { ExerciseHistory.Note(date: day, text: $0) } }
        return ExerciseHistory.days(sets, notes: notes, coachNotes: coachNotes)
    }

    /// TKL-1087: the day's session summary whose note History edits through Today's sheet: the last one with a note,
    /// else the last one.
    static func summary(on day: Date, in entries: [LogEntry]) -> LogEntry? {
        let summaries = entries.filter { $0.kind == .workout && $0.templateRef == nil && Calendar.current.isDate($0.timestamp, inSameDayAs: day) }
        return summaries.last { !$0.note.isEmpty } ?? summaries.last
    }

    /// "Friday, Jul 10", with the year when it isn't this one.
    static func date(_ day: Date) -> String {
        let style = Date.FormatStyle.dateTime.weekday(.wide).month(.abbreviated).day()
        return Calendar.current.isDate(day, equalTo: .now, toGranularity: .year) ? day.formatted(style) : day.formatted(style.year())
    }
}

/// One day's lifts, set by set. TKL-1087: above them, the coach's note on the session and the lifter's own note,
/// editable here through the same sheet as Today.
struct HistoryDayView: View {
    let date: Date
    let names: [String: String]
    @Environment(Pro.self) private var pro
    @Query(sort: \LogEntry.timestamp) private var entries: [LogEntry]
    @Query private var templates: [Template]
    @Query private var planned: [PlannedActivity]
    @State private var editing: LogEntry?
    @State private var expanded = false

    /// A note this long is cut to a few lines, with a way to see the rest, so the sets stay on screen.
    static func isLong(_ note: String) -> Bool { note.count > 180 || note.filter(\.isNewline).count >= 4 }

    var body: some View {
        let day = HistoryScreen.days(entries, sets: Planner.loggedSets(entries, templates: templates), planned: planned)
            .first { $0.date == date } ?? ExerciseHistory.Day(date: date, lifts: [])
        let summary = HistoryScreen.summary(on: date, in: entries)
        List {
            if let coach = day.coachNote {
                Section {
                    SessionNote(text: coach, by: pro.coaches.first?.name ?? "Your coach")
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
            }
            if day.note != nil || summary != nil {
                Section("Your note") { yourNote(day.note, summary: summary) }
            }
            Section(day.note != nil || summary != nil || day.coachNote != nil ? "Sets" : "") {
                ForEach(day.lifts, id: \.exercise) { lift in
                    ExerciseHistory.LiftRow(name: names[lift.exercise] ?? lift.exercise, lift: lift)
                }
            }
        }
        .navigationTitle(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { summary in NavigationStack { WorkoutNoteSheet(summary: summary, note: summary.note) } }
    }

    @ViewBuilder
    private func yourNote(_ note: String?, summary: LogEntry?) -> some View {
        if let note {
            VStack(alignment: .leading, spacing: 8) {
                Text("“\(note)”").font(.body).foregroundStyle(Color.ink).lineLimit(expanded || !Self.isLong(note) ? nil : 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                    .onTapGesture { if let summary { editing = summary } }
                    .accessibilityLabel("Your note: \(note)")
                    .accessibilityHint(summary == nil ? "" : "Edits the note")
                    .accessibilityAddTraits(summary == nil ? [] : .isButton)
                if Self.isLong(note) {
                    Button(expanded ? "Show less" : "Show all") { withAnimation(.snappy) { expanded.toggle() } }
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Plate.current.mark).buttonStyle(.borderless)
                }
            }
        } else if let summary {
            Button { editing = summary } label: {
                Label("Add a note", systemImage: "square.and.pencil").font(.subheadline.weight(.semibold)).foregroundStyle(Plate.current.mark)
            }
        }
    }
}

/// FIT-356: an exercise's last sessions, under its how-to: the date, the sets, the best estimated max.
struct ExerciseHistorySection: View {
    let slug: String
    var limit = 6
    /// TKL-793: the how-to sheet calls it "Last time".
    var title = "Your last sessions"
    @Query(sort: \LogEntry.timestamp) private var entries: [LogEntry]
    @Query private var templates: [Template]

    var body: some View {
        let days = ExerciseHistory.days(Planner.loggedSets(entries.filter { $0.kind == .workout }, templates: templates), exercise: slug).prefix(limit)
        if !days.isEmpty {
            Section(title) {
                ForEach(Array(days)) { day in
                    if let lift = day.lifts.first {
                        ExerciseHistory.LiftRow(name: day.date.formatted(.dateTime.month(.abbreviated).day()), lift: lift)
                    }
                }
            }
        }
    }
}

extension ExerciseHistory {
    /// A name (an exercise, or a date), its sets, and its best estimated max.
    struct LiftRow: View {
        let name: String
        let lift: Lift

        var body: some View {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                    Text(ExerciseHistory.summary(lift.sets)).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                if let best = lift.best {
                    Text("max ~\(Coach.number(best.rounded()))").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}
