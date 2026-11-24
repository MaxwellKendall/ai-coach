import SwiftUI
import SwiftData

/// FIT-454, FIT-455, FIT-456: the first launch for a lifter on their own, after AbMaxx's onboarding (spec: "Barbrabell
/// onboarding: AbMaxx-style hard paywall"). The goal first, quick one-tap questions, their first name, a strength check
/// that shows only the weakest lift, their plan, then Lifter Pro's hard paywall. No sign-in anywhere in it, and no
/// transition between questions: each tap opens the next one at once.
struct StartFlow: View {
    @Environment(\.modelContext) private var context
    @Query private var profiles: [Profile]
    @Query private var goals: [Goal]
    var onDone: () -> Void

    @State private var answers = StartAnswers()
    @State private var step: Step = .goal
    @State private var history: [Step] = []
    @State private var failure: String?

    enum Step: Int, CaseIterable {
        case goal, sex, chart, age, height, weight, days, body, activity, place, equipment, holdback, name
        case invite, steps, lifts, enter, analysis, results, setup, ready, paywall
    }

    /// The questions' progress bar runs to the name; the check and the plan have their own screens.
    private var progress: Double? {
        step.rawValue <= Step.name.rawValue ? Double(step.rawValue + 1) / Double(Step.name.rawValue + 1) : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if step != .paywall && step != .analysis && step != .setup && step != .ready { topBar }
            screen.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .screenBackground()
        .transaction { $0.animation = nil }
        .sensoryFeedback(.selection, trigger: step)
        // TKL-466: every screen, counted once per install on the server.
        .onChange(of: step, initial: true) { _, now in
            Funnel.track(.screenViewed, now.screen)
            if now == .results { Funnel.track(.resultsViewed) }
            if now == .ready { Funnel.track(.planReadyViewed) }
        }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Button { back() } label: {
                Image(systemName: "chevron.left").font(.body.weight(.semibold)).frame(width: 44, height: 44)
            }
            .tint(.primary)
            .opacity(history.isEmpty ? 0 : 1)
            .disabled(history.isEmpty)
            .accessibilityLabel("Back")
            .accessibilityIdentifier("start.back")
            if let progress {
                ProgressView(value: progress).tint(Plate.current.mark)
            } else {
                Spacer()
            }
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder private var screen: some View {
        switch step {
        case .goal:
            choices("What do you want to achieve?", StartAnswers.Goal.allCases, title: Self.goalTitle) { answers.goal = $0 }
        case .sex:
            choices("What’s your gender?", StrengthCheck.Sex.allCases, detail: "Only to compare your lifts with the right standards.",
                    title: { [.male: "Male", .female: "Female", .unspecified: "Prefer not to say"][$0]! }) { answers.sex = $0 }
        case .chart:
            ChartStep { next() }
        case .age:
            AgeStep(age: $answers.age) { next() }
        case .height:
            HeightStep(inches: $answers.heightIn, metric: $answers.metric) { next() }
        case .weight:
            WeightStep(pounds: $answers.weightLb, metric: $answers.metric) { next() }
        case .days:
            choices("How many days a week do you lift?", [2, 3, 4, 5, 6], title: { $0 == 6 ? "6+ days" : "\($0) days" }) { answers.days = $0 }
        case .body:
            choices("Which best describes you today?", StartAnswers.Body.allCases,
                    title: { [.slim: "Slim", .average: "Average", .athletic: "Athletic", .stocky: "Stocky"][$0]! }) { answers.body = $0 }
        case .activity:
            choices("How active are you outside the gym?", StartAnswers.Activity.allCases,
                    title: { [.low: "Not very active", .moderate: "Moderately active", .high: "Very active"][$0]! }) { answers.activity = $0 }
        case .place:
            choices("Where do you train?", StartAnswers.Place.allCases,
                    title: { [.commercial: "Commercial gym", .home: "Home gym", .both: "Both", .other: "Other"][$0]! }) { place in
                answers.place = place
                answers.equipment = StartAnswers.equipment(for: place)
            }
        case .equipment:
            EquipmentStep(have: $answers.equipment) { next() }
        case .holdback:
            choices("What’s holding you back?", StartAnswers.Holdback.allCases, title: Self.holdbackTitle) { answers.holdback = $0 }
        case .name:
            NameStep(name: $answers.name) { next() }
        case .invite:
            InviteStep(name: answers.firstName, start: {
                Funnel.track(.checkStarted)
                next()
            }, skip: { skipCheck() })
        case .steps:
            ThreeStepsStep(next: { next() }, skip: { skipCheck() })
        case .lifts:
            LiftsStep(picked: Binding(get: { Set(answers.lifts.map(\.slug)) }, set: { slugs in
                answers.lifts = StrengthCheck.lifts.map(\.slug).filter(slugs.contains).map { slug in
                    answers.lifts.first { $0.slug == slug } ?? StrengthCheck.Entry(slug: slug, weight: 0, reps: 0)
                }
            }), next: { next() }, skip: { skipCheck() })
        case .enter:
            EnterLiftsStep(entries: $answers.lifts, metric: answers.metric, next: { next() }, skip: { skipCheck() })
        case .analysis:
            AnalysisStep(name: answers.firstName, lifts: answers.lifts.map(\.slug)) { next() }
        case .results:
            if let result = answers.result() {
                ResultsStep(result: result) { next() }
            }
        case .setup:
            SetupStep(weakest: answers.result()?.weakest, failure: failure, work: setUp) { next() }
        case .ready:
            if let profile = profiles.first, let program = ReadyProgram.named(profile.programSlug) {
                PlanReadyStep(name: answers.firstName, program: program, days: profile.trainingDays.count,
                              weakest: answers.result()?.weakest) { next() }
            }
        case .paywall:
            StartPaywall(name: answers.firstName, onDone: onDone)
        }
    }

    // MARK: Moving between screens

    private func next() {
        guard let index = Step.allCases.firstIndex(of: step), index + 1 < Step.allCases.count else { return }
        // TKL-466: which question was answered, never the answer.
        Funnel.answer(step, name: answers.name)
        var upcoming = Step.allCases[index + 1]
        // Lifts left blank aren't scored; with none, there's nothing to show.
        if step == .enter {
            answers.lifts = answers.lifts.filter { $0.weight > 0 && $0.reps > 0 }
            if !answers.lifts.isEmpty { Funnel.track(.checkCompleted) }
        }
        if upcoming == .analysis && answers.lifts.isEmpty { upcoming = .setup }
        if upcoming == .results && answers.result() == nil { upcoming = .setup }
        go(upcoming)
    }

    /// Spec: Skip for now goes straight to setting up, with starting loads from the program.
    private func skipCheck() {
        Funnel.track(.checkSkipped, step.screen)
        answers.lifts = []
        go(.setup)
    }

    private func go(_ upcoming: Step) {
        // The check's in-between screens, and everything once the plan's made, can't be gone back to.
        if ![.analysis, .setup].contains(step) { history.append(step) }
        if upcoming == .setup || upcoming == .paywall { history = [] }
        step = upcoming
    }

    private func back() {
        guard let last = history.popLast() else { return }
        step = last
    }

    private func choices<Value: Hashable>(_ question: String, _ values: [Value], detail: String? = nil, title: @escaping (Value) -> String,
                                          set: @escaping (Value) -> Void) -> some View {
        StartQuestion(question, detail: detail) {
            ForEach(values, id: \.self) { value in
                StartOption(title(value)) {
                    set(value)
                    next()
                }
            }
        }
    }

    // MARK: Saving

    /// Screen 22: the profile, the program and a goal for the weakest lift. The paywall is owed from here on, even if
    /// the app's closed before it (RootView shows it again).
    private func setUp() throws {
        guard let profile = profiles.first, let pick = answers.program() else { throw StartFailure() }
        // Only hard mode owes the paywall; freemium's has Not Now.
        UserDefaults.standard.set(Monetization.current == .hard, forKey: StartFlow.needsProKey)
        UserDefaults.standard.set(answers.firstName, forKey: StartFlow.nameKey)
        UserDefaults.standard.set(try? JSONEncoder().encode(answers), forKey: "start.answers")
        profile.age = answers.age
        if let weight = answers.weightLb { profile.weightLb = weight }
        let starts = answers.lifts.filter { pick.program.recentLifts.contains($0.slug) }
            .map { StartingSet.recent($0.slug, weight: $0.weight, reps: $0.reps, perHand: false) }
        try Planner.start(pick.program, days: pick.days, equipment: ReadyProgram.equipment(answers.equipment), starts: starts,
                          profile: profile, in: context)
        // The weakest lift becomes a goal: about 10% on by the program's end, which AI-designed weeks work toward.
        if let result = answers.result(), let entry = answers.lifts.first(where: { $0.slug == result.weakest }) {
            let metric = "\(entry.slug).1rm_lb"
            if !goals.contains(where: { $0.metric == metric && $0.status == .active }) {
                let goal = Goal(kind: .training, metric: metric, target: TrainingGenerator.roundTo5(entry.estimatedMax * 1.1), unit: "lb",
                                deadline: profile.targetDate)
                goal.baseline = entry.estimatedMax.rounded()
                context.insert(goal)
                try context.save()
            }
        }
    }

    struct StartFailure: Error {}

    /// Set once the plan's made in hard mode: until Lifter Pro (or a coach), RootView keeps the paywall over the app.
    static let needsProKey = "start.needsPro"
    static let nameKey = "start.name"

    static func goalTitle(_ goal: StartAnswers.Goal) -> String {
        [.stronger: "Get stronger", .muscle: "Build muscle", .leaner: "Lose fat and keep my strength",
         .consistent: "Train more consistently", .comeback: "Come back after time off"][goal]!
    }

    static func holdbackTitle(_ holdback: StartAnswers.Holdback) -> String {
        [.noProgram: "I don’t have a program", .missSessions: "I miss sessions", .noProgress: "I don’t know if I’m getting stronger",
         .plateau: "I’ve plateaued", .unsure: "I’m not sure what to improve"][holdback]!
    }
}

/// TKL-466: the spec's stable screen ids, which the server's funnel keeps (shared/funnel.ts SCREENS).
extension StartFlow.Step {
    /// The screens that ask something (shared/funnel.ts QUESTIONS).
    var isQuestion: Bool {
        switch self {
        case .goal, .sex, .age, .height, .weight, .days, .body, .activity, .place, .equipment, .holdback, .name, .lifts, .enter: true
        default: false
        }
    }

    var screen: String {
        switch self {
        case .goal: "goal"
        case .sex: "gender"
        case .chart: "comparison_chart"
        case .age: "age"
        case .height: "height"
        case .weight: "weight"
        case .days: "frequency"
        case .body: "body_type"
        case .activity: "activity_level"
        case .place: "where_train"
        case .equipment: "equipment"
        case .holdback: "holding_back"
        case .name: "name"
        case .invite: "strength_invite"
        case .steps: "strength_steps"
        case .lifts: "select_lifts"
        case .enter: "enter_lifts"
        case .analysis: "analysis"
        case .results: "results"
        case .setup: "setup"
        case .ready: "plan_ready"
        case .paywall: "paywall"
        }
    }
}

// MARK: - Pieces every screen shares

/// A question: its title, then its answers or inputs, and a bottom bar when there is one.
struct StartQuestion<Content: View>: View {
    let question: String
    var detail: String?
    @ViewBuilder var content: Content

    init(_ question: String, detail: String? = nil, @ViewBuilder content: () -> Content) {
        self.question = question
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(question).font(.display(30)).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let detail {
                    Text(detail).font(.body).foregroundStyle(Color.inkMuted).padding(.top, 8)
                }
                VStack(spacing: 10) { content }.padding(.top, 28)
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.immediately)
    }
}

/// A one-tap answer.
struct StartOption: View {
    let title: String
    var on = false
    let action: () -> Void

    init(_ title: String, on: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.on = on
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.headline).multilineTextAlignment(.leading)
                Spacer(minLength: 12)
                if on { Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.tint) }
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(Color.fill, in: .rect(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2) }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The primary button at the foot of a screen, and an optional quiet one under it.
struct StartBar: View {
    let title: String
    var enabled = true
    var id = "start.continue"
    let action: () -> Void
    var secondary: (title: String, action: () -> Void)?

    var body: some View {
        VStack(spacing: 4) {
            Button(action: action) {
                Text(title).font(.headline).frame(maxWidth: .infinity, minHeight: 54)
            }
            .buttonStyle(.primary)
            .disabled(!enabled)
            .accessibilityIdentifier(id)
            if let secondary {
                Button(secondary.title, action: secondary.action)
                    .font(.subheadline).foregroundStyle(Color.inkMuted)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("start.skip")
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
    }
}

// MARK: - Screens 4–14

/// Screen 4: a structured plan against training on your own. Truthful (decision 7, 2026-11-14): no multiplier.
private struct ChartStep: View {
    let next: () -> Void

    var body: some View {
        StartQuestion("A structured plan, built around your lifts", detail: "Every session planned, and each week a little heavier than the last.") {
            VStack(alignment: .leading, spacing: 14) {
                ZStack(alignment: .bottomLeading) {
                    Curve(rise: 0.9).stroke(Plate.current.mark, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    Curve(rise: 0.35).stroke(Color.inkFaint, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [6, 6]))
                }
                .frame(height: 160)
                .accessibilityHidden(true)
                HStack(spacing: 18) {
                    Label("With Barbrabell", systemImage: "circle.fill").foregroundStyle(Plate.current.mark)
                    Label("On your own", systemImage: "circle.fill").foregroundStyle(Color.inkFaint)
                }
                .font(.footnote.weight(.semibold))
                .labelStyle(Dot())
            }
            .padding(20)
            .background(Color.fill, in: .rect(cornerRadius: 20))
        }
        .safeAreaBar(edge: .bottom) { StartBar(title: "Continue", action: next) }
    }

    private struct Curve: Shape {
        let rise: Double
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - rect.height * rise),
                          control1: CGPoint(x: rect.width * 0.4, y: rect.maxY),
                          control2: CGPoint(x: rect.width * 0.6, y: rect.maxY - rect.height * rise))
            return path
        }
    }

    private struct Dot: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 6) { configuration.icon.font(.system(size: 8)); configuration.title.foregroundStyle(Color.inkMuted) }
        }
    }
}

/// Screen 5: age in years, never a date of birth.
private struct AgeStep: View {
    @Binding var age: Int
    let next: () -> Void

    var body: some View {
        StartQuestion("How old are you?") {
            Picker("Age", selection: $age) {
                ForEach(13...90, id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.wheel)
            .accessibilityIdentifier("start.age")
        }
        .safeAreaBar(edge: .bottom) { StartBar(title: "Continue", action: next) }
    }
}

/// The ft/in or cm (and lb or kg) switch, kept for the weight and the lifts after it.
private struct UnitToggle: View {
    @Binding var metric: Bool
    let imperial: String
    let metricName: String

    var body: some View {
        Picker("Units", selection: $metric) {
            Text(imperial).tag(false)
            Text(metricName).tag(true)
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 200)
        .frame(maxWidth: .infinity)
    }
}

/// Screen 6.
private struct HeightStep: View {
    @Binding var inches: Double
    @Binding var metric: Bool
    let next: () -> Void

    var body: some View {
        StartQuestion("What’s your height?") {
            UnitToggle(metric: $metric, imperial: "ft / in", metricName: "cm")
            if metric {
                Picker("Height", selection: Binding(get: { Int((inches * 2.54).rounded()) }, set: { inches = Double($0) / 2.54 })) {
                    ForEach(120...220, id: \.self) { Text("\($0) cm").tag($0) }
                }
                .pickerStyle(.wheel)
            } else {
                HStack(spacing: 0) {
                    Picker("Feet", selection: Binding(get: { Int(inches.rounded()) / 12 }, set: { inches = Double($0 * 12 + Int(inches.rounded()) % 12) })) {
                        ForEach(4...7, id: \.self) { Text("\($0) ft").tag($0) }
                    }
                    Picker("Inches", selection: Binding(get: { Int(inches.rounded()) % 12 }, set: { inches = Double(Int(inches.rounded()) / 12 * 12 + $0) })) {
                        ForEach(0...11, id: \.self) { Text("\($0) in").tag($0) }
                    }
                }
                .pickerStyle(.wheel)
            }
        }
        .safeAreaBar(edge: .bottom) { StartBar(title: "Continue", action: next) }
        .onAppear {
            if !metric, Locale.current.measurementSystem != .us { metric = true }
        }
    }
}

/// Screen 7: the body weight the strength scores are against.
private struct WeightStep: View {
    @Binding var pounds: Double?
    @Binding var metric: Bool
    let next: () -> Void
    @State private var typed = ""
    @FocusState private var focused: Bool

    private var value: Double? {
        guard let number = Double(typed.replacingOccurrences(of: ",", with: ".")) else { return nil }
        let lb = metric ? number / 0.45359237 : number
        return (60...700).contains(lb) ? lb : nil
    }

    var body: some View {
        StartQuestion("What’s your current weight?") {
            UnitToggle(metric: $metric, imperial: "lb", metricName: "kg")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TextField("0", text: $typed)
                    .font(.display(44, weight: .semibold)).monospacedDigit()
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.center)
                    .focused($focused)
                    .fixedSize()
                    .accessibilityIdentifier("start.weight")
                Text(metric ? "kg" : "lb").font(.title3).foregroundStyle(Color.inkMuted)
            }
            .frame(maxWidth: .infinity, minHeight: 90)
            .background(Color.fill, in: .rect(cornerRadius: 16))
            .onTapGesture { focused = true }
        }
        .safeAreaBar(edge: .bottom) {
            StartBar(title: "Continue", enabled: value != nil) {
                pounds = value
                next()
            }
        }
        .onAppear {
            if let pounds { typed = (metric ? pounds * 0.45359237 : pounds).rounded().formatted() }
            focused = true
        }
        .onChange(of: metric) { _, now in
            guard let number = Double(typed) else { return }
            typed = (now ? number * 0.45359237 : number / 0.45359237).rounded().formatted()
        }
    }
}

/// Screen 12: what they have, ticked from where they train. Bodyweight only clears the rest.
private struct EquipmentStep: View {
    @Binding var have: Set<String>
    let next: () -> Void

    var body: some View {
        StartQuestion("What equipment do you have?", detail: "Every session uses only what you have.") {
            ForEach(ReadyProgram.kit, id: \.name) { line in
                StartOption(line.name, on: have.isSuperset(of: line.equipment)) {
                    if have.isSuperset(of: line.equipment) { have.subtract(line.equipment) } else { have.formUnion(line.equipment) }
                }
            }
            StartOption("Bodyweight only", on: have.isEmpty) { have = [] }
        }
        .safeAreaBar(edge: .bottom) { StartBar(title: "Continue", action: next) }
    }
}

/// Screen 14: the first name, used on every screen after it, the paywall's headline too.
private struct NameStep: View {
    @Binding var name: String
    let next: () -> Void
    @FocusState private var focused: Bool

    private var valid: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        StartQuestion("What’s your first name?") {
            TextField("Your first name", text: $name)
                .font(.title2.weight(.semibold))
                .textContentType(.givenName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.continue)
                .focused($focused)
                .onSubmit { if valid { next() } }
                .padding(.horizontal, 18)
                .frame(minHeight: 60)
                .background(Color.fill, in: .rect(cornerRadius: 16))
                .accessibilityIdentifier("start.name")
        }
        .safeAreaBar(edge: .bottom) { StartBar(title: "Continue", enabled: valid, action: next) }
        .onAppear { focused = true }
    }
}
