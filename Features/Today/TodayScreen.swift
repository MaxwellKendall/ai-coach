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
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    /// FIT-330: the day Today is on. It moves on when the app comes back on a new day, or at midnight while it's open,
    /// and with it the pages and the week's planning.
    @State private var today = Calendar.current.startOfDay(for: .now)
    @State private var day: Int?
    /// FIT-340: the whole conversation with the coach, open.
    @State private var conversing = false
    /// FIT-332: the Sunday of the week shown.
    @State private var shownWeek = Week.start(of: .now)
    /// Which way the last week change went, so the strip slides the right way.
    @State private var forward = true
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
    /// FIT-325: the picker, from a finished program's card.
    @State private var picking = false
    /// FIT-204: today's check-in sheet.
    @State private var checkingIn: CheckInDay?
    /// FIT-344: the weekly check-in sheet.
    @State private var weekly = false
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
        case details([PlannedActivity]), record([PlannedActivity], Date), log([PlannedActivity]), adjust(Plan), check([LogDraftEntry])
        case propose(Proposal), spoken(Spoken), own, run(PlannedActivity?), ran(LogEntry)
        /// FIT-297: Change and Log on Today.
        /// FIT-302: Move (Change and its quick fixes are gone; the session is edited on Today), and Log.
        case move, logChoice([PlannedActivity])
        /// FIT-235: a workout of their own on a past day: pick the exercises, then log the sets on that day.
        case ownOn(Date), logOwn(WorkoutDraft, Date)
        /// A note on a saved workout: its summary row and the note as shown.
        case note(LogEntry, String)
        /// FIT-378: how ticked-off lifts felt, asked as they're saved.
        case feel(DayCard.Planned)
        var id: String {
            switch self {
            case .feel: "feel"
            case .own: "own"
            case .ownOn(let day): "own \(day)"
            case .logOwn(let draft, let day): "log own \(day) \(draft.id)"
            case .ran(let entry): "ran \(entry.id)"
            case .note(let entry, _): "note \(entry.id)"
            case .run(let item): "run \(item?.id.uuidString ?? "")"
            case .details(let items): "details \(items.map(\.id))"
            case .record(let items, let day): "record \(items.map(\.id)) \(day)"
            case .log(let items): "log \(items.map(\.id))"
            case .adjust(let plan): "adjust \(plan.id)"
            case .check: "check"
            case .propose(let proposal): "propose \(proposal.id)"
            case .spoken(let spoken): "spoken \(spoken.id)"
            case .move: "move"
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
        (0..<7).map { Calendar.current.date(byAdding: .day, value: $0, to: Week.start(of: today))! }
    }

    private var todayIndex: Int { week.firstIndex { Calendar.current.isDateInToday($0) } ?? 0 }

    /// The swiped days: the week shown, Sunday first and Saturday last. FIT-332 (author, 2026-11-10): any week, earlier
    /// or later, in place of this week only (2026-10-30).
    private var days: [Date] { (0..<7).map { Calendar.current.date(byAdding: .day, value: $0, to: shownWeek)! } }

    private var isThisWeek: Bool { shownWeek == week[0] }

    /// Today's place in this week's days (the Gregorian weekday runs 1 = Sunday to 7 = Saturday).
    private var todayPos: Int { Calendar.current.component(.weekday, from: .now) - 1 }

    /// Whether a page is today: its place on this week.
    private func isToday(_ index: Int) -> Bool { isThisWeek && index == todayPos }
    private func isPast(_ day: Date) -> Bool { day < Calendar.current.startOfDay(for: .now) }

    /// FIT-332: a later week with nothing planned in it yet: it says so, rather than seven rest days.
    private func notPlannedYet(_ day: Date) -> Bool {
        let start = Week.start(of: day)
        return start > week[0] && !planned.contains { $0.kind == .workout && Week.start(of: $0.date) == start }
    }

    /// To another week, on the same weekday as the day shown; back on this week, today.
    private func go(to sunday: Date) {
        guard sunday != shownWeek else { return }
        let picked = day ?? todayPos
        forward = sunday > shownWeek
        withAnimation(.settle) {
            shownWeek = sunday
            day = sunday == week[0] ? todayPos : picked
        }
    }

    /// Back to today, from any week.
    private func goToday() {
        shownWeek = week[0]
        day = todayPos
    }

    /// FIT-201: coached, with no session planned from this Monday on.
    private var awaitingCoach: Bool {
        !pro.coaches.isEmpty && !planned.contains { $0.kind == .workout && $0.date >= week[0] }
    }

    private var thisWeeksPlan: Plan? { plans.first { $0.weekStart == week[0] } }
    /// The coach is designing the shown week, and hasn't yet.
    private var planning: Bool { isThisWeek && Planner.designing.weeks.contains(week[0]) && thisWeeksPlan?.designedBy == nil }

    var body: some View {
        let weekCards = cards(week)
        let days = days
        let cards = cards(days)
        // FIT-235: another day's session comes to today; when today has a session of its own waiting, the two swap.
        let todayPlan: DayCard.Planned? = if case .plan(let plan) = weekCards[todayPos] { plan } else { nil }
        VStack(alignment: .leading, spacing: 0) {
            header(days, cards: cards).padding(.bottom, 8)
            // Each day a full-width page swiped sideways; the strip above follows it.
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(days.indices, id: \.self) { index in
                        page(cards[index], day: days[index], index: index, week: weekCards, todayPlan: todayPlan)
                            .containerRelativeFrame(.horizontal)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $day)
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .screenBackground()
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
                        .motionTransition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
            .padding(.bottom, 4)
        }
        // FIT-64: what's said to the coach about today lands here and is done in place.
        .onChange(of: coach.request) { takeFromCoach() }
        .onAppear { takeFromCoach() }
        .animation(.settle, value: voice.listening)
        .animation(.settle, value: working)
        .animation(.settle, value: toast)
        .onAppear { if day == nil { day = todayPos } }
        .onChange(of: scenePhase) { _, phase in if phase == .active { turnDay() } }
        // FIT-383: the coach removed them while the app was open: Messages, check-ins and their name go.
        .onChange(of: Navigator.shared.arrived) { _, arrival in
            if arrival?.target.kind == .ended { Task { await pro.refreshCoaches(signedIn: account.user != nil) } }
        }
        // FIT-372: what the coach wrote, for Messages' dot, on opening and on coming back to the front.
        .task(id: scenePhase == .active && !pro.coaches.isEmpty) {
            if scenePhase == .active && !pro.coaches.isEmpty { await CoachMessages.shared.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in turnDay() }
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
        // FIT-430: signed out from You, the welcome screen takes over.
        .onChange(of: account.user == nil) { _, signedOut in if signedOut { you = false } }
        .sheet(isPresented: $conversing) {
            NavigationStack {
                CoachConversation()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { conversing = false } } }
            }
            .tint(RootView.accent)
        }
        .fullScreenCover(isPresented: $picking) { ProgramPicker { picking = false } }
        .sheet(isPresented: $weekly) { WeeklyCheckInSheet() }
        // FIT-344: the weekly reminder on the coach's check-in day, while coached.
        .task(id: "\(profiles.first?.checkInDay ?? -1) \(pro.coaches.isEmpty)") {
            await WeeklyCheckIn.remind(profiles.first?.checkInDay, coached: !pro.coaches.isEmpty)
        }
        .sheet(item: $checkingIn) { checkIn in
            CheckInSheet(day: checkIn.day,
                         lastWeight: entries.last { $0.kind == .bodyweight }?.measurements.first { $0.metric == "weight_lb" }?.value)
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
                goToday()
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
        // FIT-424: weeks are planned at the root (RootView); a failure there is said here, once.
        .onChange(of: Planner.designing.trouble, initial: true) { _, trouble in
            guard let trouble else { return }
            toast = Toast(text: trouble)
            Planner.designing.trouble = nil
        }
    }

    /// FIT-330: a new day since Today last looked goes to it.
    private func turnDay() {
        let now = Calendar.current.startOfDay(for: .now)
        guard now != today else { return }
        today = now
        goToday()
    }

    private func open(_ target: PushTarget?) {
        guard let target else { return }
        Navigator.shared.day = nil
        // FIT-332: the day's own week, whichever it is.
        guard let date = target.day else { return }
        let sunday = Week.start(of: date)
        let days = (0..<7).map { Calendar.current.date(byAdding: .day, value: $0, to: sunday)! }
        guard let index = days.firstIndex(where: { Calendar.current.isDate($0, inSameDayAs: date) }) else { return }
        withAnimation(.settle) {
            shownWeek = sunday
            day = index
        }
        // A reply on a logged session opens it; on any other day its thread is on Today, under the day.
        if target.kind == .reply, case .done(let done) = cards(days)[index] {
            sheet = done.run.map { .ran($0) } ?? .record(done.planned, done.start)
        } else if target.kind == .reply {
            // FIT-340: a reply on a day with nothing logged is read in the conversation.
            conversing = true
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

    /// The day shown as the title ("Today", "Tomorrow", "Monday"), the week strip to jump between days (FIT-27's strip,
    /// brought back), and a coached client's actions. One header for every page.
    private func header(_ days: [Date], cards: [DayCard]) -> some View {
        let shown = min(day ?? todayPos, days.count - 1)
        return VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .firstTextBaseline) {
                Text(Self.dayName(days[shown])).font(.display(34)).contentTransition(.opacity)
                    .animation(.settle, value: shown)
                Spacer()
                // FIT-367: every message with the coach, beside the account, as a toolbar's buttons are.
                if !pro.coaches.isEmpty {
                    // FIT-372: a dot while the coach has written something not yet read on this phone.
                    let unread = CoachMessages.shared.unread(me: account.user?.uid)
                    Button { conversing = true } label: {
                        Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 22)).foregroundStyle(Color.inkMuted) // ui-score: allow dynamic-type: glyph sized to its fixed frame
                            .frame(width: 44, height: 44)
                            .overlay(alignment: .topTrailing) {
                                if unread {
                                    Circle().fill(Plate.current.accent).frame(width: 10, height: 10).offset(x: -6, y: 8)
                                }
                            }
                    }
                    .accessibilityLabel("Messages with \(pro.coaches[0].name ?? "your coach")")
                    .accessibilityValue(unread ? "Unread" : "")
                }
                Button { you = true } label: {
                    Image(systemName: "person.crop.circle").font(.system(size: 26)).foregroundStyle(Color.inkMuted) // ui-score: allow dynamic-type: glyph sized to its fixed frame
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Account and library")
            }
            VStack(spacing: 12) {
                // Simplicity pass: this week needs no header; swipe the strip for another, which then says which and
                // offers the way back.
                if shownWeek != Week.start(of: .now) {
                    HStack {
                        Text(WeekPaging.range(shownWeek)).font(.headline)
                        Spacer()
                        Button("This Week") { goToday() }.font(.subheadline.weight(.semibold)).buttonStyle(.plain).foregroundStyle(Plate.current.mark)
                    }
                }
                strip(days, cards: cards, selected: shown)
                    .id(shownWeek)
                    .motionTransition(.push(from: forward ? .trailing : .leading))
            }
            .clipped()
            // FIT-332: swipe the strip for another week, as in Calendar; the pages below swipe between its days.
            .simultaneousGesture(WeekPaging.swipe { go(to: WeekPaging.week($0, from: shownWeek)) })
        }
        .padding(.horizontal, 20).padding(.top, 4)
    }

    /// The seven days from today: weekday, date, and a dot for a session (ring) or one done (filled). Today's date is in
    /// the plate colour; the shown day is filled.
    private func strip(_ days: [Date], cards: [DayCard], selected: Int) -> some View {
        HStack(spacing: 0) {
            ForEach(days.indices, id: \.self) { index in
                let on = index == selected
                let today = isToday(index)
                Button { withAnimation(.settle) { day = index } } label: {
                    VStack(spacing: 6) {
                        Text(days[index].formatted(.dateTime.weekday(.narrow)))
                            .font(.caption.weight(.semibold)).foregroundStyle(Color.inkMuted)
                        Text(days[index].formatted(.dateTime.day()))
                            .font(.body.weight(on || today ? .semibold : .regular)).monospacedDigit()
                            .foregroundStyle(on ? Color(.systemBackground) : today ? Plate.current.mark : Color.ink)
                            .frame(width: 36, height: 36)
                            .background(on ? Color.ink : .clear, in: .circle)
                        dot(cards[index])
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.dayName(days[index]))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        // Seven dates across the width: past the largest standard size they'd truncate, as Calendar's strip caps them.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    @ViewBuilder private func dot(_ card: DayCard) -> some View {
        switch card {
        case .done: Circle().fill(Color.ink).frame(width: 5, height: 5)
        case .plan: Circle().strokeBorder(Color.ink, lineWidth: 1.5).frame(width: 5, height: 5)
        case .rest: Color.clear.frame(width: 5, height: 5)
        }
    }

    /// FIT-297: "Squat, bench press, row": a session named by its lifts, not "Day A".
    static func title(_ session: SessionPlan, names: [String: String], fallback: String) -> String {
        // The warm-up (blocks with no working sets) isn't what the session is called.
        let lifts = session.blocks.filter { $0.rounds > 0 }.flatMap(\.movements).map { names[$0.exercise] ?? $0.exercise }
        return lifts.isEmpty ? fallback : title(lifts: lifts)
    }

    /// Exercise names as a session's title: "Squat, bench press, row + 1 more".
    static func title(lifts names: [String]) -> String {
        let lifts = names.map(short)
        let shown = lifts.prefix(3).enumerated().map { $0.offset == 0 ? $0.element.prefix(1).uppercased() + $0.element.dropFirst() : $0.element }
        return shown.joined(separator: ", ") + (lifts.count > 3 ? " + \(lifts.count - 3) more" : "")
    }

    /// A lift by the word people say: "Back Squat" → "squat", "Bent Over Barbell Row" → "row", "Bench Press" →
    /// "bench press" (a press needs its kind).
    static func short(_ name: String) -> String {
        // FIT-356: "Dumbbell Row (single-arm)" is a row; the brackets only say which kind.
        let words = name.replacing(/\s*\(.*\)\s*$/, with: "").split(separator: " ").map(String.init)
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

    /// FIT-344: the weekly check-in is due: the coach's day or after, this week, and not done yet.
    private var weeklyDue: Bool {
        let done = entries.contains { $0.kind == .checkin && $0.timestamp >= Week.start(of: .now) }
        return WeeklyCheckIn.isDue(profiles.first?.checkInDay ?? WeeklyCheckIn.defaultDay, today: .now, done: done)
    }

    /// A check-in sheet's day.
    struct CheckInDay: Identifiable {
        var day: Date
        var id: Date { day }
    }

    /// FIT-367: a coached client's weekly check-in, due today: a card over the session, as the week's review is.
    private var weeklyCard: some View {
        Button { weekly = true } label: {
            HStack(spacing: 14) {
                // Accessibility sizes keep the words and their width: no glyph, and the title alone.
                if !typeSize.isAccessibilitySize {
                    Image(systemName: "list.clipboard").font(.title3).foregroundStyle(Plate.current.mark).frame(width: 28)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Weekly check-in").font(.headline)
                    if !typeSize.isAccessibilitySize {
                        Text("A few questions from \(pro.coaches.first?.name ?? "your coach") about your week")
                            .font(.subheadline).foregroundStyle(Color.inkMuted).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.inkFaint)
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground()
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// FIT-204, FIT-367: the day's check-in for the coach (weight, sleep and a note) as one row under the day, saying
    /// what it said once there is one. Any day up to today (FIT-345).
    private func checkInRow(_ day: Date) -> some View {
        let rows = entries.filter { ($0.kind == .bodyweight || $0.kind == .sleep) && Calendar.current.isDate($0.timestamp, inSameDayAs: day) }
        let values = CheckIn.values(rows)
        let said = [CheckIn.summary(rows), values.note.isEmpty ? nil : "“\(values.note)”"].compactMap { $0 }.joined(separator: " · ")
        return Button { checkingIn = CheckInDay(day: day) } label: {
            HStack(spacing: 14) {
                if !typeSize.isAccessibilitySize {
                    Image(systemName: said.isEmpty ? "plus.circle" : "checkmark.circle.fill").font(.title3)
                        .foregroundStyle(said.isEmpty ? Plate.current.mark : Color.good).frame(width: 28)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(said.isEmpty ? "Check in" : "Checked in").font(.headline)
                    if !typeSize.isAccessibilitySize || !said.isEmpty {
                        Text(said.isEmpty ? "Weight, sleep or a note for \(pro.coaches.first?.name ?? "your coach")" : said)
                            .font(.subheadline).foregroundStyle(Color.inkMuted).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.inkFaint)
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground()
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// "Today", "Tomorrow", then the weekday.
    static func dayName(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInTomorrow(day) { return "Tomorrow" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        // FIT-332: outside this week a weekday alone is ambiguous: "Mon, Nov 3".
        if Week.start(of: day) != Week.start(of: .now) { return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) }
        return day.formatted(.dateTime.weekday(.wide))
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

    /// FIT-325: the ready-made program they follow, once it's past its last week.
    private var finishedProgram: ReadyProgram? {
        guard let profile = profiles.first, let ready = ReadyProgram.named(profile.programSlug), let start = profile.programStart,
              ready.isFinished(started: start, on: .now) else { return nil }
        return ready
    }

    /// The next program, from today, on their days where it runs on that many, with their equipment and starting sets.
    private func startNext(after done: ReadyProgram) {
        guard let profile = profiles.first else { return }
        let next = done.following(days: profile.trainingDays.count)
        let days = next.days.contains(profile.trainingDays.count) ? profile.trainingDays : ReadyProgram.days(for: next.days(nearest: profile.trainingDays.count))
        do {
            try Planner.start(next, days: days, equipment: profile.equipment, profile: profile, in: context)
        } catch {
            message = "Couldn’t start the program. Try again."
        }
    }

    private func weekReport() -> WeekReport {
        WeekReport.make(profile: profiles.first, goals: goals, entries: entries, planned: planned, templates: templates)
    }

    @ViewBuilder private func dayContent(_ card: DayCard, day: Date, isToday: Bool, isPast: Bool) -> some View {
        switch card {
        // FIT-74: the week standing in until the coach's arrives isn't shown as if it were the plan.
        case .plan where planning:
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Your coach is planning this week").font(.headline)
                Text("Usually under a minute.").font(.subheadline).foregroundStyle(Color.inkMuted)
            }
            .frame(maxWidth: .infinity).padding(.top, 80)
        case .plan(let plan) where isPast:
            // A past session with nothing logged against it says so; the footer logs it on its own day.
            VStack(alignment: .leading, spacing: 12) {
                Label("Not logged", systemImage: "circle.dashed").font(.headline).foregroundStyle(Color.inkMuted).padding(.top, 16)
                planView(plan, isToday: false)
            }
        case .plan(let plan): planView(plan, isToday: isToday)
        case .done(let done): doneCard(done)
        // FIT-332: a later week nobody has planned yet isn't seven rest days.
        case .rest where notPlannedYet(day):
            VStack(alignment: .leading, spacing: 8) {
                Text("Not planned yet").font(.display(28))
                Text(pro.coaches.isEmpty ? "This week is planned when it comes." : "Your coach plans this week before it starts.")
                    .foregroundStyle(Color.inkMuted)
            }
        // FIT-201, FIT-427: a coach's client with nothing planned from this week on is waiting on the coach, not resting:
        // it says who, and a message to them is a tap away. The app plans nothing over a coach's weeks.
        case .rest where awaitingCoach:
            let coach = pro.coaches.first
            VStack(alignment: .leading, spacing: 8) {
                Text("\(coach?.title ?? "Your coach") hasn’t written \(planned.contains { $0.kind == .workout } ? "this week" : "your first week") yet")
                    .font(.display(28))
                Text("It shows up here as soon as it’s ready.").foregroundStyle(Color.inkMuted)
                Button { conversing = true } label: { Label("Message \(coach?.name ?? "your coach")", systemImage: "bubble.left") }
                    .buttonStyle(.secondary)
                    .padding(.top, 8)
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
            // The lifts are the session; only a run, with no list to show, gets a title (author, 2026-10-30).
            if lifts.isEmpty {
                // The card adds only 4 pt, expecting a row's own 16 above: the title brings that 16 itself (FIT-368).
                Text(plan.title).font(.display(30)).fixedSize(horizontal: false, vertical: true).padding(.top, 16).padding(.bottom, 10)
            }
            // FIT-377: the coach's note on the session, over it.
            if let note = PlannedActivity.sessionNote(plan.items) {
                SessionNote(text: note, by: pro.coaches.first?.name ?? "Your coach").padding(.top, 16)
            }
            // A later day is read-only: its week may be replanned before it starts, which would undo a change made now.
            SessionList(session: plan.session, names: names, previous: previousLoads,
                        checked: lifts.isEmpty || !isToday ? nil : $checked,
                        onLoad: isToday ? { exercise, step in changeLoad(exercise, by: step, in: plan.items) } : nil,
                        onEdit: isToday ? { edited($0, over: plan.items) } : nil, history: true)
            ForEach(plan.ran) { run in RunRow(run: run) { sheet = .ran(run) }.padding(.top, 16) }
        }
    }

    /// FIT-297: Start, then Change and Log side by side; a checked-off session's Save bar in their place.
    @ViewBuilder private func actions(_ card: DayCard, week cards: [DayCard]) -> some View {
        VStack(spacing: 8) {
            switch card {
            case .plan(let plan) where !planning:
                if !checked.isEmpty {
                    Button { sheet = .feel(plan) } label: {
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
                    // A planned run comes first: run mode tracks it and saves it to Apple Health. Lifts beside it are checked off or started below.
                    if plan.ran.isEmpty, let run = runs(plan.items).first {
                        startRun(run)
                        if !lifting(plan.items).isEmpty { secondary("Start the lifts", "play.fill") { start(plan) } }
                        pair("Move", "calendar", { sheet = .move }, "Log", "plus", { sheet = .logChoice(plan.items) })
                    } else {
                        // Simplicity pass: one button; Move and Log behind the ⋯ beside it.
                        HStack(spacing: 8) {
                            Button { start(plan) } label: { Label("Start", systemImage: "play.fill") }.buttonStyle(.primary)
                            Menu {
                                Button("Log It Without Starting", systemImage: "plus") { sheet = .logChoice(plan.items) }
                                Button("Move to Another Day", systemImage: "calendar") { sheet = .move }
                            } label: {
                                Image(systemName: "ellipsis").font(.title3.weight(.semibold)).foregroundStyle(Color.ink)
                                    .frame(width: 56, height: 56).background(Color.surface, in: .rect(cornerRadius: 18))
                            }
                            .accessibilityLabel("More")
                        }
                    }
                }
            case .done(let done):
                if let run = done.pendingRun { startRun(run) }
                pair("Edit the sets", "square.and.pencil", { if let run = done.run { sheet = .ran(run) } else { sheet = .record(done.planned, done.start) } },
                     "Log", "plus", { sheet = .logChoice([]) })
            default:
                // FIT-235: the next session this week pulled to today.
                if let next = nextPlanned(cards) {
                    pair("Train today", "arrow.uturn.left", { doToday(next) }, "Log", "plus", { sheet = .logChoice([]) })
                } else {
                    pair(nil, nil, nil, "Log a workout", "plus", { sheet = .logChoice([]) })
                }
            }
        }
    }

    /// One day: the session (scrolling on its own when it's long), then that day's actions, the only footer.
    private func page(_ card: DayCard, day: Date, index: Int, week weekCards: [DayCard], todayPlan: DayCard.Planned?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // FIT-8: the week's review is the first thing on its last day.
                    if isToday(index), WeekReport.isDue() {
                        let report = weekReport()
                        WeekReviewCard(report: report) { review = report }
                    }
                    if isToday(index), !pro.coaches.isEmpty, weeklyDue { weeklyCard }
                    if isToday(index), let done = finishedProgram {
                        ProgramDoneCard(finished: done, next: done.following(days: profiles.first?.trainingDays.count ?? 3),
                                        recap: { review = weekReport() }, start: { startNext(after: done) }, pick: { picking = true })
                    }
                    // A session's rows bring their own 16 pt above and below, so its card adds only 4: the text sits
                    // 20 pt from every edge, as on the other cards.
                    dayContent(card, day: day, isToday: isToday(index), isPast: isPast(day))
                        .padding(.horizontal, 20).padding(.vertical, Self.isList(card) && !planning ? 4 : 20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardBackground()
                    if !pro.coaches.isEmpty, day <= Calendar.current.startOfDay(for: .now) { checkInRow(day) }
                }
                .padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
            // FIT-367: the actions as the page's bottom bar, so a long session scrolls under them with the system's
            // soft edge rather than stopping at a hard line.
            .safeAreaBar(edge: .bottom) {
                Group {
                    // Another day this week, earlier or later: its session can be moved to today, or swapped with
                    // today's. A later week's waits for its week (FIT-332): its plan may change before then.
                    if isToday(index) { actions(card, week: weekCards) }
                    else if isPast(day) { pastActions(card, day: day) }
                    else if isThisWeek { laterActions(card, todayPlan: todayPlan) }
                }
                .padding(.horizontal, 20).padding(.bottom, 16)
            }
            // FIT-367: a scrolled session stays inside its page, under the strip, not drawn through its dots.
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A later day: train its session now (FIT-235). It becomes today's, and a session waiting today takes its day.
    @ViewBuilder private func laterActions(_ card: DayCard, todayPlan: DayCard.Planned?) -> some View {
        if case .plan(let plan) = card, !planning {
            // FIT-302: no editor here; Today already lists the day's lifts.
            trainToday(icon: todayPlan == nil ? "arrow.uturn.left" : "arrow.left.arrow.right") { doToday(plan, swapping: todayPlan); start(plan) }
        }
    }

    /// Another day's session, started now: a small link under the card, quieter than the day's own actions. Its icon
    /// says what happens to the plan: back to today, or a swap with today's; a missed day moves nothing, so has none.
    private func trainToday(icon: String? = nil, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon) }
                Text("Train this today")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Plate.current.mark).frame(maxWidth: .infinity).padding(.vertical, 8).contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// A card that's a session's list of rows, not a message or a summary.
    static func isList(_ card: DayCard) -> Bool {
        if case .plan = card { true } else { false }
    }

    static func isDone(_ card: DayCard) -> Bool {
        if case .done = card { true } else { false }
    }

    /// An earlier day this week: its session logged on that day, or anything else logged there; a logged day's sets
    /// can still be corrected.
    private func pastActions(_ card: DayCard, day: Date) -> some View {
        VStack(spacing: 8) {
        switch card {
        case .plan(let plan) where !planning:
            let lifts = lifting(plan.items)
            Button { sheet = lifts.isEmpty ? .run(plan.items.first) : .log(plan.items) } label: {
                Label("Log it", systemImage: "checkmark")
            }
            .buttonStyle(.primary)
            // A missed day is trained today as it is: nothing moves, and the day stays unlogged.
            trainToday { start(plan) }
        case .done(let done):
            pair(nil, nil, nil, "Edit the sets", "square.and.pencil", { if let run = done.run { sheet = .ran(run) } else { sheet = .record(done.planned, done.start) } })
        case .rest:
            pair(nil, nil, nil, "Log a workout", "plus", { sheet = .ownOn(day) })
        default:
            EmptyView()
        }
        }
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
        Button(action: action) { Label(title, systemImage: icon) }.buttonStyle(.secondary)
    }

    /// FIT-302: today's session as changed by hand on Today, saved as it's made and pinned like any edit. A change to
    /// the lifts' order or number starts the check-offs again, since they're kept by position.
    private func edited(_ session: SessionPlan, over items: [PlannedActivity]) {
        let before = Planner.session(items, templates: templates)
        _ = Planner.save(session, over: items, templates: templates, in: context)
        if before.blocks.map(\.movements.first?.exercise) != session.blocks.map(\.movements.first?.exercise) { checked = [] }
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
    /// FIT-378: with how it felt, as workout mode saves it: the session's effort and the RPE of its sets.
    private func saveChecked(_ plan: DayCard.Planned, feel: Feel?) {
        var draft = WorkoutDraft(session: plan.title, plan: plan.session)
        for index in draft.rows.indices where checked.contains(draft.rows[index].block) { draft.rows[index].done = true }
        draft.feel = feel
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
                    .background(Color.surface, in: .capsule)
            }
            if let run { runButton("Start the run", run) } else { runButton("Start a run", nil) }
        }
        .buttonStyle(.plain)
    }

    private func startRun(_ planned: PlannedActivity) -> some View {
        Button { tracking = RunTarget(planned: planned) } label: { Label("Start the run", systemImage: "figure.run") }
            .buttonStyle(.primary)
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
                .background(Color.surface, in: .capsule)
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
                RouteMap(points: route).frame(height: 170).clipShape(.rect(cornerRadius: 18)).padding(.top, 18)
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
            ForEach(done.ran) { run in RunRow(run: run) { sheet = .ran(run) }.padding(.top, 16) }
            Text(done.coach).font(.body).lineSpacing(2).padding(.top, 26).fixedSize(horizontal: false, vertical: true)
            // How it went, added or changed any time after; a tap on the note edits it.
            if let summary = done.summary {
                Button { sheet = .note(summary, done.note) } label: {
                    if done.note.isEmpty {
                        Label("Add a note", systemImage: "square.and.pencil").font(.subheadline.weight(.semibold)).foregroundStyle(Plate.current.mark)
                    } else {
                        Text("“\(done.note)”").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    }
                }
                .buttonStyle(.plain).padding(.top, 12)
            } else if !done.note.isEmpty {
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
        .onTapGesture { if let run = done.run { sheet = .ran(run) } else { sheet = .record(done.planned, done.start) } }
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
    /// The coach sees it on today, and Undo puts it back. Today's own session, if one is waiting, takes the other's day.
    private func doToday(_ plan: DayCard.Planned, swapping todays: DayCard.Planned? = nil) {
        let calendar = Calendar.current
        let moving = plan.items + (todays?.items ?? [])
        let was = moving.map { ($0, $0.date) }
        let today = calendar.startOfDay(for: .now)
        let other = calendar.startOfDay(for: plan.start)
        func move(_ items: [PlannedActivity], to day: Date) {
            for item in items {
                item.date = day + item.date.timeIntervalSince(calendar.startOfDay(for: item.date))
                item.updatedAt = .now
            }
        }
        move(plan.items, to: today)
        if let todays { move(todays.items, to: other) }
        try? context.save()
        let from = plan.start.formatted(.dateTime.weekday(.wide))
        withAnimation(.settle) {
            goToday()
            toast = Toast(text: todays == nil ? "\(from)’s session is today" : "Swapped with \(from)") { [context] in
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
            try withAnimation(.settle) {
                fresh.formUnion(Set(rows.map(\.exercise)).subtracting(shown))
                try Planner.apply((others + rows).sorted { $0.date < $1.date }, to: plan, templates: base + added.templates, in: context)
            }
        }
        func restore() {
            withAnimation(.settle) {
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
            withAnimation(.reveal) { fresh = [] }
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
        case .record(let items, let day): NavigationStack { SessionRecordView(planned: items, day: day) }
        case .ran(let entry): NavigationStack { RunDetailView(run: entry) }
        case .note(let entry, let note): NavigationStack { WorkoutNoteSheet(summary: entry, note: note) }
        case .feel(let plan):
            FeelSheet { feel in
                self.sheet = nil
                saveChecked(plan, feel: feel)
            }
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
        case .move:
            MoveSheet { weekday in after { propose(.move(weekday: weekday), said: "") } }
        case .logChoice(let items):
            LogChoiceSheet(hasToday: !lifting(items).isEmpty) { choice in
                after {
                    switch choice {
                    case .today: self.sheet = .log(items)
                    case .other: self.sheet = .ownOn(.now)
                    case .track: self.tracking = RunTarget(planned: nil)
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
