import Foundation

/// FIT-317: each catalog exercise's start and end photos from free-exercise-db (public domain, the Unlicense:
/// Tests/Fixtures/free-exercise-db.LICENSE.md), as paths under its `exercises/` folder ("Air_Bike/0.jpg"). An
/// exercise imported from it is matched by name; one of the author's cards by the name it was merged under (its
/// `aliases`, ExerciseDBImporter.merged). Bundled as Resources/Seed/exercise-photos.json; hosting is FIT-318.
enum ExercisePhotos {
    private struct Entry: Decodable {
        var name: String
        var images: [String]?
    }

    struct Map {
        /// Slug → [start, end].
        var photos: [String: [String]]
        /// Catalog slugs with none, sorted.
        var missing: [String]
    }

    static func map(json: Data, catalog: [TemplateSeed]) throws -> Map {
        let entries = try JSONDecoder().decode([Entry].self, from: json)
        let byName = Dictionary(entries.compactMap { entry in entry.images.flatMap { $0.isEmpty ? nil : (entry.name, $0) } },
                                uniquingKeysWith: { first, _ in first })
        var photos: [String: [String]] = [:]
        var missing: [String] = []
        for seed in catalog where seed.kind == .exercise {
            let names = [seed.name] + seed.attributes.filter { $0.key == "aliases" }.flatMap(\.values)
            if let images = names.lazy.compactMap({ byName[$0] }).first {
                photos[seed.slug] = images
            } else {
                missing.append(seed.slug)
            }
        }
        return Map(photos: photos, missing: missing.sorted())
    }

    /// FIT-318: an exercise's start and end photos on the site, none when free-exercise-db has none. Debug only:
    /// `-exercisePhotos https://raw.githubusercontent.com/yuhonas/free-exercise-db/main` reads them from its repository
    /// (the same exercises/ layout), to look at them before the upload.
    static func urls(_ slug: String) -> [URL] {
        var base = Backend.current.web
        #if DEBUG
        if let other = UserDefaults.standard.string(forKey: "exercisePhotos").flatMap(URL.init(string:)) { base = other }
        #endif
        return (bundled[slug] ?? []).map { base.appending(path: "exercises/\($0)") }
    }

    /// The bundled map, slug → [start, end]; empty when it's missing.
    static let bundled: [String: [String]] = Bundle.main.url(forResource: "exercise-photos", withExtension: "json")
        .flatMap { try? JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: $0)) } ?? [:]
}
