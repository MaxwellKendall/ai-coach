import SwiftUI
import SwiftData

/// FIT-111: "Train my program". The program goes as its brief (phases, focus, main lifts and reps), goals, days,
/// equipment and this week's sessions, never weights or logs; the page (infra/lambda/sharePages.ts, /p/{id}) reads
/// the same fields. A friend starts it with the brief checked against their own catalog, and their weeks are
/// designed from it with their own goals and weights.
enum SharedProgram {
    struct Phase: Codable, Equatable, Sendable {
        var phase: String
        /// Weeks, 1-based.
        var from: Int
        var to: Int
        var focus: String
        var mainLifts: [String]
        var mainReps: Int
    }

    struct Day: Codable, Equatable, Sendable {
        var day: String
        var title: String
        var items: [String]
    }

    struct Shared: Codable, Equatable, Sendable {
        var name: String
        var weeks: Int
        var days: Int
        var equipment: String
        var goals: [String]
        var phases: [Phase]
        var sampleWeek: [Day]
        var brief: ProgramBrief
        var invite: String?
    }

    /// The profile's program, or nil before it has a brief.
    @MainActor static func make(profile: Profile, goals: [Goal], thisWeek: [PlannedActivity], templates: [Template],
                                invite: String?, calendar: Calendar = .current) -> Shared? {
        guard let brief = profile.brief?.brief, let program = profile.program, !program.isEmpty else { return nil }
        let lines = Planner.goalLines(goals)
        let phases = brief.phases.compactMap { line -> Phase? in
            let weeks = program.indices.filter { program[$0].phase.rawValue == line.phase && !program[$0].light }
            guard let from = weeks.first, let to = weeks.last else { return nil }
            return Phase(phase: line.phase, from: from + 1, to: to + 1, focus: line.focus, mainLifts: line.mainLifts, mainReps: line.mainReps)
        }
        let slugs = Dictionary(templates.map { ($0.id, $0.slug) }, uniquingKeysWith: { first, _ in first })
        let names = Dictionary(templates.map { ($0.slug, $0.name) }, uniquingKeysWith: { first, _ in first })
        let days = Dictionary(grouping: thisWeek.filter { $0.kind == .workout }) { calendar.startOfDay(for: $0.date) }
        let sample = days.keys.sorted().map { day -> Day in
            let rows = days[day]!.sorted { $0.date < $1.date }
            let workouts = rows.map {
                PlannedWorkout(date: $0.date, session: $0.slot ?? "", exercise: $0.templateRef.flatMap { slugs[$0] } ?? "",
                               targets: $0.targets, note: $0.note.isEmpty ? nil : $0.note)
            }
            let session = SharedSession.make(title: rows.first?.slot ?? "Workout", date: day, workouts: workouts, names: names,
                                             showNumbers: false, invite: nil, calendar: calendar)
            return Day(day: day.formatted(.dateTime.weekday(.wide)), title: session.title,
                       items: session.exercises.prefix(12).map { "\($0.name) \($0.sets) × \($0.reps.map(String.init) ?? $0.seconds.map { "\($0) s" } ?? "")" })
        }
        let equipment = Set(profile.equipment)
        return Shared(name: lines.first ?? "\(program.count)-week program", weeks: program.count,
                      days: profile.trainingSettings.trainingDays.count,
                      equipment: equipment.isSuperset(of: ["barbell", "rack"]) ? "Full gym" : equipment.contains("dumbbells") ? "Dumbbells" : "Bodyweight",
                      goals: Array(lines.prefix(4)), phases: phases, sampleWeek: Array(sample.prefix(7)), brief: brief, invite: invite)
    }

    /// The friend's program from now on follows the shared brief, checked against their own catalog; this week is
    /// planned again from it. False when none of it fits (nothing changes then).
    @MainActor static func start(_ shared: Shared, in context: ModelContext, model: any AIModel) async -> Bool {
        guard let request = Planner.designRequest(weekOf: .now, in: context), !request.programPlan.isEmpty,
              let profile = try? context.fetch(FetchDescriptor<Profile>()).first else { return false }
        let checked = ProgramBrief.checked(shared.brief, ProgramBrief.Request(
            settings: request.settings, catalog: request.catalog, names: request.names, goals: request.goals,
            goalLifts: request.goalLifts, weeks: request.programPlan))
        guard !checked.phases.isEmpty else { return false }
        profile.brief = ProgramBrief.Stored(brief: checked, key: ProgramBrief.key(goals: request.goals, settings: request.settings,
                                                                                weeks: request.programPlan), model: "shared")
        try? context.save()
        try? Planner.generate(weekOf: .now, in: context)
        await Planner.design(in: context, model: model)
        return true
    }

    @MainActor static func link(profile: Profile, goals: [Goal], thisWeek: [PlannedActivity], templates: [Template]) async throws -> SharedLink? {
        var invite: String?
        if let group = try? await Cloud.myGroups().first { invite = try? await Cloud.group(group.groupId)?.inviteCode }
        guard let shared = make(profile: profile, goals: goals, thisWeek: thisWeek, templates: templates, invite: invite) else { return nil }
        let payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(shared)) as? [String: Any] ?? [:]
        let share = try await Cloud.createShare(kind: "program", payload: payload)
        guard let url = URL(string: share.url) else { throw URLError(.badURL) }
        let card = PlanCard.program(shared, link: ShareLinks.short(url)).image()
        if let png = card?.pngData() { try? await Cloud.uploadCard(png, for: share.id) }
        return SharedLink(url: url, title: "Train my program: \(shared.name)", image: card)
    }
}

/// Opened from a shared program's link: what it is, and Start. Principle 7: nothing changes until they say so.
struct ProgramStartSheet: View {
    let id: String
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(Account.self) private var account
    @State private var loaded: (who: String, shared: SharedProgram.Shared)?
    @State private var failure: String?
    @State private var working = false

    var body: some View {
        NavigationStack {
            Group {
                if let loaded { content(loaded.who, loaded.shared) } else if let failure {
                    ContentUnavailableView("Can’t start this program", systemImage: "calendar.badge.exclamationmark", description: Text(failure))
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(loaded.map { "\($0.who)’s program" } ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .task { await load() }
    }

    private func content(_ who: String, _ shared: SharedProgram.Shared) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(shared.name).font(.title2.weight(.bold))
                    Text("\(shared.weeks) weeks · \(shared.days) days a week · \(shared.equipment)").foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            Section("The plan") {
                ForEach(shared.phases, id: \.phase) { phase in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(phase.phase.capitalized) · weeks \(phase.from)\(phase.to > phase.from ? "–\(phase.to)" : "")").font(.headline)
                        Text(phase.focus).font(.subheadline).foregroundStyle(.secondary)
                        Text("\(phase.mainLifts.joined(separator: " · ")) × \(phase.mainReps)").font(.subheadline)
                    }
                    .padding(.vertical, 2)
                }
            }
            Section {
                Button(working ? "Planning your week…" : "Start this program") { start(shared) }
                    .bold().frame(maxWidth: .infinity).disabled(working)
            } footer: {
                Text("Your goals, days and weights stay yours: the program’s phases and main lifts guide your weeks from now on.")
            }
        }
    }

    private func load() async {
        do {
            guard let item = try await Cloud.share(id), item.kind == "program",
                  let shared = try? JSONDecoder().decode(SharedProgram.Shared.self, from: Data(item.payload.utf8)) else {
                failure = "Whoever shared it may have stopped sharing."
                return
            }
            loaded = (item.name?.split(separator: " ").first.map(String.init) ?? "A friend", shared)
        } catch {
            failure = "Check your connection and try again."
        }
    }

    private func start(_ shared: SharedProgram.Shared) {
        working = true
        Task {
            defer { working = false }
            if await SharedProgram.start(shared, in: context, model: LanguageModel.programs(signedIn: account.user != nil)) {
                if let invite = shared.invite { _ = try? await Cloud.join(code: invite) }
                dismiss()
            } else {
                failure = "None of this program fits your equipment and settings."
            }
        }
    }
}

/// A shared program's id, for presenting it.
struct ProgramRef: Identifiable {
    let id: String
}
