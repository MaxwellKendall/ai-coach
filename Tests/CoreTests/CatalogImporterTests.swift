import Foundation
import Testing
@testable import AICoach

private let fixtures = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Fixtures")

private func fixture(_ name: String) throws -> String {
    try String(contentsOf: fixtures.appending(path: name), encoding: .utf8)
}

struct CatalogImporterTests {
    @Test func exerciseCardKeepsFrontMatterAndSections() throws {
        let seed = try #require(CatalogImporter.exercise(markdown: try fixture("bench-press.md"), fileName: "bench-press.md"))
        #expect(seed.kind == .exercise)
        #expect(seed.name == "Bench Press")
        #expect(seed.slug == "bench-press")
        #expect(seed.attributes.map(\.key) == [
            "movement_pattern", "muscles_primary", "muscles_secondary", "equipment", "difficulty", "fatigue_cost",
            "technique_demand", "substitutes", "tags", "cues", "programming_notes", "warm_up_protocol",
        ])
        let byKey = Dictionary(uniqueKeysWithValues: seed.attributes.map { ($0.key, $0.values) })
        #expect(byKey["muscles_primary"] == ["pectorals", "anterior_deltoids", "triceps"])
        #expect(byKey["cues"]?.count == 7)
        #expect(byKey["cues"]?.first?.hasPrefix("Set up: 5 points of contact") == true)
        // Wrapped prose lines join into a single paragraph.
        #expect(byKey["programming_notes"]?.count == 1)
        #expect(byKey["programming_notes"]?.first?.contains("1.0× BW bench press (200 lb at 200 lb bodyweight). Historical") == true)
    }

    @Test func emptyListsAreDropped() throws {
        let seed = try #require(CatalogImporter.exercise(markdown: try fixture("plank.md"), fileName: "plank.md"))
        #expect(seed.name == "Plank (Forearm)")
        #expect(!seed.attributes.contains { $0.key == "equipment" })
    }

    @Test func recipeUsesFileNameAsSlugAndSkipsPlaceholders() throws {
        let ratings = CatalogImporter.ratings(yaml: """
            last_updated: 2026-05-06
            recipes:
              bang-bang-salmon:
                ratings:
                  effort: 4
                  bang_for_buck: 2
                  protein: 5
                  composite: 3.4
                  rated_on: 2026-05-06
                last_used: 2026-04-30
              other:
                ratings:
                  taste: 3
                  is_memorized: false
            """)
        let seed = try #require(CatalogImporter.recipe(
            markdown: try fixture("bang-bang-salmon.md"), fileName: "bang-bang-salmon.md", ratings: ratings))
        #expect(seed.kind == .recipe)
        #expect(seed.slug == "bang-bang-salmon")
        #expect(seed.values("servings") == ["4"])
        #expect(seed.values("cost_per_serving").isEmpty)
        #expect(seed.values("ingredients").count == 11)
        #expect(seed.values("ingredients").first == "4 salmon filets, (about 1½ pounds, skins on)")
        #expect(seed.values("instructions").count == 9)
        #expect(seed.values("instructions").first?.hasPrefix("Preheat the oven") == true)
        #expect(seed.values("protein_rating") == ["5"])
        #expect(seed.values("composite_rating") == ["3.4"])
        #expect(seed.values("rated_on_rating").isEmpty)
        #expect(ratings["other"]?.map(\.0) == ["taste"])
    }

    @Test func apostropheInName() throws {
        let seed = try #require(CatalogImporter.recipe(
            markdown: try fixture("homemade-shepherd-s-pie.md"), fileName: "homemade-shepherd-s-pie.md"))
        #expect(seed.name == "Homemade Shepherd's Pie")
    }

    @Test func unknownServingsIsDropped() {
        let seed = CatalogImporter.recipe(markdown: """
            ---
            name: Meatballs
            servings: unknown
            effort: low
            ---
            """, fileName: "meatballs.md")
        #expect(seed?.values("servings") == [])
        #expect(seed?.values("effort") == ["low"])
    }

    @Test func fileWithoutFrontMatterIsSkipped() {
        #expect(CatalogImporter.exercise(markdown: "# Just a heading", fileName: "x.md") == nil)
    }

    @Test func pantryStopsBeforeNonGrocery() throws {
        let items = CatalogImporter.pantry(yaml: try fixture("pantry.yaml"))
        let names = items.map(\.name)
        #expect(names.contains("olive oil"))
        #expect(names.contains("greek yogurt"))
        #expect(names.contains("frozen spinach"))
        #expect(!names.contains("ricola lozenge"))
        #expect(!names.contains("status"))
        #expect(items.filter { !$0.stocked }.isEmpty)
    }

    @Test func pantryStatusOtherThanStockedIsOut() {
        let items = CatalogImporter.pantry(yaml: """
            staples:
              olive oil:
                status: out
              salt:
                status: stocked
            """)
        #expect(items == [PantrySeed(name: "olive oil", stocked: false), PantrySeed(name: "salt", stocked: true)])
    }
}

struct SlugTests {
    @Test(arguments: [
        ("Plank (Forearm)", "plank-forearm"),
        ("Homemade Shepherd's Pie", "homemade-shepherd-s-pie"),
        ("Crème Fraîche Galette", "creme-fraiche-galette"),
        ("  ", ""),
    ])
    func make(name: String, slug: String) {
        #expect(Slug.make(name) == slug)
    }

    @Test func uniqueAppendsCounter() {
        #expect(Slug.unique("Push-up", existing: ["push-up", "push-up-2"]) == "push-up-3")
        #expect(Slug.unique("!!", existing: []) == "item")
    }
}

extension TemplateSeed {
    func values(_ key: String) -> [String] { attributes.first { $0.key == key }?.values ?? [] }
}
