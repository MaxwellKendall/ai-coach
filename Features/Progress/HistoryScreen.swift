import SwiftData
import SwiftUI

/// FIT-356: every past workout, newest first, each opening what was lifted that day. Progress's third tab.
struct HistoryScreen: View {
    @Query(sort: \LogEntry.timestamp) private var entries: [LogEntry]
    @Query private var templates: [Template]

    private var days: [ExerciseHistory.Day] { ExerciseHistory.days(Planner.loggedSets(entries, templates: templates)) }
    private var names: [String: String] { Dictionary(templates.map { ($0.slug, $0.name) }, uniquingKeysWith: { first, _ in first }) }

    var body: some View {
        let days = days, names = names
        if days.isEmpty {
            ContentUnavailableView("No workouts yet", systemImage: "clock.arrow.circlepath",
                                   description: Text("Each workout you log shows up here, with every set."))
        } else {
            List(days) { day in
                NavigationLink {
                    HistoryDayView(day: day, names: names)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Self.date(day.date)).font(.subheadline).foregroundStyle(.secondary)
                        Text(TodayScreen.title(lifts: day.lifts.map { names[$0.exercise] ?? $0.exercise })).font(.headline)
                        Text("\(day.lifts.reduce(0) { $0 + $1.sets.count }) sets").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .scrollContentBackground(.hidden)
        }
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
