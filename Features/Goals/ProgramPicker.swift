import SwiftUI
import SwiftData

/// FIT-230: no coach: where you'll train and how many days, one tap each, then the ready-made program that fits, to
/// start on Today. Opened again from You, it starts on the program being followed, with the questions a step back.
struct ProgramPicker: View {
    @Query private var profiles: [Profile]
    var onDone: () -> Void

    @State private var path: [Step] = []
    @State private var place = ReadyProgram.Place.gym
    @State private var days = 3
    @State private var started = false

    enum Step: Hashable { case days, program }

    var body: some View {
        NavigationStack(path: $path) {
            question("Where will you train?", "Pick the closest. You can change the program later.") {
                option("A gym", "Barbells, machines and cables") { place = .gym }
                option("At home, with dumbbells", "A pair, or a few sets") { place = .dumbbells }
                option("No equipment", "Just your body weight") { place = .bodyweight }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(profiles.first?.programSlug == nil ? "Skip" : "Cancel", action: onDone) }
            }
            .navigationDestination(for: Step.self) { step in
                switch step {
                case .days:
                    question("How many days a week?", "The days themselves come next.") {
                        ForEach(2...6, id: \.self) { count in
                            option("\(count) days", nil) { days = count }
                        }
                    }
                case .program:
                    ProgramChoice(place: place, days: days, onStart: onDone)
                }
            }
        }
        .onAppear(perform: resume)
    }

    /// From You: the program being followed, from its place and days.
    private func resume() {
        guard !started, let profile = profiles.first, let ready = ReadyProgram.named(profile.programSlug) else { return }
        started = true
        place = ready.place
        days = profile.trainingDays.count
        path = [.days, .program]
    }

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

    /// A one-tap answer: it's set and the next step opens.
    private func option(_ title: String, _ detail: String?, set: @escaping () -> Void) -> some View {
        Button {
            set()
            path.append(path.isEmpty ? .days : .program)
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

/// The program that fits best, what a week of it looks like and its days, then Start. The others that fit, and every
/// other program, are below it.
private struct ProgramChoice: View {
    @Environment(\.modelContext) private var context
    @Query private var profiles: [Profile]
    @Query private var templates: [Template]
    var place: ReadyProgram.Place
    var days: Int
    var onStart: () -> Void

    @State private var selected: ReadyProgram?
    @State private var trainingDays: [Int] = []
    /// Optional equipment switched on: a pull-up bar, a bench.
    @State private var extras: Set<String> = []
    @State private var showsAll = false
    @State private var failure: String?
    /// Following a program already: starting one begins again at week 1, so it's asked first.
    @State private var confirming = false

    private var matches: [ReadyProgram] { ReadyProgram.matches(place: place, days: days) }
    private var program: ReadyProgram? { selected ?? matches.first }
    private var equipment: [String] { place.equipment + extras.sorted() }

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                if let program {
                    VStack(alignment: .leading, spacing: 0) {
                        header(program).id("top")
                        daysRow(program).padding(.top, 24)
                        ForEach(program.optional ?? [], id: \.self) { item in
                            Toggle(Self.have[item] ?? item, isOn: Binding { extras.contains(item) } set: { on in
                                if on { extras.insert(item) } else { extras.remove(item) }
                            })
                            .padding(.top, 16)
                        }
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
            let current = ReadyProgram.named(profile?.programSlug)
            select(current?.place == place && current?.days.contains(days) == true ? current! : matches.first,
                   days: current != nil && profile?.trainingDays.count == days ? profile?.trainingDays : nil)
            // The switches as they were, for the program being followed; equipment from another place doesn't carry over.
            if let profile, current?.place == place { extras = Set(profile.equipment).intersection(selected?.optional ?? []) }
        }
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
            try Planner.start(program, days: trainingDays, equipment: equipment, profile: profile, in: context)
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

    static let places: [ReadyProgram.Place: String] = [.gym: "Gym", .dumbbells: "Dumbbells", .bodyweight: "No equipment"]
    static let have = ["pull_up_bar": "I have a pull-up bar", "bench": "I have a bench"]
}
