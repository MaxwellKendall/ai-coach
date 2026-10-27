import SwiftUI
import SwiftData

/// FIT-230: no coach: what you have to train with, then how many days (one tap), then the ready-made program that fits,
/// to start on Today. Opened again from You, it starts on the program being followed, with the questions a step back.
/// FIT-281: the consumer app asks the goal and whether they've lifted first, and a recent set of the main lift last, as
/// the web's quiz does (web/src/StartPage.tsx).
struct ProgramPicker: View {
    @Query private var profiles: [Profile]
    var onDone: () -> Void
    /// FIT-267: the consumer app's first launch has no Skip; someone who started on the web signs in instead.
    var signIn: (() -> Void)?

    @State private var path: [Step] = []
    /// Catalog equipment ticked on "What do you have?".
    @State private var have: Set<String> = []
    @State private var days = 3
    @State private var goal: ReadyProgram.Goal?
    @State private var lifted: Bool?
    @State private var recent: StartingSet?
    @State private var started = false

    enum Step: Hashable { case lifted, kit, days, recent, program }

    /// The main lift of the program the answers so far pick, which the recent set is of.
    private var lift: String? {
        ReadyProgram.matches(have: have, days: days, goal: goal, lifted: lifted).first?.mainLift?.exercise
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if Edition.consumer {
                    question("What’s your goal?", "Your plan is built around it.") {
                        ForEach(Self.goals, id: \.goal) { line in
                            option(line.title, detail: line.detail, next: line.goal == .start ? .kit : .lifted) {
                                goal = line.goal
                                if line.goal == .start { lifted = false }
                            }
                        }
                    }
                } else {
                    kit
                }
            }
            .toolbar {
                if let signIn {
                    ToolbarItem(placement: .cancellationAction) { Button("Sign In", action: signIn) }
                } else if !Edition.consumer || profiles.first?.programSlug != nil {
                    ToolbarItem(placement: .cancellationAction) { Button(profiles.first?.programSlug == nil ? "Skip" : "Cancel", action: onDone) }
                }
            }
            .navigationDestination(for: Step.self) { step in
                switch step {
                case .lifted:
                    question("Have you lifted weights before?", "Your plan starts where you are.") {
                        option("Yes", next: .kit) { lifted = true }
                        option("Not really", next: .kit) { lifted = false }
                    }
                case .kit:
                    kit
                case .days:
                    question("How many days a week?", "The days themselves come next.") {
                        ForEach(2...6, id: \.self) { count in
                            option("\(count) days", next: .program) {
                                days = count
                                // Someone who's lifted gives a recent set first, when the program has a lift to load.
                                if Edition.consumer, lifted == true, lift != nil { path.append(.recent) } else { path.append(.program) }
                            }
                        }
                    }
                case .recent:
                    if let lift {
                        RecentSetStep(exercise: lift, perHand: ReadyProgram.matches(have: have, days: days, goal: goal, lifted: lifted)
                            .first?.place == .dumbbells) { set in
                            recent = set
                            path.append(.program)
                        }
                    }
                case .program:
                    ProgramChoice(have: $have, days: days, goal: goal, lifted: lifted, recent: recent, onStart: onDone)
                }
            }
        }
        .onAppear(perform: resume)
    }

    /// From You: the program being followed, with its equipment and days.
    private func resume() {
        guard !started, let profile = profiles.first, ReadyProgram.named(profile.programSlug) != nil else { return }
        started = true
        have = Set(profile.equipment)
        days = profile.trainingDays.count
        path = Edition.consumer ? [.kit, .days, .program] : [.days, .program]
    }

    private var kit: some View {
        question("What do you have?", "Tick what you can use. The program only uses these.") {
            KitList(have: $have)
            Text(have.isEmpty ? "Nothing ticked: a body-weight program." : " ")
                .font(.footnote).foregroundStyle(.secondary).padding(.top, 4)
        }
        .safeAreaBar(edge: .bottom) {
            Button { path.append(.days) } label: {
                Text("Continue").font(.headline).frame(maxWidth: .infinity, minHeight: 54)
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
            .padding(.horizontal, 24).padding(.bottom, 8)
        }
    }

    /// The web's goals (web/src/StartPage.tsx), in its words.
    static let goals: [(goal: ReadyProgram.Goal, title: String, detail: String)] = [
        (.strength, "Get stronger", "Lift heavier on the big lifts."),
        (.muscle, "Build muscle", "Add size and shape."),
        (.start, "Start lifting", "New to it: learn the lifts, then build."),
    ]

    private func question(_ text: String, _ detail: String, @ViewBuilder options: () -> some View) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(text).font(.system(size: 32, weight: .bold)).tracking(-0.4)
                Text(detail).font(.body).foregroundStyle(.secondary).padding(.top, 8).padding(.bottom, 28)
                VStack(spacing: 10) { options() }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
        }
        .toolbarTitleDisplayMode(.inline)
    }

    /// A one-tap answer: it's set and the next question opens (`set` may open another itself).
    private func option(_ title: String, detail: String? = nil, next: Step, set: @escaping () -> Void) -> some View {
        Button {
            let count = path.count
            set()
            if path.count == count { path.append(next) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 18))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// "What do you have?": a full gym ticks every line; each line is some of the catalog's equipment.
private struct KitList: View {
    @Binding var have: Set<String>

    private var everything: Set<String> { Set(ReadyProgram.kit.flatMap(\.equipment)) }

    var body: some View {
        VStack(spacing: 10) {
            row("A full gym", on: have.isSuperset(of: everything)) { on in
                have = on ? have.union(everything) : have.subtracting(everything)
            }
            ForEach(ReadyProgram.kit, id: \.name) { line in
                row(line.name, on: have.isSuperset(of: line.equipment)) { on in
                    have = on ? have.union(line.equipment) : have.subtracting(line.equipment)
                }
            }
        }
    }

    private func row(_ title: String, on: Bool, set: @escaping (Bool) -> Void) -> some View {
        Button { withAnimation(.snappy) { set(!on) } } label: {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(on ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 18))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// "A full gym", "Dumbbells, Pull-up bar", "None".
    static func summary(_ have: Set<String>) -> String {
        let lines = ReadyProgram.kit.filter { have.isSuperset(of: $0.equipment) }
        return lines.count == ReadyProgram.kit.count ? "A full gym" : lines.isEmpty ? "None" : lines.map(\.name).joined(separator: ", ")
    }
}

/// The program that fits best, what a week of it looks like and its days, then Start. The others that fit, and every
/// other program, are below it.
private struct ProgramChoice: View {
    @Environment(\.modelContext) private var context
    @Query private var profiles: [Profile]
    @Query private var templates: [Template]
    @Binding var have: Set<String>
    var days: Int
    var goal: ReadyProgram.Goal?
    var lifted: Bool?
    var recent: StartingSet?
    var onStart: () -> Void

    @State private var selected: ReadyProgram?
    @State private var trainingDays: [Int] = []
    @State private var showsAll = false
    @State private var failure: String?
    /// Following a program already: starting one begins again at week 1, so it's asked first.
    @State private var confirming = false

    private var matches: [ReadyProgram] { ReadyProgram.matches(have: have, days: days, goal: goal, lifted: lifted) }
    private var program: ReadyProgram? { selected ?? matches.first }
    private var equipment: [String] { ReadyProgram.equipment(have) }

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                if let program {
                    VStack(alignment: .leading, spacing: 0) {
                        header(program).id("top")
                        daysRow(program).padding(.top, 24)
                        DisclosureGroup {
                            KitList(have: $have).padding(.top, 12)
                        } label: {
                            LabeledContent("Equipment", value: KitList.summary(have)).font(.headline)
                        }
                        .padding(.top, 24)
                        week(program).padding(.top, 28)
                        others(program, scroll: scroll).padding(.top, 36)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
            }
        }
        .toolbarTitleDisplayMode(.inline)
        .safeAreaBar(edge: .bottom) { if let program { startBar(program) } }
        .onAppear {
            guard selected == nil else { return }
            let profile = profiles.first
            // The program being followed, while the answers are still the ones it was started with.
            let same = profile.map { Set($0.equipment) == Set(equipment) && $0.trainingDays.count == days } ?? false
            let current = same ? ReadyProgram.named(profile?.programSlug) : nil
            select(current ?? matches.first, days: current != nil ? profile?.trainingDays : nil)
        }
        // Equipment changed here: the best program for it, as the questions would have picked.
        .onChange(of: have) { withAnimation(.snappy) { select(matches.first) } }
    }

    private func header(_ program: ReadyProgram) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(program.name).font(.system(size: 32, weight: .bold)).tracking(-0.4)
            Text(program.summary).font(.body).foregroundStyle(.secondary).padding(.top, 8)
            Text([Self.level(program), "\(program.weeks) weeks", "about \(program.minutes) min a session"].joined(separator: " · "))
                .font(.subheadline).padding(.top, 12)
        }
    }

    private func daysRow(_ program: ReadyProgram) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Training days").font(.headline)
            DayPicker(days: $trainingDays)
            let counts = program.days.map(String.init)
            if !program.days.contains(trainingDays.count) {
                Text("Pick \(counts.count == 1 ? counts[0] : counts.dropLast().joined(separator: ", ") + " or " + counts.last!) days.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    /// Each session once, in order, with the exercises the equipment allows.
    private func week(_ program: ReadyProgram) -> some View {
        let names = Dictionary(templates.map { ($0.slug, $0.name) }, uniquingKeysWith: { first, _ in first })
        let catalog = Dictionary(Planner.catalog(templates).map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
        let have = Set(equipment)
        var seen = Set<String>()
        let sessions = program.sessions.filter { seen.insert($0.name).inserted }
        return VStack(alignment: .leading, spacing: 18) {
            Text("A week looks like").font(.headline)
            ForEach(sessions, id: \.name) { session in
                VStack(alignment: .leading, spacing: 6) {
                    Text(session.name.uppercased()).font(.footnote.weight(.semibold)).tracking(0.4).foregroundStyle(.secondary)
                    ForEach(Array(session.exercises.enumerated()), id: \.offset) { _, item in
                        if let slug = item.choices.first(where: { catalog[$0]?.equipment.isSubset(of: have) == true }) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(names[slug] ?? slug)
                                Spacer(minLength: 12)
                                Text(Self.dose(item)).foregroundStyle(.secondary).monospacedDigit()
                            }
                            .font(.subheadline)
                        }
                    }
                }
            }
        }
    }

    private func others(_ program: ReadyProgram, scroll: ScrollViewProxy) -> some View {
        let fits = Array(matches.filter { $0 != program }.prefix(3))
        let rest = ReadyProgram.all.filter { $0 != program && !fits.contains($0) }
        return VStack(alignment: .leading, spacing: 10) {
            if !fits.isEmpty {
                Text("Also fits").font(.headline)
                ForEach(fits) { row($0, scroll: scroll) }
            }
            if showsAll {
                ForEach(rest) { row($0, scroll: scroll) }
            } else if !rest.isEmpty {
                Button("All Programs") { withAnimation(.snappy) { showsAll = true } }
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
    }

    private func row(_ other: ReadyProgram, scroll: ScrollViewProxy) -> some View {
        Button {
            withAnimation(.snappy) {
                select(other)
                scroll.scrollTo("top", anchor: .top)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(other.name).font(.headline)
                Text([other.days.map(String.init).joined(separator: ", ") + " days", Self.places[other.place] ?? "", Self.level(other)]
                    .joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 18))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func startBar(_ program: ReadyProgram) -> some View {
        VStack(spacing: 6) {
            if let failure { Text(failure).font(.footnote).foregroundStyle(.red) }
            Button {
                if profiles.first?.programSlug == nil { start(program) } else { confirming = true }
            } label: {
                Text("Start Program").font(.headline).frame(maxWidth: .infinity, minHeight: 54)
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
            .disabled(!program.days.contains(trainingDays.count))
            .confirmationDialog("Start \(program.name)?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Start Program") { start(program) }
            } message: {
                Text("It starts today at week 1. Everything you’ve logged stays.")
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
    }

    private func start(_ program: ReadyProgram) {
        guard let profile = profiles.first else { return }
        do {
            // FIT-281: the recent set, while it's of this program's main lift.
            let starts = Edition.consumer ? [recent].compactMap { $0 }.filter { $0.exercise == program.mainLift?.exercise } : nil
            try Planner.start(program, days: trainingDays, equipment: equipment, starts: starts, profile: profile, in: context)
            onStart()
        } catch {
            failure = "Couldn’t start the program. Try again."
        }
    }

    /// Another program: its days a week nearest the answer, spread out, unless the days already picked suit it.
    private func select(_ program: ReadyProgram?, days picked: [Int]? = nil) {
        guard let program else { return }
        selected = program
        if let picked, program.days.contains(picked.count) {
            trainingDays = picked
        } else if !program.days.contains(trainingDays.count) {
            trainingDays = ReadyProgram.days(for: program.days(nearest: days))
        }
    }

    /// "3 × 5", "3 × 8–12", "3 × 20–60 s".
    static func dose(_ item: ReadyProgram.Item) -> String {
        let range = (item.seconds ?? item.reps ?? []).sorted()
        guard let low = range.first, let high = range.last else { return "\(item.sets) sets" }
        return "\(item.sets) × \(low == high ? "\(low)" : "\(low)–\(high)")" + (item.seconds != nil ? " s" : "")
    }

    static func level(_ program: ReadyProgram) -> String { program.level == "new" ? "New to lifting" : "Some experience" }

    static let places: [ReadyProgram.Place: String] = [.gym: "Barbell", .dumbbells: "Dumbbells", .bodyweight: "No equipment"]
}

/// FIT-281: "Your best recent Back Squat": a hard set from the last few months, which the plan starts a little under.
private struct RecentSetStep: View {
    @Query private var templates: [Template]
    let exercise: String
    let perHand: Bool
    var onDone: (StartingSet?) -> Void

    @State private var weight = ""
    @State private var reps = ""
    @FocusState private var focus: Field?

    enum Field { case weight, reps }

    private var set: StartingSet? {
        guard let load = Double(weight), (1...1000).contains(load), let count = Int(reps), (1...12).contains(count) else { return nil }
        return StartingSet.recent(exercise, weight: load, reps: Double(count), perHand: perHand)
    }

    var body: some View {
        let name = templates.first { $0.slug == exercise }?.name ?? exercise
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Your best recent \(name)").font(.system(size: 32, weight: .bold)).tracking(-0.4)
                Text("A hard set from the last few months, 1 to 12 reps. Your plan starts a little under it.")
                    .font(.body).foregroundStyle(.secondary).padding(.top, 8).padding(.bottom, 28)
                HStack(spacing: 12) {
                    field($weight, perHand ? "lb a hand" : "lb", .weight, keyboard: .decimalPad)
                    Text("×").font(.title2).foregroundStyle(.secondary)
                    field($reps, "reps", .reps, keyboard: .numberPad)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
        }
        .toolbarTitleDisplayMode(.inline)
        .onAppear { focus = .weight }
        .safeAreaBar(edge: .bottom) {
            VStack(spacing: 4) {
                Button { onDone(set) } label: {
                    Text("Continue").font(.headline).frame(maxWidth: .infinity, minHeight: 54)
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                .disabled(set == nil)
                Button("I’m Not Sure") { onDone(nil) }
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .padding(.horizontal, 24).padding(.bottom, 8)
        }
    }

    private func field(_ text: Binding<String>, _ unit: String, _ which: Field, keyboard: UIKeyboardType) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            TextField("0", text: text)
                .font(.system(size: 28, weight: .semibold)).monospacedDigit()
                .keyboardType(keyboard)
                .focused($focus, equals: which)
            Text(unit).font(.subheadline).foregroundStyle(.secondary).fixedSize()
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, minHeight: 64)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 18))
        .onTapGesture { focus = which }
    }
}
