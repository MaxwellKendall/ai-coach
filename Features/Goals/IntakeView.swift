import SwiftUI
import SwiftData

/// FIT-219: right after joining a coach, onboarding's four questions, one screen each and each skippable, saved into
/// the profile and goals the coach and their Claude read. No program is made; the coach writes it.
struct IntakeView: View {
    @Environment(\.modelContext) private var context
    @Query private var profiles: [Profile]
    @Query private var goals: [Goal]
    @Query private var templates: [Template]
    @Query(sort: \LogEntry.timestamp) private var entries: [LogEntry]
    var onDone: () -> Void

    @State private var answers = OnboardingAnswers()
    @State private var page = 0
    @State private var open: String?
    @State private var loads: [String: Double] = [:]
    @State private var prefilled = false

    private static let steps = [
        ("What are you training for, and by when?", "Your coach plans toward these."),
        ("What can you train with?", "Untick anything you never want to do."),
        ("Where are you starting?", "Your age, weight and a recent heavy set. Skip any you don’t know."),
        ("When can you train?", "Days, how long, and anything that hurts."),
    ]

    private var catalog: [Exercise] { Planner.catalog(templates) }
    private var names: [String: String] { Dictionary(templates.map { ($0.slug, $0.name) }, uniquingKeysWith: { first, _ in first }) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(page + 1) of \(Self.steps.count) · for your coach")
                            .font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        Text(Self.steps[page].0).font(.system(size: 30, weight: .bold)).tracking(-0.4)
                        Text(Self.steps[page].1).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.top, 18)
                    .padding(.bottom, 14)
                    OnboardingStepView(index: page, answers: $answers, open: $open, catalog: catalog, names: names,
                                       history: Planner.loggedSets(entries, templates: templates), loads: $loads, forCoach: true,
                                       go: { index in withAnimation(.snappy) { page = index } })
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 24)
                .id(page)
            }
            .scrollIndicators(.hidden)
            HStack(spacing: 12) {
                Button(page == 0 ? "Skip All" : "Back") {
                    if page == 0 { onDone() } else { withAnimation(.snappy) { page -= 1; open = nil } }
                }
                .frame(maxWidth: .infinity, minHeight: 54)
                Button(page == Self.steps.count - 1 ? "Done" : "Next") { next() }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .foregroundStyle(Color(.systemBackground))
                    .background(Color.primary, in: .capsule)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
        }
        .screenBackground()
        .onAppear(perform: prefill)
    }

    private func next() {
        save()
        if page == Self.steps.count - 1 { onDone() } else { withAnimation(.snappy) { page += 1; open = nil } }
    }

    /// What the account already has, set on another phone or by the coach.
    private func prefill() {
        guard !prefilled, let profile = profiles.first else { return }
        prefilled = true
        if profile.isComplete { answers = OnboardingAnswers(profile, goals: goals) } else { answers.add(goals) }
    }

    /// Saved after each screen, so leaving partway keeps what was answered.
    private func save() {
        guard let profile = profiles.first else { return }
        Intake.save(answers, to: profile, goals: goals, in: context)
    }
}

/// FIT-219: onboarding's answers into the profile and goals. Onboarding adds the program; the intake doesn't.
@MainActor
enum Intake {
    static func save(_ answers: OnboardingAnswers, to profile: Profile, goals: [Goal], deadline: Date? = nil,
                     in context: ModelContext, now: Date = .now) {
        let deadline = deadline ?? Calendar.current.date(byAdding: .day, value: 7 * answers.weeks - 1, to: Week.start(of: now))
        if let age = answers.age { profile.age = age }
        if let weight = answers.weight { profile.weightLb = weight }
        profile.trainingDays = answers.days.sorted()
        profile.sessionMinutes = answers.minutes
        profile.equipment = Profile.allEquipment.filter(answers.equipment.contains)
        profile.avoidExercises = answers.avoid.sorted()
        profile.injuredAreas = answers.hurts.sorted()
        // A starting set suggested and never touched isn't one they said.
        profile.starts = answers.starts.filter { !answers.unconfirmed.contains("start.\($0.key)") }.values
            .sorted { $0.exercise < $1.exercise }
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
            goal.deadline = deadline
            goal.updatedAt = now
        }
        try? context.save()
    }
}
