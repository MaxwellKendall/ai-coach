import SwiftUI
import SwiftData

/// The app (FIT-27, prototype board 1): this week's days as cards swiped sideways, the M–S strip above them,
/// and one mic. Planned days start a workout, done days show what happened, and the rest stays one tap away.
struct TodayScreen: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \LogEntry.timestamp) private var entries: [LogEntry]
    @Query private var plans: [Plan]
    @Query private var profiles: [Profile]
    @Query(sort: \PlannedActivity.date) private var planned: [PlannedActivity]
    @Query private var templates: [Template]
    @State private var day: Int?
    @State private var voice = VoiceCapture()
    /// What was said, while it's worked on (FIT-50: the progress pill shows it and `step`).
    @State private var working: String?
    @State private var step = ""
    @State private var job: Task<Void, Never>?
    /// Exercises a spoken edit just brought in, highlighted for a moment.
    @State private var fresh: Set<String> = []
    @State private var message: String?
    @State private var toast: Toast?
    @State private var sheet: Sheet?
    @State private var live: WorkoutDraft?
    @State private var you = false
    @State private var showProgram = false

    enum Sheet: Identifiable {
        case details([PlannedActivity]), record([PlannedActivity]), log([PlannedActivity]), adjust(Plan), check([LogDraftEntry])
        case propose(Proposal), spoken(Spoken)
        var id: String {
            switch self {
            case .details(let items): "details \(items.map(\.id))"
            case .record(let items): "record \(items.map(\.id))"
            case .log(let items): "log \(items.map(\.id))"
            case .adjust(let plan): "adjust \(plan.id)"
            case .check: "check"
            case .propose(let proposal): "propose \(proposal.id)"
            case .spoken(let spoken): "spoken \(spoken.id)"
            }
        }
    }

    /// A session said out loud, waiting on the check sheet (FIT-30).
    struct Spoken: Identifiable {
        let id = UUID()
        var said: String
        var title: String
        var draft: WorkoutDraft
        var changed: [Int]
    }

    private var week: [Date] {
        (0..<7).map { Calendar.current.date(byAdding: .day, value: $0, to: Week.monday(of: .now))! }
    }

    private var todayIndex: Int { week.firstIndex { Calendar.current.isDateInToday($0) } ?? 0 }

    private var thisWeeksPlan: Plan? { plans.first { $0.weekStart == week[0] } }

    var body: some View {
        let week = week
        let cards = cards(week)
        let selected = day ?? todayIndex
        VStack(alignment: .leading, spacing: 0) {
            header(week[selected], index: selected)
            strip(week, cards: cards, selected: selected)
                .padding(.horizontal, 14).padding(.top, 18)
            SwipeDeck(index: Binding(get: { day ?? todayIndex }, set: { day = $0 }), count: week.count) { index in
                card(cards[index], isToday: index == todayIndex, isPast: index < todayIndex)
            }
            .padding(.horizontal, 22)
            .padding(.top, 22)
            .padding(.bottom, LanguageModel.isAvailable ? 126 : 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(.systemBackground))
        .overlay {
            if working != nil { EdgeGlow().transition(.opacity) }
        }
        .overlay {
            // FIT-50: the veil goes as soon as you stop talking; the pill below shows the work.
            if voice.listening {
                ListeningVeil(voice: voice, working: nil, prompt: "Change today, or say what you did")
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 14) {
                ToastView(toast: $toast)
                if let said = working {
                    WorkingPill(said: said, step: step) { job?.cancel() }
                        .padding(.bottom, 26)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                } else if LanguageModel.isAvailable {
                    MicButton(voice: voice, onHeard: heard)
                    Text(voice.listening ? " " : "Hold to talk").font(.footnote).foregroundStyle(.tertiary)
                }
            }
            .padding(.bottom, 4)
        }
        .animation(.snappy, value: voice.listening)
        .animation(.snappy, value: working)
        .animation(.snappy, value: toast)
        .onAppear { if day == nil { day = todayIndex } }
        #if DEBUG
        // `-say "swap deadlifts for RDLs"` runs a spoken request without the mic, for the simulator.
        .task {
            if let said = UserDefaults.standard.string(forKey: "say") {
                try? await Task.sleep(for: .seconds(2))
                heard(said)
            }
        }
        #endif
        .alert("Couldn’t do that", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: { Text(message ?? "") }
        .onChange(of: voice.problem) { _, problem in if let problem { message = problem } }
        .sheet(item: $sheet, content: sheetView)
        .sheet(isPresented: $you) { YouScreen() }
        .sheet(isPresented: $showProgram) { ProgramScreen() }
        .fullScreenCover(item: $live) { draft in
            WorkoutModeView(draft: draft) {
                day = todayIndex
                toast = Toast(text: "Workout saved")
            }
        }
        // A new week, or a profile that just finished onboarding, gets a plan.
        .task(id: profiles.first?.isComplete) { try? Planner.ensureWeek(in: context) }
    }

    // MARK: Header and strip

    private func header(_ date: Date, index: Int) -> some View {
        let deload = thisWeeksPlan?.warnings.contains { $0.hasPrefix("Deload") } == true
        let title = switch index - todayIndex {
        case 0: "Today"
        case -1: "Yesterday"
        case 1: "Tomorrow"
        default: date.formatted(.dateTime.weekday(.wide))
        }
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text((date.formatted(.dateTime.weekday(.wide).month(.wide).day()) + (deload ? " · light week" : "")).uppercased())
                    .font(.footnote.weight(.semibold)).tracking(0.4).foregroundStyle(.tertiary)
                Text(title).font(.system(size: 34, weight: .bold)).tracking(-0.5)
                    .contentTransition(.numericText())
                programPill.padding(.top, 4)
            }
            Spacer()
            Button { you = true } label: {
                Image(systemName: "person.crop.circle").font(.system(size: 26)).foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Goals, progress and settings")
        }
        .padding(.leading, 22).padding(.trailing, 12).padding(.top, 8)
        .animation(.snappy, value: index)
    }

    /// FIT-39: "Week 3 of 16 · Base ›", with how far through the program as a ring. Opens the program.
    @ViewBuilder private var programPill: some View {
        if let profile = profiles.first, let weeks = profile.program, let start = profile.programStart {
            let index = ProgramPlan.week(of: .now, start: start)
            if weeks.indices.contains(index) {
                Button { showProgram = true } label: {
                    HStack(spacing: 7) {
                        ZStack {
                            Circle().stroke(Color(.quaternaryLabel), lineWidth: 2.5)
                            Circle().trim(from: 0, to: (Double(index) + 0.5) / Double(weeks.count))
                                .stroke(Color.primary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        }
                        .frame(width: 14, height: 14)
                        Text("Week \(index + 1) of \(weeks.count) · \(ProgramPlan.title(weeks[index]))")
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 12).frame(minHeight: 32)
                    .background(Color(.secondarySystemBackground), in: .capsule)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens your program")
            }
        }
    }

    private func strip(_ week: [Date], cards: [DayCard], selected: Int) -> some View {
        HStack(spacing: 0) {
            ForEach(week.indices, id: \.self) { index in
                let on = index == selected
                Button { withAnimation(.snappy) { day = index } } label: {
                    VStack(spacing: 4) {
                        Text(week[index].formatted(.dateTime.weekday(.narrow)))
                            .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                        Text(week[index].formatted(.dateTime.day()))
                            .font(.body.weight(on || index == todayIndex ? .semibold : .regular)).monospacedDigit()
                            .foregroundStyle(on ? Color(.systemBackground) : index == todayIndex ? .primary : .secondary)
                            .frame(width: 34, height: 34)
                            .background(on ? Color.primary : .clear, in: .circle)
                        dot(cards[index])
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(week[index].formatted(.dateTime.weekday(.wide)))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    /// Filled when done, a ring when planned, nothing on rest days.
    @ViewBuilder private func dot(_ card: DayCard) -> some View {
        switch card {
        case .done: Circle().fill(.primary).frame(width: 5, height: 5)
        case .plan: Circle().strokeBorder(.primary, lineWidth: 1.5).frame(width: 5, height: 5)
        case .rest: Color.clear.frame(width: 5, height: 5)
        }
    }

    // MARK: Cards

    private func cards(_ week: [Date]) -> [DayCard] {
        let profile = profiles.first
        let workouts = planned.filter { $0.kind == .workout }
        let context = DayCard.Context(templates: templates, sessionMinutes: profile?.sessionMinutes ?? 45,
                                      deload: thisWeeksPlan?.warnings.contains { $0.hasPrefix("Deload") } == true,
                                      tier: AgeTier.of(age: profile?.age ?? 30))
        return week.map { day in
            let next = workouts.first { $0.date >= Calendar.current.date(byAdding: .day, value: 1, to: day)! }
            return DayCard.make(day: day, planned: workouts, entries: entries,
                                next: next.map { ($0.slot ?? "Workout", $0.date) }, context: context)
        }
    }

    @ViewBuilder private func card(_ card: DayCard, isToday: Bool, isPast: Bool) -> some View {
        Group {
            switch card {
            case .plan(let plan): planCard(plan, isToday: isToday, isPast: isPast)
            case .done(let done): doneCard(done)
            case .rest(let coach):
                VStack(spacing: 8) {
                    Text("Rest").font(.system(size: 30, weight: .bold)).tracking(-0.4)
                    Text(coach).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .frame(maxWidth: 240)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(EdgeInsets(top: 26, leading: 24, bottom: 24, trailing: 24))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 30))
    }

    private func planCard(_ plan: DayCard.Planned, isToday: Bool, isPast: Bool) -> some View {
        let names = Dictionary(templates.map { ($0.slug, $0.name) }, uniquingKeysWith: { first, _ in first })
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(plan.start.formatted(date: .omitted, time: .shortened)) · \(plan.minutes) min")
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("Edit exercises", systemImage: "list.bullet") { sheet = .details(plan.items) }
                    if let plan = thisWeeksPlan {
                        Button("Change this week", systemImage: "slider.horizontal.3") { sheet = .adjust(plan) }
                    }
                    Button("Plan this week again", systemImage: "arrow.clockwise") { try? Planner.generate(weekOf: .now, in: context) }
                } label: {
                    Image(systemName: "ellipsis").font(.body.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(width: 32, height: 24)
                }
                .accessibilityLabel("More")
            }
            Text(plan.title).font(.system(size: 30, weight: .bold)).tracking(-0.4).padding(.top, 4)
            Text(plan.coach).font(.subheadline).foregroundStyle(.secondary).lineSpacing(2).padding(.top, 10)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(Self.keyed(plan.session.blocks), id: \.key) { index, key, block in
                    let new = isToday && block.movements.contains { fresh.contains($0.exercise) }
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(block.movements.map { names[$0.exercise] ?? $0.exercise }.joined(separator: " + "))
                            .lineLimit(2)
                        Spacer(minLength: 0)
                        Text(block.dose).font(.system(.subheadline, design: .rounded)).foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    .padding(.vertical, 13)
                    .overlay(alignment: .top) { Divider() }
                    .overlay(alignment: .leading) {
                        if new { Circle().fill(.primary).frame(width: 6, height: 6).offset(x: -14).transition(.opacity) }
                    }
                    // FIT-50: a spoken edit's new exercises slide in, a new workout's one after another.
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 12))
                                                .animation(.snappy.delay(Double(index) * 0.09)),
                                            removal: .opacity))
                }
            }
            .padding(.top, 22)
            .contentShape(.rect)
            .onTapGesture { sheet = .details(plan.items) }
            Spacer(minLength: 16)
            if isToday {
                Button { start(plan) } label: {
                    Label("Start", systemImage: "play.fill").font(.headline).frame(maxWidth: .infinity, minHeight: 58)
                        .foregroundStyle(Color(.systemBackground))
                        .background(Color.primary, in: .capsule)
                }
                .buttonStyle(.plain)
            } else if isPast {
                Button { sheet = .log(plan.items) } label: {
                    Text("Log it").font(.headline).frame(maxWidth: .infinity, minHeight: 58)
                        .background(Color(.systemBackground), in: .capsule)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func doneCard(_ done: DayCard.Done) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(done.start.formatted(date: .omitted, time: .shortened)).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Label("Done", systemImage: "checkmark.circle.fill").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            }
            Text(done.title).font(.system(size: 30, weight: .bold)).tracking(-0.4).padding(.top, 4)
            HStack(alignment: .top, spacing: 8) {
                if let minutes = done.minutes { stat("\(minutes)", "min") }
                stat("\(done.sets)", done.sets == 1 ? "set" : "sets")
                stat(done.volume.formatted(.number.precision(.fractionLength(0))), "lb")
            }
            .padding(.top, 26)
            Text(done.coach).font(.body).lineSpacing(2).padding(.top, 26).fixedSize(horizontal: false, vertical: true)
            if !done.note.isEmpty {
                Text("“\(done.note)”").font(.subheadline).foregroundStyle(.secondary).padding(.top, 12)
            }
            Spacer(minLength: 12)
            if let feel = done.feel {
                Text("Felt \(feel.label.lowercased())").font(.footnote).foregroundStyle(.tertiary)
            }
        }
        .contentShape(.rect)
        .onTapGesture { sheet = .record(done.planned) }
    }

    private func stat(_ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: 28, weight: .semibold, design: .rounded)).tracking(-0.4)
            Text(unit).font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Blocks named by their exercises, so a block keeps its identity across a spoken edit and a new one animates in.
    private static func keyed(_ blocks: [SessionPlan.Block]) -> [(index: Int, key: String, block: SessionPlan.Block)] {
        var seen: [String: Int] = [:]
        return blocks.enumerated().map { index, block in
            let name = block.movements.map(\.exercise).joined(separator: "+")
            seen[name, default: 0] += 1
            return (index, "\(name)#\(seen[name]!)", block)
        }
    }

    // MARK: Actions

    private func start(_ plan: DayCard.Planned) {
        live = WorkoutDraft(session: plan.title, plan: plan.session)
    }

    /// The mic on Today (FIT-29, FIT-30): change the plan, log the session, or log a meal, sleep or weight
    /// (FIT-9). The model sorts what was said; the rules decide; a sheet confirms.
    private func heard(_ said: String) {
        working = said
        step = "Understanding what you said"
        job = Task {
            defer { working = nil; job = nil }
            do {
                switch try await TodayRequestParser.parse(said)?.kind {
                case .change(let change)?: propose(change, said: said)
                case .edit?: try await editToday(said)
                case .didWorkout(let differences)?: logSpoken(differences, said: said)
                case .log?:
                    let result = LogResolver.resolve(try await LogParser.parse(said), recipes: templates.filter { $0.kind == .recipe })
                    if !result.entries.isEmpty { sheet = .check(result.entries) } else { message = "Couldn’t find anything to log in that." }
                case nil:
                    message = "Couldn’t tell what to change. Try “I only have 30 minutes”, “my shoulder hurts” or “give me squats and lunges”."
                }
            } catch {
                if !Task.isCancelled { message = "Couldn’t understand that. Try again." }
            }
        }
    }

    /// The next session not yet done, today or later this week.
    private var nextSession: [PlannedActivity]? {
        let start = Calendar.current.startOfDay(for: .now)
        let loggedDays = Set(entries.filter { $0.kind == .workout }.map { Calendar.current.startOfDay(for: $0.timestamp) })
        let upcoming = planned.filter { $0.kind == .workout && $0.date >= start && !loggedDays.contains(Calendar.current.startOfDay(for: $0.date)) }
        guard let first = upcoming.first else { return nil }
        return upcoming.filter { Calendar.current.isDate($0.date, inSameDayAs: first.date) }
    }

    private func propose(_ change: SpokenRequest.Change, said: String) {
        guard let plan = thisWeeksPlan, let profile = profiles.first, let session = nextSession, let first = session.first else {
            message = "There’s no session left this week to change."
            return
        }
        let calendar = Calendar.current
        let day = Planner.workouts(plan, templates: templates).first { calendar.isDate($0.date, inSameDayAs: first.date) }?.date ?? first.date
        let catalog = Planner.catalog(templates)
        let bySlug = Dictionary(catalog.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
        let name = first.slot ?? "Workout"
        var moveTo: Date?
        guard let result = Planner.adjust(plan, templates: templates, { week in
            switch change {
            case .time(let minutes):
                return TrainingAdjuster.time(week, on: day, minutes: minutes, sessionMinutes: profile.sessionMinutes) {
                    bySlug[$0.exercise]?.isGoalLift == true
                }
            case .energy: return TrainingAdjuster.energy(week, on: day)
            case .injury(let area):
                return TrainingAdjuster.injury(week, areas: BodyArea.muscles(for: [area]), label: area.lowercased(),
                                               settings: profile.trainingSettings, catalog: catalog)
            case .move(let weekday):
                let time = calendar.dateComponents([.hour, .minute], from: day)
                let target = calendar.date(byAdding: DateComponents(day: weekday, hour: time.hour, minute: time.minute),
                                           to: Week.monday(of: day))!
                moveTo = target
                return TrainingAdjuster.reschedule(week, from: day, to: target) { bySlug[$0]?.pattern }
            }
        }) else {
            message = "That day is within 48 hours of another session for the same muscles, so the plan can’t move it there."
            return
        }
        let names = Dictionary(templates.map { ($0.slug, $0.name) }, uniquingKeysWith: { first, _ in first })
        let before = result.before.filter { calendar.isDate($0.date, inSameDayAs: day) }
        let after = result.after.filter { calendar.isDate($0.date, inSameDayAs: moveTo ?? day) }
        var lines = Proposal.lines(before: before, after: after, names: names)
        let unchanged = "Nothing changes until you apply it."
        let proposal: Proposal
        switch change {
        case .time(let minutes):
            proposal = Proposal(said: said, title: "\(name) in \(minutes) minutes", lines: lines,
                                footnote: "Your plan’s rules picked this, so the main lifts stay. \(unchanged)",
                                keep: "Keep \(profile.sessionMinutes) minutes", plan: plan, workouts: result.past + result.after)
        case .energy:
            proposal = Proposal(said: said, title: "An easier \(name)", lines: lines,
                                footnote: "One less on the effort cap and fewer sets. \(unchanged)",
                                keep: "Keep the plan", plan: plan, workouts: result.past + result.after)
        case .injury(let area):
            let later = result.before.filter { !calendar.isDate($0.date, inSameDayAs: day) }
                != result.after.filter { !calendar.isDate($0.date, inSameDayAs: day) }
            proposal = Proposal(said: said, title: "Working around your \(area.lowercased())", lines: lines,
                                footnote: "Exercises that load it are swapped for safe ones, or dropped if there are none\(later ? ", here and later this week" : ""). \(unchanged)",
                                keep: "Keep the plan", plan: plan, workouts: result.past + result.after)
        case .move:
            let target = moveTo ?? day
            lines = [Proposal.Line(mark: .changed, text: "\(day.formatted(.dateTime.weekday(.wide))) → \(target.formatted(.dateTime.weekday(.wide).hour().minute()))"),
                     Proposal.Line(mark: .same, text: "Same exercises")]
            proposal = Proposal(said: said, title: "\(name) on \(target.formatted(.dateTime.weekday(.wide)))", lines: lines,
                                footnote: "No two sessions for the same muscles within 48 hours. \(unchanged)",
                                keep: "Keep \(day.formatted(.dateTime.weekday(.wide)))", plan: plan, workouts: result.past + result.after)
        }
        if result.before == result.after {
            withAnimation { toast = Toast(text: "\(name) already fits") }
            return
        }
        sheet = .propose(proposal)
    }

    /// FIT-47: the model edits today's workout as JSON; code checks what comes back and it's applied at once,
    /// with Undo. A rest day is edited as an empty workout.
    private func editToday(_ said: String) async throws {
        let calendar = Calendar.current
        guard let plan = thisWeeksPlan, let profile = profiles.first else {
            message = "There’s no plan this week to change."
            return
        }
        guard !entries.contains(where: { $0.kind == .workout && calendar.isDateInToday($0.timestamp) }) else {
            message = "Today’s workout is already logged."
            return
        }
        let exercises = templates.filter { $0.kind == .exercise }
        let names = Dictionary(exercises.map { ($0.slug, $0.name) }, uniquingKeysWith: { first, _ in first })
        let all = Planner.workouts(plan, templates: templates)
        let todays = all.filter { calendar.isDateInToday($0.date) }
        let date = todays.first?.date ?? calendar.date(byAdding: .minute, value: profile.workoutTime, to: calendar.startOfDay(for: .now))!
        let history = Planner.loggedSets(entries, templates: templates)
        let setup = TodayWorkout.Setup(names: names, catalog: Planner.catalog(templates), settings: profile.trainingSettings,
                                       history: history,
                                       weeksSinceDeload: Training.weeksSinceDeload(history, before: plan.weekStart, calendar: calendar),
                                       date: date, session: todays.first?.session ?? "Workout", calendar: calendar)
        // FIT-50: each tool's change is shown in place as it's made, so the ~8 s of work is visible. Cancel or a
        // failure puts today back as it was.
        let base = templates, others = all.filter { !calendar.isDateInToday($0.date) }
        let added = Added()
        func show(_ rows: [PlannedWorkout], _ seeds: [TemplateSeed]) throws {
            for seed in seeds where !added.templates.contains(where: { $0.slug == seed.slug }) {
                let template = Template(kind: seed.kind, name: seed.name, slug: seed.slug, attributes: seed.attributes)
                context.insert(template)
                added.templates.append(template)
            }
            let shown = Set(Planner.workouts(plan, templates: base + added.templates).filter { calendar.isDateInToday($0.date) }.map(\.exercise))
            try withAnimation(.snappy) {
                fresh.formUnion(Set(rows.map(\.exercise)).subtracting(shown))
                try Planner.apply((others + rows).sorted { $0.date < $1.date }, to: plan, templates: base + added.templates, in: context)
            }
        }
        func restore() {
            withAnimation(.snappy) {
                try? Planner.apply(all, to: plan, templates: base, in: context)
                for template in added.templates { context.delete(template) }
                try? context.save()
                fresh = []
            }
        }
        let result: WorkoutAgent.Outcome
        do {
            result = try await WorkoutAgent.run(said, today: todays, setup: setup) { change in
                step = change.step
                try? show(change.workouts, change.newExercises)
            }
            try Task.checkCancellation()
        } catch {
            restore()
            throw error
        }
        guard result.changed, result.workouts != todays else {
            restore()
            if result.changed { withAnimation { toast = Toast(text: "That’s already today’s plan") } }
            else { message = "Couldn’t make that change. Try saying it another way." }
            return
        }
        try show(result.workouts, result.newExercises)
        let kept = added.templates
        withAnimation { toast = Toast(text: result.summary) { [context] in
            try? Planner.apply(all, to: plan, templates: base, in: context)
            for template in kept { context.delete(template) }
            try? context.save()
        } }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(.easeOut(duration: 0.6)) { fresh = [] }
        }
    }

    /// Templates a spoken edit added while it ran.
    private final class Added { var templates: [Template] = [] }

    private func apply(_ proposal: Proposal) {
        let before = Planner.workouts(proposal.plan, templates: templates)
        try? Planner.apply(proposal.workouts, to: proposal.plan, templates: templates, in: context)
        withAnimation { toast = Toast(text: "Plan changed") { [context, templates] in
            try? Planner.apply(before, to: proposal.plan, templates: templates, in: context)
        } }
    }

    private func logSpoken(_ differences: [SpokenRequest.Difference], said: String) {
        guard let session = nextSession, let first = session.first, Calendar.current.isDateInToday(first.date) else {
            message = "There’s no session planned today to log."
            return
        }
        let names = Dictionary(templates.map { ($0.slug, $0.name) }, uniquingKeysWith: { first, _ in first })
        var draft = WorkoutDraft(session: first.slot ?? "Workout", plan: Planner.session(session, templates: templates))
        let changed = SpokenLog.apply(differences, to: &draft, names: names)
        sheet = .spoken(Spoken(said: said, title: draft.session, draft: draft, changed: changed))
    }

    private func save(_ spoken: WorkoutDraft) {
        let saved = spoken.save(at: .now, templates: templates, in: context)
        try? context.save()
        day = todayIndex
        withAnimation { toast = Toast(text: "\(spoken.session) saved") { [context] in
            for entry in saved { context.delete(entry) }
            try? context.save()
        } }
    }

    @ViewBuilder private func sheetView(_ sheet: Sheet) -> some View {
        switch sheet {
        case .details(let items):
            NavigationStack {
                WorkoutDetailView(items: items, session: Planner.session(items, templates: templates))
            }
        case .record(let items): NavigationStack { SessionRecordView(planned: items) }
        case .log(let items):
            NavigationStack {
                WorkoutLogView(draft: WorkoutDraft(session: items.first?.slot ?? "Workout", plan: Planner.session(items, templates: templates)),
                               date: items.first?.date ?? .now)
            }
        case .adjust(let plan): NavigationStack { AdjustSheet(plan: plan) }
        case .check(let entries): LogCheckSheet(entries: entries)
        case .propose(let proposal): ProposalSheet(proposal: proposal) { apply(proposal) }
        case .spoken(let spoken):
            SpokenCheckSheet(said: spoken.said, title: spoken.title, draft: spoken.draft, changed: spoken.changed,
                             names: Dictionary(templates.map { ($0.slug, $0.name) }, uniquingKeysWith: { first, _ in first }),
                             onSave: save)
        }
    }
}

extension WorkoutDraft: Identifiable {
    var id: String { session + rows.map(\.id.uuidString).joined() }
}
