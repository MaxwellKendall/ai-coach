import Foundation
import SwiftData
import Testing
@testable import AICoach

private let repoRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

@MainActor
struct SeederTests {
    @Test func seedsBundledCatalogOnceIntoEmptyStore() throws {
        let context = ModelContext(try AppSchema.container(inMemory: true))
        try Seeder.seedIfEmpty(context)
        let templates = try context.fetch(FetchDescriptor<Template>())
        #expect(templates.filter { $0.kind == .exercise }.count == 11)
        #expect(templates.filter { $0.kind == .recipe }.count == 185)
        #expect(try context.fetchCount(FetchDescriptor<PantryItem>()) > 0)

        try Seeder.seedIfEmpty(context)
        #expect(try context.fetchCount(FetchDescriptor<Template>()) == templates.count)
    }
}

/// Regenerates Resources/Seed from the sibling repos (CLAUDE.md §6). Off by default:
/// `TEST_RUNNER_REGENERATE_SEED=1 xcodebuild … test -only-testing:AICoachTests/SeedGenerator`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["REGENERATE_SEED"] == "1"))
struct SeedGenerator {
    let dev = repoRoot.deletingLastPathComponent()

    @Test func writeSeed() throws {
        let exercises = try markdownFiles(in: "fitness-planner/exercise-library").compactMap {
            CatalogImporter.exercise(markdown: try String(contentsOf: $0, encoding: .utf8), fileName: $0.lastPathComponent)
        }
        let ratings = CatalogImporter.ratings(
            yaml: try String(contentsOf: dev.appending(path: "grocery-planner/recent-recipes.yaml"), encoding: .utf8))
        var skipped: [String] = []
        let recipes = try markdownFiles(in: "grocery-planner/recipes").compactMap { url in
            let seed = CatalogImporter.recipe(markdown: try String(contentsOf: url, encoding: .utf8),
                                              fileName: url.lastPathComponent, ratings: ratings)
            if seed == nil { skipped.append(url.lastPathComponent) }
            return seed
        }
        let pantry = CatalogImporter.pantry(
            yaml: try String(contentsOf: dev.appending(path: "grocery-planner/pantry.yaml"), encoding: .utf8))

        try write(exercises, "exercises")
        try write(recipes, "recipes")
        try write(pantry, "pantry")
        print("Seed: \(exercises.count) exercises, \(recipes.count) recipes, \(pantry.count) pantry items, skipped \(skipped)")
        #expect(skipped.isEmpty)
    }

    private func markdownFiles(in path: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: dev.appending(path: path), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func write<T: Encodable>(_ value: T, _ name: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: repoRoot.appending(path: "Resources/Seed/\(name).json"))
    }
}
