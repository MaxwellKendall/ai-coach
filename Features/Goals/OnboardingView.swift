import SwiftUI
import SwiftData

/// Onboarding (FIT-38, prototype boards 1–5): four questions, one per card, swiped through with the mic in the
/// middle; the last swipe shows the program to check and start. What's heard fills the card on screen, dashed.
struct OnboardingView: View {
    @Environment(\.modelContext) private var context
    /// FIT-102: signed in, program design uses Claude through our server.
    @Environment(Account.self) private var account
    /// FIT-120: starting the program is the offer, unless Pro already is.
    @Environment(Pro.self) private var pro
    @Bindable var profile: Profile
    @Query private var templates: [Template]
    @Query private var goals: [Goal]
    @Query(sort: \LogEntry.timestamp) private var entries: [LogEntry]
    @State private var answers = OnboardingAnswers()
    @State private var prefilled = false
    @State private var page = 0
    @State private var open: String?
    @State private var voice = VoiceCapture()
    @State private var working: String?
    @State private var message: String?
    /// FIT-73: the first week the model designed from these answers, and the loads the user changed on it.
    @State private var firstWeek: ProgramDesigner.Result?
    /// FIT-95: the program brief written with week 1, and the model that wrote it.
    @State private var brief: ProgramBrief?
    @State private var briefModel = OnDeviceModel().name
    @State private var designing = false
    /// The first week's design under way, and the answers it's from. Start hands an unfinished one to Today (FIT-38).
    @State private var design: (key: String, task: Task<FirstWeekDesign?, Never>)?
    @State private var loads: [String: Double] = [:]
    /// FIT-109: an invite pasted after installing from its page (iOS loses the link through the App Store).
    @State private var invite: Invite?
    @State private var signingInToJoin = false
    @State private var pendingInvite: String?
    @State private var joined: Cloud.GroupSummary?
    @State private var sessionWaiting = false
    /// Signed out at the check step: sign in first, so Claude designs the program (author, 2026-10-12, FIT-102).
    @State private var signingInForCoach = false
    @State private var askedSignIn = false
    /// A number being typed: the mic and its hint step aside for the keyboard.
    @State private var keyboard = false
    var onDone: () -> Void

    private static let steps = [
        ("What do you want to lift, and by when?", "Say it in your own words, or pick."),
        ("What will you train with?", "Untick anything you never want to see."),
        ("Where are you starting?", "Built from your goals and exercises. Skip any you don’t know; week 1 finds it."),
        ("When can you train?", "Days, how long, and anything to be careful with."),
    ]

    private var catalog: [Exercise] { Planner.catalog(templates) }
    private var names: [String: String] { Dictionary(templates.map { ($0.slug, $0.name) }, uniquingKeysWith: { first, _ in first }) }

    var body: some View {
        VStack(spacing: 0) {
            dots
            SwipeDeck(index: Binding(get: { page }, set: { page = $0; open = nil }), count: 5, cornerRadius: 0,
                      hint: { index, swipe in
                          swipe == .next ? SwipeHint(index == 3 ? "Check the program" : "Next")
                              : swipe == .back ? SwipeHint("Back") : nil
                      }) { index in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if index < 4 { header(index) }
                        OnboardingStepView(index: index, answers: $answers, open: $open, catalog: catalog, names: names,
                                           history: history, firstLoads: firstWeek.map { FirstLoads.items($0.week.workouts) },
                                           designing: designing, brief: brief, loads: $loads,
                                           go: { index in withAnimation(.snappy) { page = index } })
                        if index == 0, account.isAvailable { inviteRow.padding(.top, 28) }
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
                .background(Color(.systemBackground))
            }
            if !keyboard { footer }
        }
        .background(Color(.systemBackground))
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboard = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboard = false }
        .overlay {
            if voice.listening || working != nil {
                ListeningVeil(voice: voice, working: working, prompt: Self.prompts[min(page, 3)])
            }
        }
        .animation(.snappy, value: voice.listening || working != nil)
        .alert("Couldn’t do that", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: { Text(message ?? "") }
        .onChange(of: voice.problem) { _, problem in if let problem { message = problem } }
        .onAppear(perform: prefill)
        .sheet(isPresented: $signingInToJoin, onDismiss: {
            if account.user != nil, let code = pendingInvite { invite = Invite(code: code) }
            pendingInvite = nil
        }) {
            SignInSheet(reason: "Sign in to join the group.")
        }
        .sheet(item: $invite) { invite in
            NavigationStack {
                JoinGroupSheet(code: invite.code) { group in
                    withAnimation(.snappy) { joined = group }
                    self.invite = nil
                }
            }
        }
        // The check step designs the first week, again whenever the answers it's built from change.
        .onChange(of: page == 4 ? designKey : nil, initial: true) { _, key in
            guard let key else { return }
            if account.isAvailable, account.user == nil, !askedSignIn {
                askedSignIn = true
                signingInForCoach = true
            } else if !signingInForCoach {
                startDesign(key)
            }
        }
        // Signed in or not, the design starts once the sheet goes.
        .sheet(isPresented: $signingInForCoach, onDismiss: { if page == 4 { startDesign(designKey) } }) {
            SignInSheet(reason: "Sign in so your coach can design your program.")
        }
        .onChange(of: answers.goals) { answers.estimateStarts() }
        .onChange(of: answers.targets) { answers.estimateStarts() }
    }

    /// FIT-109: one quiet line, for someone who came from a friend's invite. Apple's paste button reads the
    /// clipboard only when tapped, so there's no permission prompt.
    @ViewBuilder private var inviteRow: some View {
        if let joined {
            Label("You’re in \(joined.name)", systemImage: "person.2.fill")
                .font(.subheadline.weight(.semibold))
        } else if sessionWaiting {
            Label("Your friend’s plan comes up once you’re set up", systemImage: "calendar.badge.checkmark")
                .font(.subheadline.weight(.semibold))
        } else {
            HStack {
                Text("Invited by a friend?").foregroundStyle(.secondary)
                Spacer()
                PasteButton(payloadType: String.self) { pasted in
                    Task { @MainActor in pasteInvite(pasted) }
                }
                .buttonBorderShape(.capsule)
                .tint(.primary)
            }
            .font(.subheadline)
        }
    }

    private func pasteInvite(_ pasted: [String]) {
        // FIT-113: a friend's session; it's offered once onboarding is done.
        if let session = pasted.lazy.compactMap(InviteLink.session(pasted:)).first {
            Navigator.shared.session = session
            withAnimation(.snappy) { sessionWaiting = true }
            return
        }
        // FIT-111: a friend's program; it's offered once onboarding is done.
        if let program = pasted.lazy.compactMap(InviteLink.program(pasted:)).first {
            Navigator.shared.program = program
            withAnimation(.snappy) { sessionWaiting = true }
            return
        }
        guard let code = pasted.lazy.compactMap(InviteLink.code(pasted:)).first else {
            message = "That isn’t an invite. Copy the link or the code from your invite, then paste again."
            return
        }
        if account.user == nil {
            pendingInvite = code
            signingInToJoin = true
        } else {
            invite = Invite(code: code)
        }
    }

    /// What the first week is designed from.
    private var designKey: String {
        [answers.goals.joined(separator: ","), answers.targets.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","),
         "\(answers.weeks)", answers.equipment.sorted().joined(separator: ","), answers.avoid.sorted().joined(separator: ","),
         "\(answers.age ?? 0)", "\(answers.weight ?? 0)", answers.starts.values.map { "\($0)" }.sorted().joined(),
         "\(answers.days)", "\(answers.minutes)", answers.hurts.sorted().joined(separator: ","),
         // Signing in changes the model that designs it.
         "\(account.user != nil)"].joined(separator: "|")
    }

    typealias FirstWeekDesign = (brief: ProgramBrief?, model: String, result: ProgramDesigner.Result)

    /// A design for these answers, unless one is under way for them; one for older answers is cancelled. Not tied to
    /// the view, so Start can hand it on.
    private func startDesign(_ key: String) {
        guard design?.key != key else { return }
        design?.task.cancel()
        let task = Task { await designFirstWeek() }
        design = (key, task)
        designing = true
        Task {
            let done = await task.value
            guard design?.key == key else { return }
            designing = false
            guard let done else { return }
            withAnimation(.snappy) {
                firstWeek = done.result.source == .model ? done.result : nil
                // Loads the user set stay for the exercises still in the week.
                let kept = Set(done.result.week.workouts.map(\.exercise))
                loads = loads.filter { kept.contains($0.key) }
            }
        }
    }

    private func designFirstWeek() async -> FirstWeekDesign? {
        let model = LanguageModel.programs(signedIn: account.user != nil)
        guard model.isAvailable, let settings = answers.trainingSettings(workoutTime: profile.workoutTime,
                                                                                 maxWeeklySets: profile.maxWeeklySets) else { return nil }
        let monday = Week.start(of: .now)
        let weeks = ProgramPlan.weeks(count: answers.weeks, deloadEvery: AgeTier.of(age: settings.age).deloadEveryWeeks)
        let end = Calendar.current.date(byAdding: .day, value: 7 * answers.weeks - 1, to: monday)!
        let goals = answers.goalLines(by: end)
        let lifts = answers.goals.compactMap(GoalOption.with(id:)).compactMap { option -> GoalLift? in
            guard let exercise = option.exercise, let measure = option.metric.split(separator: ".").last,
                  let start = answers.baseline(option), let target = answers.target(option) else { return nil }
            return GoalLift(exercise: exercise, measure: String(measure), start: start, target: target, deadline: end)
        }
        // FIT-95: the program's plan first, then week 1 within it.
        let brief = await ProgramBrief.write(ProgramBrief.Request(settings: settings, catalog: catalog, names: names, goals: goals,
                                                                  goalLifts: lifts, weeks: weeks), model: model)
        guard !Task.isCancelled else { return nil }
        self.brief = brief
        briefModel = model.name
        let request = ProgramDesigner.Request(
            monday: monday, settings: settings, catalog: catalog, names: names, history: history, weeksSinceDeload: 0,
            program: weeks.first, programIndex: 0, programWeeks: weeks.count, goals: goals,
            brief: weeks.first.flatMap { brief?.phase($0.phase) }, goalLifts: lifts, programPlan: weeks)
        let result = await ProgramDesigner.week(request, model: model)
        guard !Task.isCancelled else { return nil }
        return (brief, model.name, result)
    }

    private static let prompts = ["“Squat 225 and bench 185 by the end of June”",
                                  "“No barbell. I like push-ups”",
                                  "“I’m 36, 200 pounds, and I squat 155 for 5”",
                                  "“Monday, Wednesday, Friday, 45 minutes. My knee gets cranky”"]

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { index in
                Button { withAnimation(.snappy) { page = index } } label: {
                    Capsule().fill(index <= page ? Color.primary : Color(.separator)).frame(height: 4)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Step \(index + 1) of 4")
            }
        }
        .padding(.horizontal, 22)
    }

    private func header(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.steps[index].0).font(.system(size: 30, weight: .bold)).tracking(-0.4)
            Text(Self.steps[index].1).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    @ViewBuilder private var footer: some View {
        if page == 4 {
            let ready = answers.age != nil && answers.weight != nil && !answers.days.isEmpty
            Button(!ready ? "Add your age and weight" : pro.active ? "Start program" : ProOfferBar.title(trialEligible: pro.trialEligible)) {
                if ready { start() } else { withAnimation(.snappy) { page = 2; open = answers.age == nil ? "age" : "weight" } }
            }
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 54)
            .foregroundStyle(Color(.systemBackground))
            .background(Color.primary, in: .capsule)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
        } else {
            VStack(spacing: 10) {
                if LanguageModel.isAvailable { MicButton(voice: voice, onHeard: heard) }
                Text((LanguageModel.isAvailable ? "Hold and say it · " : "") + (page == 3 ? "swipe to build the program" : "swipe for next"))
                    .font(.footnote).foregroundStyle(.tertiary)
                    .opacity(voice.listening ? 0 : 1)
            }
            .padding(.top, 12)
            .padding(.bottom, 6)
        }
    }

    private var history: [LoggedSet] { Planner.loggedSets(entries, templates: templates) }

    private func heard(_ said: String) {
        guard let step = OnboardingStep(rawValue: page) else { return }
        working = said
        Task {
            defer { working = nil }
            var copy = answers
            do {
                try await OnboardingSpeech.hear(said, on: step, into: &copy, catalog: catalog, names: names)
                withAnimation(.snappy) { answers = copy }
            } catch {
                message = "Couldn’t understand that. Try again, or tap to pick."
            }
        }
    }

    // MARK: Prefill and save

    /// What the app already knows: settings, goals that match, and the best recent set of each exercise.
    private func prefill() {
        guard !prefilled else { return }
        prefilled = true
        var answers = OnboardingAnswers()
        if profile.isComplete { answers = OnboardingAnswers(profile, goals: goals) } else { answers.add(goals) }
        // Starting points come from the logs, to confirm.
        answers.starts = [:]
        let now = Date.now
        for exercise in catalog {
            guard let best = OnboardingAnswers.recentBest(history, exercise: exercise, before: now) else { continue }
            answers.starts[exercise.slug] = best
            answers.unconfirmed.insert("start.\(exercise.slug)")
        }
        self.answers = answers
    }

    private func start() {
        guard let age = answers.age, let weight = answers.weight else { return }
        let now = Date.now
        let monday = Week.start(of: now)
        profile.age = age
        profile.weightLb = weight
        profile.trainingDays = answers.days.sorted()
        profile.sessionMinutes = answers.minutes
        profile.equipment = Profile.allEquipment.filter(answers.equipment.contains)
        profile.avoidExercises = answers.avoid.sorted()
        profile.injuredAreas = answers.hurts.sorted()
        profile.programStart = monday
        profile.targetDate = Calendar.current.date(byAdding: .day, value: 7 * answers.weeks - 1, to: monday)
        profile.travelWeeks = []
        profile.starts = answers.starts.values.sorted { $0.exercise < $1.exercise }
        profile.updatedAt = now
        for (index, option) in answers.goals.compactMap(GoalOption.with(id:)).enumerated() {
            guard let target = answers.target(option) else { continue }
            if option.id == "weight" { profile.targetWeightLb = target }
            let goal = goals.first { $0.metric == option.metric && $0.status == .active } ?? {
                let goal = Goal(kind: option.kind, metric: option.metric, target: target, unit: option.unit,
                                now: now + TimeInterval(index))
                context.insert(goal)
                return goal
            }()
            goal.target = target
            goal.baseline = answers.baseline(option)
            goal.deadline = profile.targetDate
            goal.updatedAt = now
        }
        try? context.save()
        // Kept under the key Planner reads it by, with the goals just saved, so it isn't written again.
        let saved = (try? context.fetch(FetchDescriptor<Goal>())) ?? []
        profile.brief = brief.map { brief in
            ProgramBrief.Stored(brief: brief, key: ProgramBrief.key(goals: Planner.goalLines(saved), settings: profile.trainingSettings,
                                                                    weeks: profile.program ?? []), model: briefModel)
        }
        try? context.save()
        if let plan = try? Planner.generate(weekOf: now, in: context), let firstWeek {
            // FIT-73: the week the model designed, at the loads the user confirmed.
            try? Planner.apply(FirstLoads.applying(loads, to: firstWeek.week.workouts), to: plan, templates: templates, in: context)
            plan.warnings = firstWeek.week.warnings
            plan.designedBy = firstWeek.source.rawValue
            try? context.save()
        } else if designing, let task = design?.task {
            // Started before the design came back: it lands on Today's week when it does, not thrown away.
            // Marked now, so Today, appearing next, doesn't start a design of its own.
            Planner.designing.weeks.insert(Week.start(of: now))
            let model = LanguageModel.programs(signedIn: account.user != nil)
            Task { await Planner.finishFirstWeek(task, in: context, model: model) }
        }
        onDone()
    }
}

extension OnboardingAnswers {
    /// The answers a profile and its goals were started from, for editing them again.
    init(_ profile: Profile, goals: [Goal]) {
        self.init()
        age = profile.age
        weight = profile.weightLb
        days = profile.trainingDays.sorted()
        minutes = [30, 45, 60, 75].min { abs($0 - profile.sessionMinutes) < abs($1 - profile.sessionMinutes) }!
        equipment = Set(profile.equipment)
        avoid = Set(profile.avoidExercises)
        hurts = Set(profile.injuredAreas.map { $0.replacingOccurrences(of: "_", with: " ") })
        starts = Dictionary(profile.starts.map { ($0.exercise, $0) }, uniquingKeysWith: { first, _ in first })
        add(goals)
    }

    /// Active goals that onboarding offers, with their targets.
    mutating func add(_ goals: [Goal]) {
        for option in GoalOption.all {
            guard let goal = goals.first(where: { $0.metric == option.metric && $0.status == .active }) else { continue }
            self.goals.append(option.id)
            targets[option.id] = goal.target
        }
    }
}
