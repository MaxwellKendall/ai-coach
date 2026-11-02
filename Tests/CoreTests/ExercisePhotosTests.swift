import Foundation
import Testing
@testable import AICoach

/// FIT-317: free-exercise-db's photos matched to the catalog.
struct ExercisePhotosTests {
    private let catalog = try! Seeder.decode([TemplateSeed].self, "exercises", .main)
    private let json = try! Data(contentsOf: URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures/free-exercise-db.json"))

    /// The ready-made programs' exercises, every choice of each item.
    private var programExercises: Set<String> {
        Set(ReadyProgram.all.flatMap(\.sessions).flatMap(\.exercises).flatMap(\.choices))
    }

    @Test func matchesImportedExercisesByNameAndCardsByAlias() throws {
        let map = try ExercisePhotos.map(json: json, catalog: catalog)
        // An imported exercise, by its own name; one of the author's cards, by the name it was merged under.
        #expect(map.photos["air-bike"] == ["Air_Bike/0.jpg", "Air_Bike/1.jpg"])
        #expect(map.photos["back-squat"] == ["Barbell_Squat/0.jpg", "Barbell_Squat/1.jpg"])
        #expect(map.photos.count + map.missing.count == catalog.filter { $0.kind == .exercise }.count)
    }

    /// The bundled map is what the generator writes from today's catalog (SeedGenerator.writePhotos).
    @Test func bundledMapIsCurrent() throws {
        #expect(ExercisePhotos.bundled == (try ExercisePhotos.map(json: json, catalog: catalog)).photos)
    }

    /// FIT-318: on the site, under /exercises/, by free-exercise-db's own paths; none for an exercise without photos.
    @Test func urlsOnTheSite() {
        let base = Backend.current.web.absoluteString
        #expect(ExercisePhotos.urls("back-squat").map(\.absoluteString) == ["\(base)/exercises/Barbell_Squat/0.jpg", "\(base)/exercises/Barbell_Squat/1.jpg"])
        #expect(ExercisePhotos.urls("dumbbell-romanian-deadlift").isEmpty)
    }

    /// Every program exercise has its two photos, except the author's own card free-exercise-db has no match for.
    @Test func programExercisesHavePhotos() {
        let missing = programExercises.filter { ExercisePhotos.bundled[$0]?.count != 2 }
        #expect(missing == ["dumbbell-romanian-deadlift"])
    }
}
