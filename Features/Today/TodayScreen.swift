import SwiftUI
import SwiftData

/// Today (FIT-297, design A, https://claude.ai/artifact/QBzBgYEd35faydgEk8Qo3f): only today's session, the goal line
/// above it, and three actions: Start, Change it when something comes up, or Log what was done. The week is on Program.
struct TodayScreen: View {
    @Environment(\.modelContext) private var context
    /// FIT-102: signed in, program design uses Claude through our server.
    @Environment(Account.self) private var account
    @Environment(CoachInbox.self) private var coach
    /// FIT-120: Pro runs the program; without it, logging stays.
    @Environment(Pro.self) private var pro
    @Query(sort: \LogEntry.timestamp) private var entries: [LogEntry]
    @Query private var plans: [Plan]
    @Query private var profiles: [Profile]
    @Query(sort: \PlannedActivity.date) private var planned: [PlannedActivity]
    @Query private var templates: [Template]
    @Query(sort: \Goal.createdAt) private var goals: [Goal]
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
    @State private var tracking: RunTarget?
    @State private var you = false
    /// FIT-204: today's check-in sheet.
    @State private var checkingIn = false
    @State private var review: WeekReport?
    @State private var sharing: WinItem?
    /// FIT-106: the wins there were before a workout, so the ones it earns can be celebrated when it's saved.
    @State private var winsBefore: Set<String> = []
    @State private var saved = false
    @State private var celebrating: [WinItem]?
    @State private var sessionLink: SharedLink?
    /// FIT-297: today's blocks checked off as done (L3), saved together.
    @State private var checked: Set<Int> = []

    enum Sheet: Identifiable {
        case details([PlannedActivity]), record([PlannedActivity]), log([PlannedActivity]), adjust(Plan), check([LogDraftEntry])
        case propose(Proposal), spoken(Spoken), own, run(PlannedActivity?), ran(LogEntry)
        /// FIT-297: Change and Log on Today.
        case change([PlannedActivity]), logChoice([PlannedActivity])
        /// FIT-235: a workout of their own on a past day: pick the exercises, then log the sets on that day.
        case ownOn(Date), logOwn(WorkoutDraft, Date)
        var id: String {
            switch self {
            case .own: "own"
            case .ownOn(let day): "own \(day)"
            case .logOwn(let draft, let day): "log own \(day) \(draft.id)"
            case .ran(let entry): "ran \(entry.id)"
            case .run(let item): "run \(item?.id.uuidString ?? "")"
            case .details(let items): "details \(items.map(\.id))"
            case .record(let items): "record \(items.map(\.id))"
            case .log(let items): "log \(items.map(\.id))"
            case .adjust(let plan): "adjust \(plan.id)"
            case .check: "check"
            case .propose(let proposal): "propose \(proposal.id)"
            case .spoken(let spoken): "spoken \(spoken.id)"
            case .change(let items): "change \(items.map(\.id))"
            case .logChoice(let items): "log choice \(items.map(\.id))"
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
        (0..<7).map { Calendar.current.date(byAdding: .day, value: $0, to: Week.start(of: .now))! }
    }

    private var todayIndex: Int { week.firstIndex { Calendar.current.isDateInToday($0) } ?? 0 }

    /// The swiped days: today and the six after it, so tomorrow is there on a Sunday too.
    private var days: [Date] {
        let today = Calendar.current.startOfDay(for: .now)
        return (0..<7).map { Calendar.current.date(byAdding: .day, value: $0, to: today)! }
    }

    /// FIT-201: coached, with no session planned from this Monday on.
    private var awaitingCoach: Bool {
        !pro.coaches.isEmpty && !planned.contains { $0.kind == .workout && $0.date >= week[0] }
    }

    private var thisWeeksPlan: Plan? { plans.first { $0.weekStart == week[0] } }
    /// The coach is designing the shown week, and hasn't yet.
    private var planning: Bool { Planner.designing.weeks.contains(week[0]) && thisWeeksPlan?.designedBy == nil }

    var body: some View {
        let weekCards = cards(week)
        let days = days
        let cards = cards(days)
        // FIT-235: a later session can be done today only when today has no session of its own waiting.
        let todayFree: Bool = if case .plan = cards[0] { false } else { true }
        VStack(alignment: .leading, spacing: 0) {
            header(days[0])
            // Each day a card swiped sideways, the next one's edge showing (prototype A,
            // https://claude.ai/artifact/M5FZ8bWiGeoJAG8QKdN7BT).
            // Cards line up on the leading margin; the wider trailing one leaves the next card's edge in view.
            GeometryReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(days.indices, id: \.self) { index in
                            page(cards[index], day: days[index], index: index, week: weekCards, todayFree: todayFree)
                                .frame(width: max(0, proxy.size.width - 22 - 40))
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $day)
                .contentMargins(.leading, 22, for: .scrollContent)
                .contentMargins(.trailing, 40, for: .scrollContent)
                .scrollIndicators(.hidden)
            }
            .padding(.top, 14)
            deckFooter(days.count)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.canvas)
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
                }
            }
            .padding(.bottom, 4)
        }
        // FIT-64: what's said to the coach about today lands here and is done in place.
        .onChange(of: coach.request) { takeFromCoach() }
        .onAppear { takeFromCoach() }
        .animation(.snappy, value: voice.listening)
        .animation(.snappy, value: working)
        .animation(.snappy, value: toast)
        .onAppear { if day == nil { day = 0 } }
        // FIT-220: a tapped notification's day; a coach's reply opens that session and its thread.
        .onChange(of: Navigator.shared.day, initial: true) { _, target in open(target) }
        #if DEBUG
        // `-say "swap deadlifts for RDLs"` runs a spoken request without the mic, for the simulator.
        .task {
            if let said = UserDefaults.standard.string(forKey: "say") {
                try? await Task.sleep(for: .seconds(2))
                heard(said)
            }
            // `-race YES` adds a 10K in 55:00 from a 1:00:00 run and two runs since, to look at race goals (FIT-179).
            if UserDefaults.standard.bool(forKey: "race"), !racing { seedRace() }
            // `-review YES` opens this week's review.
            if UserDefaults.standard.bool(forKey: "review") { review = weekReport() }
            // `-celebrate YES` shows the latest two wins as if a workout had just earned them (FIT-106).
            if UserDefaults.standard.bool(forKey: "celebrate") {
                // A sample when there's no history yet, so the screen can be looked at on a fresh simulator.
                let sample = WinItem(kind: .pr, date: .now, key: "pr:sample", metric: "bench-press.1rm_lb", unit: "lb", value: 205, previous: 190,
                                     trend: [175, 180, 185, 190, 205])
                celebrating = allWins.isEmpty ? [sample] : Array(allWins.prefix(2))
            }
        }
        #endif
        .alert("Couldn’t do that", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: { Text(message ?? "") }
        .onChange(of: voice.problem) { _, problem in if let problem { message = problem } }
        .sheet(item: $sheet, content: sheetView)
        .sheet(isPresented: $you) { YouScreen().tint(RootView.accent) }
        .sheet(isPresented: $checkingIn) {
            CheckInSheet(lastWeight: entries.last { $0.kind == .bodyweight }?.measurements.first { $0.metric == "weight_lb" }?.value)
        }
        .sheet(item: $sharing) { ShareWinSheet(win: $0) }
        .fullScreenCover(isPresented: Binding(get: { review != nil }, set: { if !$0 { review = nil } })) {
            if let review {
                WeeklyReviewScreen(report: review, profile: profiles.first,
                                   recap: Recap.make(review, profile: profiles.first, wins: allWins, sessions: programSessions))
            }
        }
        // FIT-185: run mode, for a run today, planned or not.
        .fullScreenCover(item: $tracking) { target in RunModeView(planned: target.planned) }
        .fullScreenCover(item: $live, onDismiss: celebrate) { draft in
            WorkoutModeView(draft: draft) {
                day = 0
                saved = true
            }
            .onAppear {
                saved = false
                winsBefore = Set(allWins.map(\.key))
            }
        }
        .sheet(item: $sessionLink) { ActivityView(link: $0).presentationDetents([.medium, .large]) }
        .sheet(isPresented: Binding(get: { celebrating != nil }, set: { if !$0 { celebrating = nil } })) {
            if let celebrating { CelebrationSheet(wins: celebrating) }
        }
        // A new week, or a profile that just finished onboarding, gets a plan; the coach designs it with Pro (FIT-120).
        .task(id: "\(profiles.first?.plansItself == true) \(profiles.first?.programSlug ?? "") \(pro.active) \(pro.coaches.isEmpty)") {
            guard Pilot.plansWeeks(hasProgram: profiles.first?.programStart != nil, coached: !pro.coaches.isEmpty) else { return }
            try? Planner.ensureWeek(in: context)
            // The swiped days reach into next week: plan it now, so its sessions don't show as rest days. A week planned
            // early is replanned when it starts (ensureWeek), so its loads still come from the latest sets.
            if let last = days.last, Week.start(of: last) != week[0] { try? Planner.ensureWeek(of: last, in: context) }
            guard pro.active else { return }
            await Planner.design(in: context, model: LanguageModel.programs(signedIn: account.user != nil))
        }
    }

    private func open(_ target: PushTarget?) {
        guard let target else { return }
        Navigator.shared.day = nil
        let days = days
        guard let date = target.day, let index = days.firstIndex(where: { Calendar.current.isDate($0, inSameDayAs: date) }) else { return }
        withAnimation(.snappy) { day = index }
        if target.kind == .reply, case .done(let done) = cards(days)[index] {
            sheet = done.run.map { .ran($0) } ?? .record(done.planned)
        }
    }

    private var allWins: [WinItem] {
        WinFeed.wins(profile: profiles.first, goals: goals, entries: entries, planned: planned, templates: templates)
    }

    /// FIT-108: the program's planned sessions so far, and how many were done, for its recap.
    private var programSessions: (done: Int, planned: Int) {
        guard let start = profiles.first?.programStart else { return (0, 0) }
        let day = { Calendar.current.startOfDay(for: $0) }
        let plannedDays = Set(planned.filter { $0.kind == .workout && $0.date >= start && $0.date <= .now }.map { day($0.date) })
        let doneDays = Set(entries.filter { $0.kind == .workout && $0.timestamp >= start }.map { day($0.timestamp) })
        return (plannedDays.intersection(doneDays).count, plannedDays.count)
    }

    private func trainWithFriend(_ plan: DayCard.Planned) {
        toast = Toast(text: "Making your link…")
        Task {
            do {
                sessionLink = try await TrainWithFriend.link(for: plan, templates: templates)
                toast = nil
            } catch {
                toast = nil
                message = "Couldn’t make a link. Check your connection and try again."
            }
        }
    }

    /// FIT-106: a saved workout that earned wins ends on their cards; otherwise a quiet "saved".
    private func celebrate() {
        guard saved else { return }
        saved = false
        let earned = Wins.earned(allWins, before: winsBefore)
        if earned.isEmpty { toast = Toast(text: "Workout saved") } else { celebrating = earned }
    }

    // MARK: Header and strip

    /// The date written out with the program's week, the account, and the goal line (FIT-297: no relative title).
    private func header(_ date: Date) -> some View {
        let deload = thisWeeksPlan?.warnings.contains { $0.hasPrefix("Deload") } == true
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()) + programWeek + (deload ? " · light week" : ""))
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Color.inkMuted)
                Spacer()
                Button { you = true } label: {
                    Image(systemName: "person.crop.circle").font(.system(size: 26)).foregroundStyle(Color.inkMuted)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Account and library")
            }
            if let goal = goalLine {
                HStack(spacing: 8) {
                    Text(goal.label).font(.subheadline.weight(.semibold))
                    ProgressView(value: goal.fraction).tint(Plate.current.mark).scaleEffect(y: 1.4)
                    Text(goal.end.formatted(.dateTime.month(.abbreviated).day())).font(.subheadline.weight(.bold)).foregroundStyle(Plate.current.mark)
                }
                .accessibilityElement(children: .combine)
            }
            if !pro.coaches.isEmpty { checkInButton }
        }
        .padding(.leading, 22).padding(.trailing, 12).padding(.top, 4)
    }

    /// FIT-297: the first active goal, "Back squat 250 lb", and how far along its dates today is.
    private var goalLine: (label: String, end: Date, fraction: Double)? {
        guard let goal = goals.first(where: { $0.status == .active }), let option = GoalOption.all.first(where: { $0.metric == goal.metric }),
              let end = goal.deadline.flatMap({ $0 > .now ? $0 : nil }) ?? profiles.first?.targetDate ?? goal.deadline else { return nil }
        let start = profiles.first?.programStart ?? goal.createdAt
        let fraction = min(1, max(0.02, Date.now.timeIntervalSince(start) / max(1, end.timeIntervalSince(start))))
        let label = ["lb", "reps"].contains(goal.unit) ? "\(option.liftName) \(Coach.number(goal.target)) \(goal.unit)" : option.liftName
        return (label, end, fraction)
    }

    /// FIT-297: "Squat, bench press, row": a session named by its lifts, not "Day A".
    static func title(_ session: SessionPlan, names: [String: String], fallback: String) -> String {
        let lifts = session.blocks.flatMap(\.movements).map { short(names[$0.exercise] ?? $0.exercise) }
        guard !lifts.isEmpty else { return fallback }
        let shown = lifts.prefix(3).enumerated().map { $0.offset == 0 ? $0.element.prefix(1).uppercased() + $0.element.dropFirst() : $0.element }
        return shown.joined(separator: ", ") + (lifts.count > 3 ? " + \(lifts.count - 3) more" : "")
    }

    /// A lift by the word people say: "Back Squat" → "squat", "Bent Over Barbell Row" → "row", "Bench Press" →
    /// "bench press" (a press needs its kind).
    static func short(_ name: String) -> String {
        let words = name.split(separator: " ").map(String.init)
        guard let last = words.last else { return name.lowercased() }
        let needsKind = ["Press", "Raise", "Curl", "Extension", "Fly", "Pulldown", "Thrust"].contains(last)
        return (needsKind && words.count > 1 ? "\(words[words.count - 2]) \(last)" : last).lowercased()
    }

    /// The last working load logged for each exercise before today, for "+5 lb".
    private var previousLoads: [String: Double] {
        let today = Calendar.current.startOfDay(for: .now)
        var last: [String: Double] = [:]
        for set in Planner.loggedSets(entries.filter { $0.kind == .workout && $0.timestamp < today }, templates: templates) {
            if let load = set.value("load_lb") ?? set.value("load_lb_hand") { last[set.exercise] = load }
        }
        return last
    }

    /// FIT-204: weight, sleep and a note for the coach, or what today's said.
    private var checkInButton: some View {
        let today = entries.filter { ($0.kind == .bodyweight || $0.kind == .sleep) && Calendar.current.isDateInToday($0.timestamp) }
        let summary = CheckIn.summary(today)
        return Button { checkingIn = true } label: {
            Label(summary.map { "Checked in · \($0)" } ?? "Check in", systemImage: summary == nil ? "plus.circle" : "checkmark.circle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(summary == nil ? .primary : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Weight, sleep and a note for your coach")
    }

    /// FIT-39's "Week 3 of 16", in the date line since the program has its own tab (FIT-64).
    private var programWeek: String {
        guard let profile = profiles.first, let weeks = profile.program, let start = profile.programStart else { return "" }
        let index = ProgramPlan.week(of: .now, start: start)
        return weeks.indices.contains(index) ? " · Week \(index + 1) of \(weeks.count)" : ""
    }

    private func takeFromCoach() {
        if let said = coach.take(for: .today) { heard(said) }
    }

    // MARK: Cards

    private func cards(_ week: [Date]) -> [DayCard] {
        let profile = profiles.first
        let workouts = planned.filter { $0.kind == .workout }
        let context = DayCard.Context(templates: templates, sessionMinutes: profile?.sessionMinutes ?? 45,
                                      deload: thisWeeksPlan?.warnings.contains { $0.hasPrefix("Deload") } == true,
                                      tier: AgeTier.of(age: profile?.age ?? 30), coach: pro.coaches.first?.mention)
        return week.map { day in
            let next = workouts.first { $0.date >= Calendar.current.date(byAdding: .day, value: 1, to: day)! }
            return DayCard.make(day: day, planned: workouts, entries: entries,
                                next: next.map { ($0.slot ?? "Workout", $0.date) }, context: context)
        }
    }

    private func weekReport() -> WeekReport {
        WeekReport.make(profile: profiles.first, goals: goals, entries: entries, planned: planned, templates: templates)
    }

    @ViewBuilder private func dayContent(_ card: DayCard, day: Date, isToday: Bool, isPast: Bool, todayFree: Bool) -> some View {
        switch card {
        // FIT-74: the week standing in until the coach's arrives isn't shown as if it were the plan.
        case .plan where planning:
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Your coach is planning this week").font(.headline)
                Text("Usually under a minute.").font(.subheadline).foregroundStyle(Color.inkMuted)
            }
            .frame(maxWidth: .infinity).padding(.top, 80)
        case .plan(let plan): planView(plan, isToday: isToday)
        case .done(let done): doneCard(done)
        // FIT-201: a coach's client with nothing planned from this week on is waiting on the coach, not resting.
        case .rest where awaitingCoach:
            VStack(alignment: .leading, spacing: 8) {
                Text(planned.contains { $0.kind == .workout } ? "Your coach is writing this week" : "Your coach is writing your first week")
                    .font(.display(28))
                Text("It shows up here as soon as it’s ready.").foregroundStyle(Color.inkMuted)
            }
        case .rest(let coach):
            VStack(alignment: .leading, spacing: 8) {
                Text("Rest day").font(.display(30))
                Text(coach).foregroundStyle(Color.inkMuted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Design A's session: its lifts as the title, the minutes and the coach's line, then the list (warm-up first,
    /// supersets bracketed), checked off and changed in place.
    private func planView(_ plan: DayCard.Planned, isToday: Bool) -> some View {
        let names = Dictionary(templates.map { ($0.slug, $0.name) }, uniquingKeysWith: { first, _ in first })
        let lifts = lifting(plan.items)
        return VStack(alignment: .leading, spacing: 0) {
            Text(lifts.isEmpty ? plan.title : Self.title(plan.session, names: names, fallback: plan.title))
                .font(.display(30)).fixedSize(horizontal: false, vertical: true)
            Text("\(plan.minutes) min · \(plan.coach)").font(.subheadline).foregroundStyle(Color.inkMuted)
                .padding(.top, 6).fixedSize(horizontal: false, vertical: true)
            // A later day is read-only: its week may be replanned before it starts, which would undo a change made now.
            SessionList(session: plan.session, names: names, previous: previousLoads,
                        checked: lifts.isEmpty || !isToday ? nil : $checked,
                        onLoad: isToday ? { exercise, step in changeLoad(exercise, by: step, in: plan.items) } : nil)
                .padding(.top, 10)
            ForEach(plan.ran) { run in RunRow(run: run) { sheet = .ran(run) }.padding(.top, 16) }
        }
    }

    /// FIT-297: Start, then Change and Log side by side; a checked-off session's Save bar in their place.
    @ViewBuilder private func actions(_ card: DayCard, week cards: [DayCard]) -> some View {
        VStack(spacing: 8) {
            switch card {
            case .plan(let plan) where !planning:
                if !checked.isEmpty {
                    Button { saveChecked(plan) } label: {
                        HStack {
                            Text("\(checked.count) of \(plan.session.blocks.count) done").font(.headline)
                            Spacer()
                            Text("Save workout").font(.headline).padding(.horizontal, 16).padding(.vertical, 10)
                                .foregroundStyle(Plate.current.onAccent).background(.tint, in: .rect(cornerRadius: 12))
                        }
                        .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 8)
                        .foregroundStyle(Color(.systemBackground)).background(Color.ink, in: .rect(cornerRadius: 18))
                    }
                    .buttonStyle(.plain)
                } else {
                    Button { start(plan) } label: {
                        Label(lifting(plan.items).isEmpty ? "Start the run" : "Start", systemImage: lifting(plan.items).isEmpty ? "figure.run" : "play.fill")
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 58)
                            .foregroundStyle(Plate.current.onAccent)
                            .background(.tint, in: .rect(cornerRadius: 18))
                    }
                    .buttonStyle(.plain)
                    pair("Change", "arrow.left.arrow.right", { sheet = .change(plan.items) }, "Log", "plus", { sheet = .logChoice(plan.items) })
                }
            case .done(let done):
                pair("Edit the sets", "square.and.pencil", { if let run = done.run { sheet = .ran(run) } else { sheet = .record(done.planned) } },
                     "Log", "plus", { sheet = .logChoice([]) })
            default:
                // FIT-235: the next session this week pulled to today.
                if let next = nextPlanned(cards) {
                    pair("Train today", "arrow.uturn.left", { doToday(next) }, "Log", "plus", { sheet = .logChoice([]) })
                } else {
                    pair(nil, nil, nil, "Log a workout", "plus", { sheet = .logChoice([]) })
                }
            }
            pips(cards)
        }
    }

    /// One day's card: its name, the session (scrolling on its own when it's long), then that day's actions.
    private func page(_ card: DayCard, day: Date, index: Int, week weekCards: [DayCard], todayFree: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            dayLabel(day, index: index).padding(.horizontal, 18).padding(.top, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // FIT-8: the week's review is the first thing on its last day.
                    if index == 0, WeekReport.isDue() {
                        let report = weekReport()
                        WeekReviewCard(report: report) { review = report }
                    }
                    dayContent(card, day: day, isToday: index == 0, isPast: false, todayFree: todayFree)
                }
                .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
            Group {
                if index == 0 { actions(card, week: weekCards) } else { laterActions(card, todayFree: todayFree) }
            }
            .padding(.horizontal, 18).padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.surface, in: .rect(cornerRadius: 20))
    }

    /// "Today", "Tomorrow  Sat, Oct 31", "Sunday  Nov 1" (the header already says today's date).
    private func dayLabel(_ day: Date, index: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(index == 0 ? "Today" : index == 1 ? "Tomorrow" : day.formatted(.dateTime.weekday(.wide)))
                .font(.headline).foregroundStyle(index == 0 ? Plate.current.mark : Color.ink)
            if index > 0 {
                Text(day.formatted(index == 1 ? .dateTime.weekday(.abbreviated).month(.abbreviated).day() : .dateTime.month(.abbreviated).day()))
                    .font(.subheadline).foregroundStyle(Color.inkMuted)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// A later day: pull its session to today (FIT-235) when today has none waiting, or open its sets.
    @ViewBuilder private func laterActions(_ card: DayCard, todayFree: Bool) -> some View {
        if case .plan(let plan) = card, !planning {
            if todayFree {
                pair("Do It Today", "arrow.uturn.left", { doToday(plan) }, "See the Sets", "list.bullet", { sheet = .details(plan.items) })
            } else {
                pair(nil, nil, nil, "See the Sets", "list.bullet", { sheet = .details(plan.items) })
            }
        }
    }

    /// Where the deck is, and on today, that tomorrow is a swipe away.
    private func deckFooter(_ count: Int) -> some View {
        let shown = day ?? 0
        return HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule().fill(index == shown ? Color.ink : Color.inkFaint).frame(width: index == shown ? 18 : 6, height: 6)
            }
            Spacer()
            if shown == 0 { Text("Swipe for tomorrow").font(.subheadline.weight(.semibold)).foregroundStyle(Color.inkMuted) }
        }
        .padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 8)
        .animation(.snappy, value: shown)
        .accessibilityHidden(true)
    }

    private func nextPlanned(_ cards: [DayCard]) -> DayCard.Planned? {
        for index in cards.indices where index > todayIndex { if case .plan(let plan) = cards[index] { return plan } }
        return nil
    }

    private func pair(_ left: String?, _ leftIcon: String?, _ leftAction: (() -> Void)?, _ right: String, _ rightIcon: String,
                      _ rightAction: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            if let left, let leftIcon, let leftAction { secondary(left, leftIcon, leftAction) }
            secondary(right, rightIcon, rightAction)
        }
    }

    private func secondary(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 48)
                .background(Color.fill, in: .rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    /// This week's sessions as short bars: done, today's, still to come.
    @ViewBuilder private func pips(_ cards: [DayCard]) -> some View {
        let sessions = cards.indices.filter { index in if case .rest = cards[index] { false } else { true } }
        if !sessions.isEmpty {
            let done = sessions.filter { index in if case .done = cards[index] { true } else { false } }.count
            HStack(spacing: 6) {
                ForEach(sessions, id: \.self) { index in
                    let isDone: Bool = if case .done = cards[index] { true } else { false }
                    Capsule().fill(isDone ? Color.ink : index == todayIndex ? Plate.current.mark : Color.fillStrong).frame(width: 26, height: 6)
                }
                Text(done == sessions.count ? "\(done) of \(done) this week" : "\(done) of \(sessions.count) done this week")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Color.inkMuted).padding(.leading, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
            .accessibilityElement(children: .combine)
        }
    }

    /// FIT-297 (E1): a load changed in place on Today changes the plan's working sets for that exercise.
    private func changeLoad(_ exercise: String, by step: Double, in items: [PlannedActivity]) {
        guard let id = templates.first(where: { $0.slug == exercise })?.id else { return }
        for item in items where item.templateRef == id && item.note != TrainingGenerator.warmupNote {
            var targets = item.targets
            guard let index = targets.firstIndex(where: { ["load_lb", "load_lb_hand"].contains($0.metric) }) else { continue }
            targets[index].value = max(0, targets[index].value + step)
            item.targets = targets
            item.updatedAt = .now
        }
        try? context.save()
    }

    /// FIT-297 (L3): the checked-off lifts saved as planned, with Undo; wins they earn are celebrated.
    private func saveChecked(_ plan: DayCard.Planned) {
        var draft = WorkoutDraft(session: plan.title, plan: plan.session)
        for index in draft.rows.indices where checked.contains(draft.rows[index].block) { draft.rows[index].done = true }
        winsBefore = Set(allWins.map(\.key))
        let saved = draft.save(at: .now, templates: templates, in: context)
        try? context.save()
        checked = []
        let earned = Wins.earned(allWins, before: winsBefore)
        if !earned.isEmpty { celebrating = earned; return }
        withAnimation { toast = Toast(text: "Workout saved") { [context] in
            for entry in saved { context.delete(entry) }
            try? context.save()
        } }
    }

    private func open(_ plan: DayCard.Planned, locked: Bool) {
        if locked { pro.paywall = true } else { sheet = .details(plan.items) }
    }

    /// FIT-120: free, a workout of your own: pick the exercises, then the same workout mode.
    /// FIT-184: a planned run is logged as a run, free, race goal or not. FIT-185: anyone can start a run.
    /// Stacked full width, as the session card's Start and Start a run are: side by side, "Log a workout" ran into its
    /// capsule's edges.
    private func logOwnButton(run: PlannedActivity?) -> some View {
        VStack(spacing: 10) {
            Button { sheet = .own } label: {
                Label("Log a workout", systemImage: "plus").font(.headline).padding(.horizontal, 20)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Color(.systemBackground), in: .capsule)
            }
            if let run { runButton("Start the run", run) } else { runButton("Start a run", nil) }
        }
        .buttonStyle(.plain)
    }

    /// FIT-179: a run, planned or not, logged with its distance and time.
    private func runButton(_ title: String, _ planned: PlannedActivity?) -> some View {
        pill(title, "figure.run") { tracking = RunTarget(planned: planned) }
    }

    /// The card's secondary action: a full-width capsule on the card's grey.
    private func pill(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.headline).padding(.horizontal, 20)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Color(.systemBackground), in: .capsule)
        }
        .buttonStyle(.plain)
    }

    private func doneCard(_ done: DayCard.Done) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // FIT-297: saved, and how it felt, then the session by its lifts.
            Label(done.feel.map { "Saved · felt \($0.label.lowercased())" } ?? "Saved", systemImage: "checkmark.circle.fill")
                .font(.headline).foregroundStyle(Color.good)
            Text(doneTitle(done)).font(.display(30)).padding(.top, 6).fixedSize(horizontal: false, vertical: true)
            if let route = done.route {
                RouteMap(points: route).frame(height: 170).clipShape(.rect(cornerRadius: 16)).padding(.top, 18)
            }
            HStack(alignment: .top, spacing: 8) {
                if let meters = done.runMeters {
                    stat(Coach.number((meters / Running.mile * 100).rounded() / 100), "mi")
                    if let seconds = done.runSeconds {
                        stat(Running.clock(seconds), "time")
                        stat(Running.clock(seconds / (meters / Running.mile)), "per mi")
                    }
                } else {
                    if let minutes = done.minutes { stat("\(minutes)", "min") }
                    stat("\(done.sets)", done.sets == 1 ? "set" : "sets")
                    stat(done.volume.formatted(.number.precision(.fractionLength(0))), "lb")
                }
            }
            .padding(.top, 26)
            Text(done.coach).font(.body).lineSpacing(2).padding(.top, 26).fixedSize(horizontal: false, vertical: true)
            if !done.note.isEmpty {
                Text("“\(done.note)”").font(.subheadline).foregroundStyle(.secondary).padding(.top, 12)
            }
            Spacer(minLength: 12)
            // FIT-15: wins earned that day, a card each (two at most; the rest are in Wins), easy to ignore.
            let wins = WinFeed.wins(allWins, on: done.start)
            if !wins.isEmpty {
                VStack(spacing: 8) {
                    ForEach(wins.prefix(2)) { win in WinCard(win: win) { sharing = win } }
                }
                .padding(.bottom, 14)
                .sensoryFeedback(.success, trigger: wins.map(\.key))
            }
        }
        .contentShape(.rect)
        .onTapGesture { if let run = done.run { sheet = .ran(run) } else { sheet = .record(done.planned) } }
    }

    private func doneTitle(_ done: DayCard.Done) -> String {
        guard done.run == nil, !done.planned.isEmpty else { return done.title }
        let names = Dictionary(templates.map { ($0.slug, $0.name) }, uniquingKeysWith: { first, _ in first })
        return Self.title(Planner.session(done.planned, templates: templates), names: names, fallback: done.title)
    }

    private func stat(_ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.display(28, weight: .semibold, relativeTo: .title)).monospacedDigit()
            Text(unit).font(.footnote).foregroundStyle(Color.inkMuted)
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
        let lifts = lifting(plan.items)
        if lifts.isEmpty, let run = runs(plan.items).first { tracking = RunTarget(planned: run); return }
        live = WorkoutDraft(session: plan.title, plan: lifts.count == plan.items.count ? plan.session : Planner.session(lifts, templates: templates))
    }

    // MARK: FIT-179: runs

    /// FIT-185: run mode's run, planned or not.
    struct RunTarget: Identifiable {
        let id = UUID()
        let planned: PlannedActivity?
    }

    private var runTemplates: Set<UUID> { Set(templates.filter { Running.runs.contains($0.slug) }.map(\.id)) }
    private func runs(_ items: [PlannedActivity]) -> [PlannedActivity] {
        let ids = runTemplates
        return items.filter { $0.kind == .workout && $0.templateRef.map(ids.contains) == true }
    }
    private func lifting(_ items: [PlannedActivity]) -> [PlannedActivity] {
        let ids = runTemplates
        return items.filter { !($0.kind == .workout && $0.templateRef.map(ids.contains) == true) }
    }
    #if DEBUG
    private func seedRace() {
        guard let profile = profiles.first, let start = profile.programStart else { return }
        let run = templates.first { $0.slug == Running.outdoor }?.id
        profile.starts.append(StartingSet(exercise: Running.outdoor, measurements: [
            Measurement(metric: "distance_m", value: 10000, unit: "m"), Measurement(metric: "duration_s", value: 3600, unit: "s")]))
        let goal = Goal(kind: .training, metric: Running.metric(meters: 10000), target: 3300, unit: "s", deadline: profile.targetDate)
        goal.baseline = 3600
        context.insert(goal)
        for (days, km, minutes) in [(1.0, 8.0, 46.0), (4.0, 10.0, 57.5)] {
            context.insert(LogEntry(kind: .workout, timestamp: start.addingTimeInterval(days * 86_400 + 8 * 3600), templateRef: run, measurements: [
                Measurement(metric: "distance_m", value: km * 1000, unit: "m"), Measurement(metric: "duration_s", value: minutes * 60, unit: "s")], note: "easy"))
        }
    }
    #endif

    /// Someone training for a race gets "Log a run" beside "Log a workout".
    private var racing: Bool { goals.contains { $0.status == .active && Running.meters($0.metric) != nil } }

    /// A workout of your own, started once its sheet has gone (two can't be presented at once).
    /// FIT-235: a later session moves to today, each row at its own time of day, and Today shows it ready to start.
    /// The coach sees it on today, and Undo puts it back.
    private func doToday(_ plan: DayCard.Planned) {
        let calendar = Calendar.current
        let was = plan.items.map { ($0, $0.date) }
        let today = calendar.startOfDay(for: .now)
        for item in plan.items {
            item.date = today + item.date.timeIntervalSince(calendar.startOfDay(for: item.date))
            item.updatedAt = .now
        }
        try? context.save()
        let from = plan.start.formatted(.dateTime.weekday(.wide))
        withAnimation(.snappy) {
            day = 0
            toast = Toast(text: "\(from)’s session is today") { [context] in
                for (item, date) in was { item.date = date; item.updatedAt = .now }
                try? context.save()
            }
        }
    }

    /// FIT-235: the picked exercises, logged on a past day.
    private func logOwn(_ session: SessionPlan, on day: Date) {
        let draft = WorkoutDraft(session: "Workout", plan: session)
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            sheet = .logOwn(draft, noon)
        }
    }

    /// The next sheet, once this one has gone (two can't be presented at once).
    private func after(_ next: @escaping () -> Void) {
        sheet = nil
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            next()
        }
    }

    private func startOwn(_ session: SessionPlan) {
        let draft = WorkoutDraft(session: "Workout", plan: session)
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            live = draft
        }
    }

    /// The mic on Today (FIT-29, FIT-30): change the plan, log the session, or log a meal, sleep or weight
    /// (FIT-9). The model sorts what was said; the rules decide; a sheet confirms.
    private func heard(_ said: String) {
        working = said
        step = "Understanding what you said"
        job = Task {
            defer { working = nil; job = nil }
            do {
                let kind = try await TodayRequestParser.parse(said)?.kind
                VoiceLog.record(said, "Today sorted it as \(kind.map { String(describing: $0) } ?? "nothing it understood")")
                switch kind {
                // FIT-120: changing the plan, or logging it as planned, is Pro; logging anything else stays free.
                // One `where` per pattern: on `case a, b, c where …` it guards only `c`, which sent every edit to the
                // offer, Pro or not.
                case .change? where !pro.active, .edit? where !pro.active, .didWorkout? where !pro.active:
                    VoiceLog.record(said, "stopped: Pro offer shown")
                    pro.paywall = true
                case .change(let change)?: propose(change, said: said)
                case .edit?: try await editToday(said)
                case .didWorkout(let differences)?: logSpoken(differences, said: said)
                case .log?:
                    let result = LogResolver.resolve(try await LogParser.parse(said), recipes: templates.filter { $0.kind == .recipe })
                    if !result.entries.isEmpty {
                        sheet = .check(result.entries)
                    } else if result.mentionedWorkout, let session = nextSession, let first = session.first,
                              Calendar.current.isDateInToday(first.date) {
                        // FIT-26: a workout is logged from its session, so open today's.
                        sheet = .details(session)
                    } else {
                        message = "Couldn’t find anything to log in that."
                    }
                case nil:
                    message = "Couldn’t tell what to change. Try “I only have 30 minutes”, “my shoulder hurts” or “give me squats and lunges”."
                }
            } catch {
                // What actually went wrong, for the console; the user gets a plain message.
                print("Spoken request failed: \(said) → \(error)")
                VoiceLog.record(said, "failed: \(error)")
                if !Task.isCancelled { message = "The coach couldn’t do that one. Try saying it another way." }
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
                                           to: Week.start(of: day))!
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
                                       date: date, session: todays.first?.session ?? "Workout", calendar: calendar,
                                       planned: Planner.workouts(plan, templates: templates).filter { !calendar.isDate($0.date, inSameDayAs: date) })
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
        VoiceLog.record(said, "edit calls: \(result.calls.isEmpty ? "none" : result.calls.joined(separator: "; ")) → \(result.changed ? result.summary : "no change")")
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
        case .ran(let entry): NavigationStack { RunDetailView(run: entry) }
        case .own:
            NavigationStack {
                WorkoutDetailView(items: [], session: SessionPlan(blocks: []), startTitle: "Start", onStartOwn: startOwn)
            }
        case .ownOn(let day):
            NavigationStack {
                WorkoutDetailView(items: [], session: SessionPlan(blocks: []), startTitle: "Log the sets", startIcon: "square.and.pencil",
                                  onStartOwn: { logOwn($0, on: day) })
            }
        case .logOwn(let draft, let day): NavigationStack { WorkoutLogView(draft: draft, date: day) }
        case .log(let items):
            // A day's runs are logged with their own sheet, which has the time (FIT-179).
            let lifts = lifting(items)
            NavigationStack {
                WorkoutLogView(draft: WorkoutDraft(session: lifts.first?.slot ?? "Workout", plan: Planner.session(lifts, templates: templates)),
                               date: lifts.first?.date ?? .now)
            }
        case .run(let item): NavigationStack { RunLogSheet(planned: item, templates: templates) }
        case .adjust(let plan): NavigationStack { AdjustSheet(plan: plan) }
        case .check(let entries): LogCheckSheet(entries: entries)
        case .propose(let proposal): ProposalSheet(proposal: proposal) { apply(proposal) }
        case .change(let items):
            ChangeSheet(canChangeWeek: pro.active && pro.coaches.isEmpty && thisWeeksPlan != nil) { choice in
                after {
                    switch choice {
                    case .change(let change): propose(change, said: "")
                    case .exercises: self.sheet = .details(items)
                    case .week: if let plan = thisWeeksPlan { self.sheet = .adjust(plan) }
                    }
                }
            }
        case .logChoice(let items):
            LogChoiceSheet(hasToday: !lifting(items).isEmpty) { choice in
                after {
                    switch choice {
                    case .today: self.sheet = .log(items)
                    case .other: self.sheet = .ownOn(.now)
                    case .run: self.sheet = .run(nil)
                    }
                }
            }
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
