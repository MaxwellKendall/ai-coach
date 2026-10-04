import SwiftUI
import SwiftData

/// The program (FIT-39, FIT-44): Program | Goals. The weeks as bars and a deck of week cards; this week and next
/// list their sessions, later weeks are a sketch of where each goal should be. The list button peeks at the whole
/// program, where it can be changed.
struct ProgramScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var profiles: [Profile]
    @Query(sort: \Goal.createdAt) private var goals: [Goal]
    @Query(sort: \PlannedActivity.date) private var planned: [PlannedActivity]
    @Query(sort: \LogEntry.timestamp) private var entries: [LogEntry]
    @Query private var templates: [Template]
    @State private var tab: Tab
    @State private var selected: Int?
    @State private var goalIndex = 0
    @State private var nextWeek: [PlannedWorkout] = []
    @State private var regenerating: Regenerate?
    @State private var toast: Toast?
    @State private var voice = VoiceCapture()
    @State private var working: String?
    @State private var message: String?
    @State private var amend: AmendSheet.Amend?
    @State private var peeking = false
    /// The program as it was when the whole-program sheet opened.
    @State private var before: ProgramSettings?
    /// The day whose session is open (FIT-45).
    @State private var opened: Date?

    struct Regenerate: Identifiable {
        let id = UUID()
        var week: Int
        var days: [RegenerateSheet.Day]
    }

    enum Tab: String, CaseIterable { case program = "Program", goals = "Goals" }

    init(tab: Tab = .program) { _tab = State(initialValue: tab) }

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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                VStack(spacing: 14) {
                    ToastView(toast: $toast)
                    if LanguageModel.isAvailable {
                        MicButton(voice: voice, onHeard: heard)
                        Text(voice.listening ? " " : "Say what changed").font(.footnote).foregroundStyle(.tertiary)
                    }
                }
                .padding(.bottom, LanguageModel.isAvailable ? 4 : 14)
            }
            .overlay {
                if voice.listening || working != nil {
                    ListeningVeil(voice: voice, working: working, prompt: "“I’m traveling November 9 to 20, hotel gym with dumbbells”")
                }
            }
            .animation(.snappy, value: toast)
            .animation(.snappy, value: voice.listening || working != nil)
            .navigationDestination(item: $opened, destination: session)
            .alert("Couldn’t do that", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") {}
            } message: { Text(message ?? "") }
            .onChange(of: voice.problem) { _, problem in if let problem { message = problem } }
            .sheet(item: $amend) { amend in AmendSheet(amend: amend) { applyTravel(amend.travel) } }
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
                if tab == .program, let profile = profiles.first {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Whole program", systemImage: "list.bullet") {
                            before = ProgramSettings(profile)
                            peeking = true
                        }
                    }
                }
            }
        }
        .sheet(item: $regenerating) { request in
            if let profile = profiles.first {
                RegenerateSheet(week: request.week, days: request.days, catalog: Planner.catalog(templates),
                                settings: profile.trainingSettings, history: Planner.loggedSets(entries, templates: templates),
                                names: names) { changes in apply(changes, week: request.week) }
            }
        }
        .sheet(isPresented: $peeking, onDismiss: replanned) {
            if let profile = profiles.first, let weeks = profile.program, let start = profile.programStart {
                let current = max(0, min(weeks.count - 1, ProgramPlan.week(of: .now, start: start)))
                WholeProgramSheet(profile: profile, goals: goals, catalog: Planner.catalog(templates), names: names, current: current,
                                  selected: min(selected ?? current, weeks.count - 1),
                                  line: { line($0, weeks: weeks, start: start, current: current, profile: profile) }) { week in
                    selected = week
                    peeking = false
                }
            }
        }
        .task(refreshNextWeek)
    }

    private func refreshNextWeek() {
        nextWeek = (try? Planner.preview(weekOf: Calendar.current.date(byAdding: .day, value: 7, to: .now)!, in: context)) ?? []
    }

    // MARK: Program

    private func program(_ weeks: [ProgramWeek], start: Date, current: Int, profile: Profile) -> some View {
        let index = Binding(get: { min(selected ?? current, weeks.count - 1) }, set: { selected = $0 })
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
            .padding(.bottom, LanguageModel.isAvailable ? 130 : 72)
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
                let saved = index == current || !dayItems(in: monday).isEmpty
                sessions(saved ? thisWeek(monday) : nextWeek.map { Planner.SketchDay($0, names: names) }.grouped(),
                         pinnable: saved, monday: monday)
                    .padding(.top, 18)
                Spacer(minLength: 12)
                if index == current {
                    let days = regenerateDays(monday)
                    HStack(alignment: .center) {
                        Text("Pinned sessions stay when you regenerate.").font(.footnote).foregroundStyle(.tertiary)
                        Spacer(minLength: 8)
                        if days.contains(where: { $0.kept == nil }) {
                            Button("Regenerate", systemImage: "arrow.triangle.2.circlepath") {
                                regenerating = Regenerate(week: index + 1, days: days)
                            }
                            .font(.subheadline.weight(.semibold))
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                        }
                    }
                } else {
                    Text(saved ? "Pinned sessions stay. The rest is planned again when this week ends."
                         : "Planned from this week. Changes after this week ends.").font(.footnote).foregroundStyle(.tertiary)
                }
            } else if index < current {
                Spacer()
                Text("Done.").font(.footnote).foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 0) {
                    ForEach(sketch(index, weeks: weeks), id: \.name) { goal in row(goal.name, goal.value + " " + goal.unit) }
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
        .clipShape(.rect(cornerRadius: 30))
    }

    /// Where each goal should be by a later week: "~190", "185".
    private func sketch(_ index: Int, weeks: [ProgramWeek]) -> [(name: String, value: String, unit: String)] {
        programGoals.map { item in
            let value = ProgramPlan.expected(from: item.goal.baseline ?? item.goal.target, target: item.goal.target, at: index, weeks: weeks)
            let option = GoalOption.with(id: item.option)
            let shown = option?.measure == .load ? TrainingGenerator.roundTo5(value) : value.rounded()
            return (option?.name ?? item.goal.metric, (item.option == "weight" ? "~" : "") + Coach.number(shown), item.goal.unit)
        }
    }

    /// A week in the whole-program list: "Oct 5 – Oct 11 · Session A · Session B", or where the goals should be.
    private func line(_ index: Int, weeks: [ProgramWeek], start: Date, current: Int, profile: Profile) -> String {
        let monday = ProgramPlan.monday(index, start: start)
        let dates = "\(monday.formatted(.dateTime.month(.abbreviated).day())) – \(Calendar.current.date(byAdding: .day, value: 6, to: monday)!.formatted(.dateTime.month(.abbreviated).day()))"
        func unique(_ days: [Planner.SketchDay]) -> String {
            days.map(\.session).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: " · ")
        }
        let rest: String = if index < current { "Done" }
            else if index == current { unique(thisWeek(monday)) }
            else if index == current + 1 {
                unique(dayItems(in: monday).isEmpty ? nextWeek.map { Planner.SketchDay($0, names: names) }.grouped() : thisWeek(monday))
            }
            else {
                (sketch(index, weeks: weeks).map { "\($0.name.split(separator: " ").first ?? "") \($0.value)" }
                 + ["\(ProgramPlan.weeklySets(weeks[index], daysPerWeek: profile.trainingDays.count, sessionMinutes: profile.sessionMinutes)) sets"])
                    .joined(separator: " · ")
            }
        return rest.isEmpty ? dates : dates + " · " + rest
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

    /// Each day opens its session to edit (FIT-45); a done day opens what was logged.
    private func sessions(_ days: [Planner.SketchDay], pinnable: Bool, monday: Date) -> some View {
        VStack(spacing: 0) {
            ForEach(days) { day in
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Button { open(day.date, monday: monday) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Text(day.date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                                .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                                .lineLimit(1).fixedSize()
                                .frame(minWidth: 36, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(day.session).font(.body.weight(.semibold))
                                Text(day.lifts + (day.more > 0 ? " + \(day.more) more" : "")).font(.footnote).foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(done(day.date) ? "Shows what you logged" : "Opens the session to change it")
                    if done(day.date) {
                        Image(systemName: "checkmark").font(.footnote.weight(.bold)).accessibilityLabel("Done")
                    } else if pinnable, day.date >= Calendar.current.startOfDay(for: .now) {
                        let items = dayItems(day.date)
                        let pinned = !items.isEmpty && items.allSatisfy(\.pinned)
                        Button {
                            withAnimation(.snappy) { for item in items { item.pinned = !pinned; item.updatedAt = .now } }
                        } label: {
                            Image(systemName: pinned ? "pin.fill" : "pin")
                                .font(.subheadline)
                                .foregroundStyle(pinned ? Color.primary : Color(.tertiaryLabel))
                                .frame(width: 44, height: 44)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(pinned ? "Unpin \(day.session). Regenerating can change it." : "Pin \(day.session) so regenerating keeps it")
                        .accessibilityAddTraits(pinned ? .isSelected : [])
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

    private func dayItems(_ date: Date) -> [PlannedActivity] {
        planned.filter { $0.kind == .workout && Calendar.current.isDate($0.date, inSameDayAs: date) }
    }

    private func dayItems(in monday: Date) -> [PlannedActivity] {
        let end = Calendar.current.date(byAdding: .day, value: 7, to: monday)!
        return planned.filter { $0.kind == .workout && $0.date >= monday && $0.date < end }
    }

    /// Next week is only a preview until one of its sessions is opened: then it's saved, to be planned again
    /// when it starts, keeping what's pinned (Planner.ensureWeek).
    private func open(_ date: Date, monday: Date) {
        if dayItems(in: monday).isEmpty { try? Planner.generate(weekOf: monday, in: context) }
        opened = Calendar.current.startOfDay(for: date)
    }

    @ViewBuilder private func session(_ date: Date) -> some View {
        let items = dayItems(date).sorted { $0.date < $1.date }
        if done(date) {
            SessionRecordView(planned: items)
        } else if !items.isEmpty {
            // An edited session is pinned, so regenerating the week keeps it.
            WorkoutDetailView(items: items, session: Planner.session(items, templates: templates), pushed: true) { _ in } onSave: { saved in
                for item in saved { item.pinned = true }
                try? context.save()
            }
        }
    }

    private func workout(_ item: PlannedActivity) -> PlannedWorkout {
        let slugs = Dictionary(templates.map { ($0.id, $0.slug) }, uniquingKeysWith: { first, _ in first })
        return PlannedWorkout(date: Date(timeIntervalSinceReferenceDate: (item.date.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60),
                              session: item.slot ?? "Workout", exercise: item.templateRef.flatMap { slugs[$0] } ?? "",
                              targets: item.targets, note: item.note.isEmpty ? nil : item.note, adjustedReason: item.adjustedReason,
                              group: item.group)
    }

    /// This week's sessions for the regenerate sheet: done, past and pinned ones are kept.
    private func regenerateDays(_ monday: Date) -> [RegenerateSheet.Day] {
        let end = Calendar.current.date(byAdding: .day, value: 7, to: monday)!
        let today = Calendar.current.startOfDay(for: .now)
        let items = planned.filter { $0.kind == .workout && $0.date >= monday && $0.date < end }
        let days = Dictionary(grouping: items) { Calendar.current.startOfDay(for: $0.date) }
        return days.keys.sorted().map { date in
            let rows = days[date]!.sorted { $0.date < $1.date }
            let kept: String? = done(date) ? "Done · kept" : date < today ? "Past · kept" : rows.allSatisfy(\.pinned) ? "Pinned · kept" : nil
            return RegenerateSheet.Day(date: date, session: rows.first?.slot ?? "Workout", items: rows, workouts: rows.map(workout), kept: kept)
        }
    }

    /// Writes the chosen sessions over their days, with an Undo that puts the old ones back.
    private func apply(_ changes: [(items: [PlannedActivity], workouts: [PlannedWorkout])], week: Int) {
        var undo: [(items: [PlannedActivity], workouts: [PlannedWorkout])] = []
        for change in changes {
            let old = change.items.sorted { $0.date < $1.date }.map(workout)
            undo.append((replace(change.items, with: change.workouts), old))
        }
        guard !undo.isEmpty else { return }
        toast = Toast(text: "Week \(week) updated") { for change in undo { _ = replace(change.items, with: change.workouts) } }
    }

    private func replace(_ items: [PlannedActivity], with workouts: [PlannedWorkout]) -> [PlannedActivity] {
        (try? Planner.replace(items, with: workouts, templates: templates, in: context)) ?? []
    }

    private func done(_ date: Date) -> Bool {
        entries.contains { $0.kind == .workout && Calendar.current.isDate($0.timestamp, inSameDayAs: date) }
    }

    private var names: [String: String] { Dictionary(templates.map { ($0.slug, $0.name) }, uniquingKeysWith: { first, _ in first }) }

    // MARK: Changing the program (FIT-41, FIT-44)

    /// The whole-program sheet closed: if anything changed, the rest of this week is planned again, with an Undo
    /// that puts the settings and the sessions back.
    private func replanned() {
        guard let profile = profiles.first, let before, before != ProgramSettings(profile) else { return }
        try? context.save()
        let removed = replanWeek(nil)
        refreshNextWeek()
        toast = Toast(text: "Program re-planned") {
            before.restore(to: profile, goals: goals)
            try? context.save()
            replanWeek(removed)
            refreshNextWeek()
        }
    }

    /// This week from today on, planned again (or put back to `workouts`). Done, past and pinned days stay.
    @discardableResult
    private func replanWeek(_ workouts: [PlannedWorkout]?) -> [PlannedWorkout] {
        guard let plan = try? Planner.plan(weekOf: .now, in: context) else { return [] }
        let keep = Set(regenerateDays(Week.monday(of: .now)).filter { $0.kept != nil }.map(\.date))
        let workouts = workouts ?? (try? Planner.preview(weekOf: .now, in: context)) ?? []
        return (try? Planner.replan(plan, with: workouts, keep: keep, templates: templates, in: context)) ?? []
    }

    /// A trip, read by code from the words: travel weeks are dumbbells and bodyweight, and the deload moves into them.
    private func heard(_ said: String) {
        guard let profile = profiles.first, let weeks = profile.program, let start = profile.programStart,
              let target = profile.targetDate else { return }
        let words = said.lowercased()
        let isTrip = ["travel", "trip", "away", "hotel", "vacation", "holiday", "visiting", "out of town"].contains { words.contains($0) }
        guard isTrip, let trip = SpokenDates.range(in: said, after: .now) else {
            message = "For now the program can change for a trip. Try “I’m traveling November 9 to 20”."
            return
        }
        let added = ProgramPlan.travelWeeks(from: trip.start, to: trip.end, start: start, count: weeks.count,
                                            trainingDays: profile.trainingDays)
        guard !added.isEmpty else {
            message = "That trip doesn’t miss a training day in the program."
            return
        }
        let travel = Set(profile.travelWeeks).union(added).sorted()
        let after = ProgramPlan.weeks(count: weeks.count, deloadEvery: profile.deloadEveryWeeks ?? AgeTier.of(age: profile.age).deloadEveryWeeks,
                                      travel: Set(travel))
        func deloads(_ weeks: [ProgramWeek]) -> [Int] { weeks.indices.filter { weeks[$0].kind == .deload } }
        let numbers = added.sorted().map { $0 + 1 }
        func day(_ date: Date) -> String { date.formatted(.dateTime.month(.abbreviated).day()) }
        var rows = [AmendSheet.Row(head: (numbers.count == 1 ? "Week \(numbers[0])" : "Weeks \(numbers.first!)–\(numbers.last!)") + " · travel",
                                   tag: "\(day(trip.start)) – \(day(trip.end))", line: "Dumbbells and bodyweight only.")]
        let moved = deloads(after).filter { !deloads(weeks).contains($0) }
        let was = deloads(weeks).filter { !deloads(after).contains($0) }
        if let to = moved.first {
            rows.append(AmendSheet.Row(head: "Deload moves to week \(to + 1)", tag: was.first.map { "was week \($0 + 1)" } ?? "",
                                       line: "A lighter week while away, so you come back fresh."))
        }
        rows.append(AmendSheet.Row(head: "Target date \(day(target))", tag: "stays",
                                   line: "Goals hold while away, then pick up where they left off."))
        amend = AmendSheet.Amend(said: said, travel: travel, rows: rows)
    }

    private func applyTravel(_ travel: [Int]) {
        guard let profile = profiles.first else { return }
        let before = profile.travelWeeks
        profile.travelWeeks = travel
        profile.updatedAt = .now
        try? context.save()
        if let first = travel.first(where: { !before.contains($0) }) { withAnimation(.snappy) { selected = first } }
        toast = Toast(text: "Program changed") {
            profile.travelWeeks = before
            profile.updatedAt = .now
            try? context.save()
        }
    }

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
        let end = profile.targetDate ?? ProgramPlan.monday(weeks.count, start: start)
        let paces = programGoals.map { item in
            let from = item.goal.baseline ?? item.goal.target
            let now = GoalProgress.current(item.goal.metric, sets: sets, weighIns: weighIns, since: start) ?? from
            return GoalProgress.pace(from: from, now: now, target: item.goal.target, week: current, weeks: weeks)
        }
        let items = programGoals
        let index = Binding(get: { min(goalIndex, max(0, items.count - 1)) }, set: { goalIndex = $0 })
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Week \(current + 1) of \(weeks.count) · ends \(end.formatted(.dateTime.month(.abbreviated).day()))".uppercased())
                    .font(.footnote.weight(.semibold)).tracking(0.4).foregroundStyle(.secondary)
                if let summary = Self.summary(paces) { Text(summary).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 30)
            .padding(.top, 8)
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(items.indices, id: \.self) { position in
                            let on = position == index.wrappedValue
                            let option = GoalOption.with(id: items[position].option)!
                            Button { withAnimation(.snappy) { index.wrappedValue = position } } label: {
                                Text(WeekReport.short(option)).font(.subheadline.weight(.semibold))
                                    .foregroundStyle(on ? Color(.systemBackground) : .secondary)
                                    .padding(.horizontal, 14).frame(minHeight: 34)
                                    .background(on ? Color.primary : Color(.secondarySystemBackground), in: .capsule)
                                    .contentShape(.capsule)
                            }
                            .buttonStyle(.plain)
                            .id(position)
                            .accessibilityLabel(option.name)
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                    .padding(.horizontal, 22)
                }
                .scrollIndicators(.hidden)
                .onChange(of: index.wrappedValue) { _, position in withAnimation(.snappy) { reader.scrollTo(position, anchor: .center) } }
            }
            .padding(.top, 10)
            SwipeDeck(index: index, count: items.count) { position in
                let item = items[position]
                let option = GoalOption.with(id: item.option)!
                GoalCard(goal: item.goal, option: option, weeks: weeks, start: start, end: end, current: current,
                         sets: sets, weighIns: weighIns, next: option.exercise.flatMap(nextWorkout),
                         setTarget: { setTarget(item.goal, $0) })
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)
            .padding(.bottom, LanguageModel.isAvailable ? 130 : 72)
        }
    }

    /// "1 ahead, 2 on pace, 1 behind".
    static func summary(_ paces: [GoalProgress.Pace]) -> String? {
        let parts = [(GoalProgress.Pace.ahead, "ahead"), (.onPace, "on pace"), (.behind, "behind")].compactMap { pace, word in
            let count = paces.filter { $0 == pace }.count
            return count > 0 ? "\(count) \(word)" : nil
        }
        guard !parts.isEmpty else { return nil }
        let text = parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// The day of the next planned workout with this exercise, today included.
    private func nextWorkout(_ exercise: String) -> Date? {
        let today = Calendar.current.startOfDay(for: .now)
        let ids = Set(templates.filter { $0.slug == exercise }.map(\.id))
        return planned.first { $0.kind == .workout && $0.date >= today && $0.templateRef.map(ids.contains) == true }?.date
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
