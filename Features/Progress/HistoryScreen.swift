import SwiftData
import SwiftUI

/// FIT-356: every past workout, newest first, each opening what was lifted that day. Progress's third tab. FIT-358:
/// above them, what the coach sees of you: each main lift's estimated max, sessions done of planned, and check-ins.
struct HistoryScreen: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \LogEntry.timestamp) private var entries: [LogEntry]
    @Query private var templates: [Template]
    /// Your training as sync units, the coach's view's input; worked out again when the log changes.
    @State private var units: [String: String] = [:]

    private var names: [String: String] { Dictionary(templates.map { ($0.slug, $0.name) }, uniquingKeysWith: { first, _ in first }) }

    var body: some View {
        let sets = Planner.loggedSets(entries, templates: templates)
        let days = ExerciseHistory.days(sets), names = names
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ProgressCharts(units: units, sets: sets, names: names)
                ProgressCharts<EmptyView>.section("Workouts") {
                    if days.isEmpty {
                        Text("Each workout you log shows up here, with every set.").font(.subheadline).foregroundStyle(Color.inkMuted)
                    }
                    ForEach(days) { day in
                        NavigationLink {
                            HistoryDayView(day: day, names: names)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(Self.date(day.date)).font(.subheadline).foregroundStyle(.secondary)
                                    Text(TodayScreen.title(lifts: day.lifts.map { names[$0.exercise] ?? $0.exercise })).font(.headline)
                                        .multilineTextAlignment(.leading)
                                    Text("\(day.lifts.reduce(0) { $0 + $1.sets.count }) sets").font(.subheadline).foregroundStyle(.secondary)
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
    /// "Friday, Jul 10", with the year when it isn't this one.
    static func date(_ day: Date) -> String {
        let style = Date.FormatStyle.dateTime.weekday(.wide).month(.abbreviated).day()
        return Calendar.current.isDate(day, equalTo: .now, toGranularity: .year) ? day.formatted(style) : day.formatted(style.year())
    }
}

/// One day's lifts, set by set.
struct HistoryDayView: View {
    let day: ExerciseHistory.Day
    let names: [String: String]

    var body: some View {
        List(day.lifts, id: \.exercise) { lift in
            ExerciseHistory.LiftRow(name: names[lift.exercise] ?? lift.exercise, lift: lift)
        }
        .navigationTitle(day.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// FIT-356: an exercise's last sessions, under its how-to: the date, the sets, the best estimated max.
struct ExerciseHistorySection: View {
    let slug: String
    var limit = 6
    @Query(sort: \LogEntry.timestamp) private var entries: [LogEntry]
    @Query private var templates: [Template]

    var body: some View {
        let days = ExerciseHistory.days(Planner.loggedSets(entries.filter { $0.kind == .workout }, templates: templates), exercise: slug).prefix(limit)
        if !days.isEmpty {
            Section("Your last sessions") {
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
