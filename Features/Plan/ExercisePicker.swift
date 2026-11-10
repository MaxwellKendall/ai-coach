import SwiftUI
import SwiftData

/// FIT-81: an exercise to swap in or add. A short list first (the same movement, or the user's cards and the staples)
/// and search for the rest of the catalog, only ever what the user can do. A 700-item menu was "way too excessive".
/// FIT-347: what they've used lately first, chips by body area, and the list in sections by area, main lifts first.
struct ExercisePicker: View {
    typealias Area = ExerciseSearch.Area

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Template.name) private var templates: [Template]
    @Query private var profiles: [Profile]
    @Query private var logged: [LogEntry]
    @Query private var planned: [PlannedActivity]
    let title: String
    /// The exercise being swapped: its alternatives come first.
    var replacing: String?
    /// Already in the session.
    var excluding: Set<String>
    /// FIT-300: picking for the warm-up: cardio and mobility first instead of the common lifts.
    var warmup: Bool
    /// FIT-347: a coach picking for a client: the client's settings and what they've used, instead of the coach's own.
    var settings: TrainingSettings?
    var uses: [(slug: String, at: Date)]?
    let onPick: (String) -> Void
    @State private var query = ""
    @State private var area: Area?

    init(title: String, replacing: String? = nil, excluding: Set<String> = [], warmup: Bool = false,
         settings: TrainingSettings? = nil, uses: [(slug: String, at: Date)]? = nil, onPick: @escaping (String) -> Void) {
        self.title = title
        self.replacing = replacing
        self.excluding = excluding
        self.warmup = warmup
        self.settings = settings
        self.uses = uses
        self.onPick = onPick
        let since = Date.now.addingTimeInterval(-28 * 86_400)
        _logged = Query(filter: #Predicate<LogEntry> { $0.timestamp >= since })
        _planned = Query(filter: #Predicate<PlannedActivity> { $0.date >= since })
    }

    var body: some View {
        let names = Dictionary(templates.map { ($0.slug, $0.name) }, uniquingKeysWith: { first, _ in first })
        let all = Planner.catalog(templates)
        let catalog = area.map { area in all.filter { Area.of($0.pattern) == area } } ?? all
        let settings = settings ?? profiles.first?.trainingSettings ?? TrainingSettings(
            age: 35, daysPerWeek: 3, sessionMinutes: 45, trainingDays: [0, 2, 4], workoutTime: 420,
            equipment: Set(Profile.allEquipment), maxWeeklySets: 60)
        let typed = query.trimmingCharacters(in: .whitespaces)
        let bySlug = Dictionary(all.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
        let sections: [(heading: String, slugs: [String])] = if !typed.isEmpty {
            [("Results", { () -> [String] in
                let found = ExerciseSearch.find(typed, in: catalog, names: names, settings: settings, excluding: excluding, limit: 40)
                return found.isEmpty ? PlanGuard.search(typed, in: catalog, names: names, settings: settings, excluding: excluding, limit: 40) : found
            }())]
        } else if let replacing, let exercise = bySlug[replacing] {
            [("Same movement", ExerciseSearch.alternatives(to: exercise, in: catalog, names: names, settings: settings, excluding: excluding))]
        } else if warmup {
            [("Warm-up", ExerciseSearch.warmups(in: catalog, settings: settings, excluding: excluding))]
        } else {
            common(catalog, names: names, settings: settings, bySlug: bySlug)
        }
        let empty = sections.allSatisfy(\.slugs.isEmpty)
        NavigationStack {
            List {
                ForEach(sections.filter { !$0.slugs.isEmpty }, id: \.heading) { section in
                    Section(section.heading) {
                        ForEach(section.slugs, id: \.self) { slug in
                            Button {
                                onPick(slug)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(names[slug] ?? slug).foregroundStyle(.primary)
                                    if let exercise = bySlug[slug] { Text(Self.detail(exercise)).font(.footnote).foregroundStyle(.secondary) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if empty {
                    Text(typed.isEmpty ? "Nothing else here with your equipment. Search for another."
                                       : "Nothing matches with your equipment.")
                        .foregroundStyle(.secondary)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { chips }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search exercises")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Chip(title: "All", on: area == nil) { area = nil }
                ForEach(Area.allCases, id: \.self) { each in
                    Chip(title: each.rawValue, on: area == each) { area = area == each ? nil : each }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 8)
        }
        .background(Color(.systemGroupedBackground))
    }

    /// Nothing typed, adding: Recent, then the cards and staples in sections by area (one section when a chip is on).
    private func common(_ catalog: [Exercise], names: [String: String], settings: TrainingSettings,
                        bySlug: [String: Exercise]) -> [(heading: String, slugs: [String])] {
        let recent = ExerciseSearch.recent(uses ?? ownUses(), in: catalog, settings: settings, excluding: excluding)
        let rest = ExerciseSearch.suggestions(in: catalog, names: names, settings: settings, excluding: excluding.union(recent))
        let grouped = Dictionary(grouping: rest) { bySlug[$0].flatMap { Area.of($0.pattern) } }
        let areas: [(String, [String])] = Area.allCases.map { ($0.rawValue, grouped[$0] ?? []) } + [("Other", grouped[nil] ?? [])]
        return [("Recent", recent)] + areas
    }

    /// What this person logged or had planned, by slug.
    private func ownUses() -> [(slug: String, at: Date)] {
        let slugs = Dictionary(templates.map { ($0.id, $0.slug) }, uniquingKeysWith: { first, _ in first })
        return logged.compactMap { entry in entry.templateRef.flatMap { slugs[$0] }.map { ($0, entry.timestamp) } }
            + planned.compactMap { item in item.templateRef.flatMap { slugs[$0] }.map { ($0, item.date) } }
    }

    /// "Dumbbells, bench", "Bodyweight": the section names the area.
    static func detail(_ exercise: Exercise) -> String {
        let equipment = exercise.equipment.isEmpty ? "bodyweight"
            : exercise.equipment.sorted().map { (OnboardingAnswers.equipmentNames[$0] ?? $0).lowercased() }.joined(separator: ", ")
        return equipment.prefix(1).uppercased() + equipment.dropFirst()
    }
}
