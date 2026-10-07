import Foundation
import Testing
@testable import AICoach

/// FIT-70: free-exercise-db into the catalog, and the catalog searched.
struct ExerciseDBImporterTests {
    private func entry(_ name: String, equipment: String? = "body only", primary: [String], mechanic: String? = "compound",
                       force: String? = "push", category: String = "strength") -> ExerciseDBImporter.Entry {
        ExerciseDBImporter.Entry(name: name, force: force, level: "beginner", mechanic: mechanic, equipment: equipment,
                                 primaryMuscles: primary, secondaryMuscles: [], category: category)
    }

    private func seed(_ entry: ExerciseDBImporter.Entry) throws -> [String: [String]] {
        let seed = try ExerciseDBImporter.seed(entry).get()
        return Dictionary(uniqueKeysWithValues: seed.attributes.map { ($0.key, $0.values) })
    }

    @Test(arguments: [
        ("Barbell Squat", "barbell", "quadriceps", "compound", "squat", ["barbell", "rack"]),
        ("Dumbbell Lunges", "dumbbell", "quadriceps", "compound", "lunge", ["dumbbells"]),
        ("Leg Extensions", "machine", "quadriceps", "isolation", "legs", ["machine"]),
        ("Romanian Deadlift", "barbell", "hamstrings", "compound", "hinge", ["barbell"]),
        ("Lying Leg Curls", "machine", "hamstrings", "isolation", "legs", ["machine"]),
        ("Incline Dumbbell Press", "dumbbell", "chest", "compound", "push", ["bench", "dumbbells"]),
        ("Side Lateral Raise", "dumbbell", "shoulders", "isolation", "shoulders", ["dumbbells"]),
        ("Seated Cable Rows", "cable", "middle back", "compound", "pull", ["cable"]),
        ("Chin-Up", "body only", "lats", "compound", "pull", ["pull_up_bar"]),
        ("Ring Dips", "other", "triceps", "compound", "push", ["suspension"]),
        ("Hammer Curls", "dumbbell", "biceps", "isolation", "arms", ["dumbbells"]),
        ("Standing Calf Raises", "machine", "calves", "isolation", "calves", ["machine"]),
        ("Trap Bar Deadlift", "other", "quadriceps", "compound", "hinge", ["trap_bar"]),
        ("One-Arm Kettlebell Swings", "kettlebells", "hamstrings", "compound", "hinge", ["kettlebells"]),
    ])
    func movementAndEquipment(name: String, equipment: String, muscle: String, mechanic: String, pattern: String,
                              needs: [String]) throws {
        let attributes = try seed(entry(name, equipment: equipment, primary: [muscle], mechanic: mechanic))
        #expect(attributes["movement_pattern"] == [pattern])
        #expect(attributes["equipment"] ?? [] == needs)
    }

    /// "chin" is a word start, not a substring: "Smith Machine" isn't a chin-up.
    @Test func wordsMatchAtWordStarts() throws {
        let row = try seed(entry("Smith Machine Bent Over Row", equipment: "machine", primary: ["middle back"], force: "pull"))
        #expect(row["tags"]?.contains("horizontal_pull") == true)
    }

    @Test func holdsAndCardioAreTimed() throws {
        let plank = try seed(entry("Side Bridge", primary: ["abdominals"], force: "static"))
        #expect(plank["tags"]?.contains("isometric") == true)
        let rower = try seed(entry("Rowing, Stationary", equipment: "machine", primary: ["quadriceps"], category: "cardio"))
        #expect(rower["equipment"] == ["rower"])
        #expect(rower["tags"]?.contains("timed") == true)
        #expect(Exercise(slug: "rowing", attributes: try ExerciseDBImporter.seed(
            entry("Rowing, Stationary", equipment: "machine", primary: ["quadriceps"], category: "cardio")).get().attributes)?.isTimed == true)
    }

    @Test func stretchesStrongmanAndBehindTheNeckAreSkipped() {
        #expect((try? ExerciseDBImporter.seed(entry("Hamstring Stretch", primary: ["hamstrings"], category: "stretching")).get()) == nil)
        #expect((try? ExerciseDBImporter.seed(entry("Atlas Stones", equipment: "other", primary: ["lower back"], category: "strongman")).get()) == nil)
        #expect((try? ExerciseDBImporter.seed(entry("Standing Barbell Press Behind Neck", equipment: "barbell", primary: ["shoulders"])).get()) == nil)
        #expect((try? ExerciseDBImporter.seed(entry("Mystery Contraption", equipment: "other", primary: ["chest"])).get()) == nil)
    }

    /// The author's card wins: same slug and attributes, plus the alias and what it lacked.
    @Test func cardsKeepTheirSlugAndGainTheAlias() throws {
        let card = TemplateSeed(kind: .exercise, name: "Dead Bug", slug: "dead-bug",
                                attributes: [TemplateAttribute(key: "movement_pattern", values: ["core"])])
        let entries = """
        [{"name": "Dead Bug", "category": "strength", "equipment": "body only", "mechanic": "compound", "force": "push",
          "level": "beginner", "primaryMuscles": ["abdominals"], "secondaryMuscles": []},
         {"name": "Hammer Curls", "category": "strength", "equipment": "dumbbell", "mechanic": "isolation", "force": "pull",
          "level": "beginner", "primaryMuscles": ["biceps"], "secondaryMuscles": ["forearms"]}]
        """
        let result = try ExerciseDBImporter.seeds(json: Data(entries.utf8), merging: [card])
        #expect(result.seeds.map(\.slug) == ["dead-bug", "hammer-curls"])
        let deadBug = Dictionary(uniqueKeysWithValues: result.seeds[0].attributes.map { ($0.key, $0.values) })
        #expect(deadBug["movement_pattern"] == ["core"])
        #expect(deadBug["aliases"] == ["Dead Bug"])
        #expect(deadBug["muscles_primary"] == ["rectus_abdominis"])
        #expect(deadBug["source"] == nil)
    }
}

@MainActor
struct ExerciseSearchTests {
    private static let seeds = try! Seeder.decode([TemplateSeed].self, "exercises", .main)
    private let catalog = seeds.compactMap { Exercise(slug: $0.slug, attributes: $0.attributes) }
    private let names = Dictionary(uniqueKeysWithValues: seeds.map { ($0.slug, $0.name) })

    private func settings(_ equipment: Set<String>, injured: [String] = [], avoid: Set<String> = []) -> TrainingSettings {
        TrainingSettings(age: 36, daysPerWeek: 3, sessionMinutes: 45, trainingDays: [0, 2, 4], workoutTime: 420,
                         equipment: equipment, injuredAreas: BodyArea.muscles(for: injured), avoidExercises: avoid,
                         maxWeeklySets: 60)
    }

    /// The bundled catalog is the extensive one, and the author's history still resolves to it.
    @Test func catalogIsExtensiveAndKeepsTheCards() {
        #expect(catalog.count >= 500)
        let slugs = Set(catalog.map(\.slug))
        for card in ["back-squat", "bench-press", "deadlift", "dumbbell-bench-press", "dumbbell-romanian-deadlift",
                     "dumbbell-row", "farmer-carry", "goblet-squat", "plank", "pull-up", "push-up", "dead-bug"] {
            #expect(slugs.contains(card), "\(card)")
        }
        #expect(Set(catalog.map(\.pattern)).isSuperset(of: ExerciseSearch.movements))
    }

    @Test func equipmentLimitsWhatIsFound() {
        let dumbbells = ExerciseSearch.find("chest", in: catalog, names: names, settings: settings(["dumbbells", "bench"]), limit: 100)
        #expect(!dumbbells.isEmpty)
        #expect(dumbbells.allSatisfy { slug in catalog.first { $0.slug == slug }!.equipment.isSubset(of: ["dumbbells", "bench"]) })
        #expect(!dumbbells.contains("bench-press"))
        let gym = ExerciseSearch.find("chest", in: catalog, names: names, settings: settings(Set(Profile.allEquipment)), limit: 100)
        #expect(gym.contains("bench-press"))
        #expect(gym.count > dumbbells.count)
    }

    @Test func movementsPlanesMusclesAndNames() {
        let gym = settings(Set(Profile.allEquipment))
        func find(_ query: String) -> [Exercise] {
            ExerciseSearch.find(query, in: catalog, names: names, settings: gym, limit: 50).map { slug in catalog.first { $0.slug == slug }! }
        }
        #expect(find("lunge").contains { $0.pattern == "lunge" })
        #expect(find("lunge").allSatisfy { $0.pattern == "lunge" || (names[$0.slug] ?? "").lowercased().contains("lunge") })
        #expect(!find("vertical pull").isEmpty && find("vertical pull").allSatisfy { $0.tags.contains("vertical_pull") })
        #expect(find("hamstrings").contains { $0.primaryMuscles.contains("hamstrings") })
        #expect(find("curl").allSatisfy { (names[$0.slug] ?? "").lowercased().contains("curl") })
        // The author's cards come first.
        #expect(find("squat").first?.slug == "back-squat")
    }

    @Test func injuriesAndAvoidsAreLeftOut() {
        let knees = ExerciseSearch.find("squat", in: catalog, names: names, settings: settings(Set(Profile.allEquipment), injured: ["knees"]), limit: 200)
        #expect(knees.allSatisfy { slug in !catalog.first { $0.slug == slug }!.muscles.contains("quads") })
        let avoid = ExerciseSearch.find("squat", in: catalog, names: names, settings: settings(Set(Profile.allEquipment), avoid: ["back-squat"]))
        #expect(!avoid.contains("back-squat"))
        let excluded = ExerciseSearch.find("squat", in: catalog, names: names, settings: settings(Set(Profile.allEquipment)), excluding: ["back-squat"])
        #expect(!excluded.contains("back-squat"))
    }
}
