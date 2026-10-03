import SwiftUI
import SwiftData

/// Onboarding (FIT-38, prototype boards 1–5): four questions, one per card, swiped through with the mic in the
/// middle; the last swipe shows the program to check and start. What's heard fills the card on screen, dashed.
struct OnboardingView: View {
    @Environment(\.modelContext) private var context
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
    var onDone: () -> Void

    private static let steps = [
        ("What are you training for?", "Say it in your own words, or pick."),
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
                                           history: history, go: { index in withAnimation(.snappy) { page = index } })
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
                .background(Color(.systemBackground))
            }
            footer
        }
        .background(Color(.systemBackground))
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
    }

    private static let prompts = ["“Get to 180 and do 10 pull-ups by the end of February”",
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
            Button(ready ? "Start program" : "Add your age and weight") {
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
        if profile.isComplete {
            answers.age = profile.age
            answers.weight = profile.weightLb
            answers.days = profile.trainingDays.sorted()
            answers.minutes = [30, 45, 60, 75].min { abs($0 - profile.sessionMinutes) < abs($1 - profile.sessionMinutes) }!
            answers.equipment = Set(profile.equipment)
            answers.avoid = Set(profile.avoidExercises)
            answers.hurts = Set(profile.injuredAreas.map { $0.replacingOccurrences(of: "_", with: " ") })
        }
        for option in GoalOption.all {
            guard let goal = goals.first(where: { $0.metric == option.metric && $0.status == .active }) else { continue }
            answers.goals.append(option.id)
            answers.targets[option.id] = goal.target
        }
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
        let monday = Week.monday(of: now)
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
        try? Planner.generate(weekOf: now, in: context)
        onDone()
    }
}
