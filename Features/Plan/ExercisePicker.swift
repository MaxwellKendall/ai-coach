import SwiftUI
import SwiftData

/// FIT-81: an exercise to swap in or add. A short list first (the same movement, or the user's cards and the staples)
/// and search for the rest of the catalog, only ever what the user can do. A 700-item menu was "way too excessive".
struct ExercisePicker: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Template.name) private var templates: [Template]
    @Query private var profiles: [Profile]
    let title: String
    /// The exercise being swapped: its alternatives come first.
    var replacing: String?
    /// Already in the session.
    var excluding: Set<String> = []
    let onPick: (String) -> Void
    @State private var query = ""

    var body: some View {
        let catalog = Planner.catalog(templates)
        let names = Dictionary(templates.map { ($0.slug, $0.name) }, uniquingKeysWith: { first, _ in first })
        let settings = profiles.first?.trainingSettings ?? TrainingSettings(
            age: 35, daysPerWeek: 3, sessionMinutes: 45, trainingDays: [0, 2, 4], workoutTime: 420,
            equipment: Set(Profile.allEquipment), maxWeeklySets: 60)
        let typed = query.trimmingCharacters(in: .whitespaces)
        let (heading, slugs): (String, [String]) = if !typed.isEmpty {
            ("Results", { () -> [String] in
                let found = ExerciseSearch.find(typed, in: catalog, names: names, settings: settings, excluding: excluding, limit: 40)
                return found.isEmpty ? PlanGuard.search(typed, in: catalog, names: names, settings: settings, excluding: excluding, limit: 40) : found
            }())
        } else if let replacing, let exercise = catalog.first(where: { $0.slug == replacing }) {
            ("Same movement", ExerciseSearch.alternatives(to: exercise, in: catalog, names: names, settings: settings, excluding: excluding))
        } else {
            ("Common", ExerciseSearch.suggestions(in: catalog, names: names, settings: settings, excluding: excluding))
        }
        let bySlug = Dictionary(catalog.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
        NavigationStack {
            List {
                Section(heading) {
                    ForEach(slugs, id: \.self) { slug in
                        Button {
                            onPick(slug)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(names[slug] ?? slug).foregroundStyle(.primary)
                                if let exercise = bySlug[slug] { Text(Self.detail(exercise)).font(.footnote).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
                if slugs.isEmpty {
                    Text(typed.isEmpty ? "Nothing else for this movement with your equipment. Search for another."
                                       : "Nothing matches with your equipment.")
                        .foregroundStyle(.secondary)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search exercises")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    /// "Squat · dumbbells", "Pull · bodyweight".
    static func detail(_ exercise: Exercise) -> String {
        let equipment = exercise.equipment.isEmpty ? "bodyweight"
            : exercise.equipment.sorted().map { (OnboardingAnswers.equipmentNames[$0] ?? $0).lowercased() }.joined(separator: ", ")
        return "\(exercise.pattern.prefix(1).uppercased() + exercise.pattern.dropFirst()) · \(equipment)"
    }
}
