import SwiftUI
import SwiftData

/// The program (FIT-39, prototype boards A, B, D): Program | Goals. The weeks as bars and a deck of week cards;
/// this week and next list their sessions, later weeks are a sketch of where each goal should be.
struct ProgramScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var profiles: [Profile]
    @Query(sort: \Goal.createdAt) private var goals: [Goal]
    @Query(sort: \PlannedActivity.date) private var planned: [PlannedActivity]
    @Query(sort: \LogEntry.timestamp) private var entries: [LogEntry]
    @Query private var templates: [Template]
    @State private var tab = Tab.program
    @State private var selected: Int?
    @State private var openGoal: UUID?
    @State private var nextWeek: [PlannedWorkout] = []

    enum Tab: String, CaseIterable { case program = "Program", goals = "Goals" }

    var body: some View {
        NavigationStack {
            Group {
                if let profile = profiles.first, let weeks = profile.program, let start = profile.programStart {
                    let current = max(0, min(weeks.count - 1, ProgramPlan.week(of: .now, start: start)))
                    switch tab {
                    case .program: program(weeks, start: start, current: current, profile: profile)
                    case .goals: goalList(weeks, start: start, current: current, profile: profile)
                    }
                }
            }
            .background(Color(.systemBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Show", selection: $tab.animation(.snappy)) {
                        ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .task { nextWeek = (try? Planner.preview(weekOf: Calendar.current.date(byAdding: .day, value: 7, to: .now)!, in: context)) ?? [] }
    }

    // MARK: Program

    private func program(_ weeks: [ProgramWeek], start: Date, current: Int, profile: Profile) -> some View {
        let index = Binding(get: { selected ?? current }, set: { selected = $0 })
        return VStack(spacing: 0) {
            PhaseBars(weeks: weeks, current: current, selected: index.wrappedValue) { week in
                withAnimation(.snappy) { selected = week }
            }
            .padding(.horizontal, 22)
            .padding(.top, 12)
            SwipeDeck(index: index, count: weeks.count) { week in
                weekCard(week, weeks: weeks, start: start, current: current, profile: profile)
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
    }

    private func weekCard(_ index: Int, weeks: [ProgramWeek], start: Date, current: Int, profile: Profile) -> some View {
        let week = weeks[index]
        let monday = ProgramPlan.monday(index, start: start)
        let sunday = Calendar.current.date(byAdding: .day, value: 6, to: monday)!
        let programGoals = self.programGoals
        let eyebrow = (index == current ? "This week · " : index == current + 1 ? "Next week · " : "") + "Week \(index + 1) of \(weeks.count)"
        let tests = programGoals.map { "\(GoalOption.with(id: $0.option)?.name.lowercased() ?? "") \(Coach.number($0.goal.target))" }
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(eyebrow.uppercased()).font(.footnote.weight(.semibold)).tracking(0.4).foregroundStyle(.secondary)
                Spacer()
                Text("\(monday.formatted(.dateTime.month(.abbreviated).day())) – \(sunday.formatted(.dateTime.month(.abbreviated).day()))")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Text(ProgramPlan.title(week)).font(.system(size: 30, weight: .bold)).tracking(-0.4).padding(.top, 6)
            Text(ProgramPlan.why(week, tests: tests)).font(.subheadline).foregroundStyle(.secondary).padding(.top, 4)
            if index == current || index == current + 1 {
                sessions(index == current ? thisWeek(monday) : nextWeek.map { Planner.SketchDay($0, names: names) }.grouped())
                    .padding(.top, 18)
                Spacer(minLength: 12)
                Text(index == current ? "Done sessions stay as they are." : "Planned from this week. Changes after this week ends.")
                    .font(.footnote).foregroundStyle(.tertiary)
            } else if index < current {
                Spacer()
                Text("Done.").font(.footnote).foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 0) {
                    ForEach(programGoals, id: \.goal.id) { item in
                        let value = ProgramPlan.expected(from: item.goal.baseline ?? item.goal.target, target: item.goal.target, at: index, weeks: weeks)
                        let option = GoalOption.with(id: item.option)
                        let shown = option?.measure == .load ? TrainingGenerator.roundTo5(value) : value.rounded()
                        row(option?.name ?? item.goal.metric, (item.option == "weight" ? "~" : "") + "\(Coach.number(shown)) \(item.goal.unit)")
                    }
                    row("Weekly sets", "\(ProgramPlan.weeklySets(week, daysPerWeek: profile.trainingDays.count, sessionMinutes: profile.sessionMinutes))")
                }
                .padding(.top, 18)
                Spacer(minLength: 12)
                Text("A sketch. Sessions get planned when the week before ends, from how it went.")
                    .font(.footnote).foregroundStyle(.tertiary)
            }
        }
        .padding(EdgeInsets(top: 22, leading: 22, bottom: 18, trailing: 22))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 30))
    }

    private func row(_ name: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(name)
                Spacer()
                Text(value).font(.system(.body, design: .rounded, weight: .semibold)).monospacedDigit()
            }
            .padding(.vertical, 11)
            Divider()
        }
    }

    private func sessions(_ days: [Planner.SketchDay]) -> some View {
        VStack(spacing: 0) {
            ForEach(days) { day in
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(day.date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                        .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(day.session).font(.body.weight(.semibold))
                        Text(day.lifts + (day.more > 0 ? " + \(day.more) more" : "")).font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if done(day.date) {
                        Image(systemName: "checkmark").font(.footnote.weight(.bold)).accessibilityLabel("Done")
                    }
                }
                .padding(.vertical, 10)
                Divider()
            }
            if days.isEmpty { Text("Nothing planned.").font(.subheadline).foregroundStyle(.secondary) }
        }
    }

    private func thisWeek(_ monday: Date) -> [Planner.SketchDay] {
        let end = Calendar.current.date(byAdding: .day, value: 7, to: monday)!
        let slugs = Dictionary(templates.map { ($0.id, $0.slug) }, uniquingKeysWith: { first, _ in first })
        return planned.filter { $0.kind == .workout && $0.date >= monday && $0.date < end }.map {
            Planner.SketchDay(PlannedWorkout(date: $0.date, session: $0.slot ?? "Workout", exercise: $0.templateRef.flatMap { slugs[$0] } ?? "",
                                             targets: $0.targets, note: $0.note.isEmpty ? nil : $0.note), names: names)
        }.grouped()
    }

    private func done(_ date: Date) -> Bool {
        entries.contains { $0.kind == .workout && Calendar.current.isDate($0.timestamp, inSameDayAs: date) }
    }

    private var names: [String: String] { Dictionary(templates.map { ($0.slug, $0.name) }, uniquingKeysWith: { first, _ in first }) }

    // MARK: Goals

    /// The goals the program works towards: those onboarding offers.
    private var programGoals: [(goal: Goal, option: String)] {
        goals.filter { $0.status == .active }.compactMap { goal in
            GoalOption.all.first { $0.metric == goal.metric }.map { (goal, $0.id) }
        }
    }

    private func goalList(_ weeks: [ProgramWeek], start: Date, current: Int, profile: Profile) -> some View {
        let sets = Planner.loggedSets(entries, templates: templates)
        let weighIns = entries.filter { $0.kind == .bodyweight }.compactMap { entry in
            entry.measurements.first { $0.metric == "weight_lb" }.map { DatedValue(date: entry.timestamp, value: $0.value) }
        }
        let end = profile.targetDate.map { $0.formatted(.dateTime.month(.abbreviated).day()) } ?? ""
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(programGoals, id: \.goal.id) { item in
                    goalRow(item.goal, option: GoalOption.with(id: item.option)!, weeks: weeks, current: current, end: end,
                            now: GoalProgress.current(item.goal.metric, sets: sets, weighIns: weighIns, since: start))
                }
                Text("Tap a goal to change its target.").font(.footnote).foregroundStyle(.secondary).padding(.top, 16)
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)
        }
    }

    private func goalRow(_ goal: Goal, option: GoalOption, weeks: [ProgramWeek], current: Int, end: String, now logged: Double?) -> some View {
        let from = goal.baseline ?? logged ?? goal.target
        let now = logged ?? from
        let fraction = GoalProgress.fraction(from: from, now: now, target: goal.target)
        let pace: String = switch GoalProgress.pace(from: from, now: now, target: goal.target, week: current, weeks: weeks) {
        case .starting: "Starting"
        case .onPace: "On pace"
        case .behind: "Behind"
        }
        let moved = abs(now - from)
        let change = moved == 0 ? "" : " · \(Coach.number(moved)) \(goal.unit) \(goal.target < from ? "down" : "up")"
        return VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.snappy) { openGoal = openGoal == goal.id ? nil : goal.id } } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(option.name).font(.subheadline).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(Coach.number(now)) →").foregroundStyle(.secondary)
                        Text(Coach.number(goal.target)).contentTransition(.numericText())
                        Text(goal.unit).font(.title3).foregroundStyle(.secondary)
                    }
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color(.tertiarySystemFill))
                            Capsule().fill(Color.primary).frame(width: max(4, proxy.size.width * fraction))
                        }
                    }
                    .frame(height: 4)
                    HStack {
                        Text(pace + change)
                        Spacer()
                        Text("by \(end)")
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Change the target")
            if openGoal == goal.id {
                Nudge(label: "\(Coach.number(goal.target)) \(goal.unit)", lessLabel: "Lower", moreLabel: "Raise",
                      less: { setTarget(goal, goal.target - option.step) }, more: { setTarget(goal, goal.target + option.step) })
            }
        }
        .padding(.vertical, 16)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func setTarget(_ goal: Goal, _ target: Double) {
        goal.target = max(0, target)
        goal.updatedAt = .now
    }
}

extension Planner {
    /// One day of a week card: the session and its exercises in a line, e.g. "Back Squat 3×5 · 135, Pull-up 3×5".
    struct SketchDay: Identifiable {
        var date: Date
        var session: String
        var lifts: String
        /// Exercises past the first two, which are only counted.
        var more = 0
        var id: Date { date }

        init(_ workout: PlannedWorkout, names: [String: String]) {
            date = Calendar.current.startOfDay(for: workout.date)
            session = workout.session
            lifts = workout.note == TrainingGenerator.warmupNote ? "" : "\(names[workout.exercise] ?? workout.exercise) \(Self.dose(workout))"
        }

        /// "3×5 · 135", "3 × 45 s", "3 × 30 m".
        static func dose(_ workout: PlannedWorkout) -> String {
            let sets = Coach.number(workout.target("sets") ?? 1)
            if let seconds = workout.target("duration_s") { return "\(sets) × \(Coach.number(seconds)) s" }
            if let meters = workout.target("distance_m") { return "\(sets) × \(Coach.number(meters)) m" }
            let reps = "\(sets)×\(Coach.number(workout.target("reps") ?? 0))"
            if let load = workout.target("load_lb") ?? workout.target("load_lb_hand") { return "\(reps) · \(Coach.number(load))" }
            return reps
        }
    }
}

extension [Planner.SketchDay] {
    /// One entry per day, its exercises joined.
    func grouped() -> [Planner.SketchDay] {
        var days: [Planner.SketchDay] = []
        for item in self {
            if let last = days.indices.last, days[last].date == item.date {
                guard !item.lifts.isEmpty else { continue }
                if days[last].lifts.isEmpty || !days[last].lifts.contains(",") {
                    days[last].lifts += (days[last].lifts.isEmpty ? "" : ", ") + item.lifts
                } else {
                    days[last].more += 1
                }
            } else {
                days.append(item)
            }
        }
        return days
    }
}
