import Foundation
import Testing
@testable import AICoach

/// FIT-447: the first batch of Higgsfield form demos, mapped to the catalog, hosted on our own site and cached on the phone.
struct ExerciseDemosTests {
    private let catalog = try! Seeder.decode([TemplateSeed].self, "exercises", .main)

    private struct Batch: Decodable {
        struct Demo: Decodable { var slug: String; var name: String; var id: String; var source: URL }
        var demos: [Demo]
    }

    private let batch = try! JSONDecoder().decode(Batch.self, from: Data(contentsOf: URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "scripts/demos/higgsfield-batch-1.json")))

    /// All 28 chosen takes, each on a different catalog exercise, by the app's slug.
    @Test func batchIsKeyedByCatalogSlugs() {
        let exercises = Set(catalog.filter { $0.kind == .exercise }.map(\.slug))
        #expect(batch.demos.count == 28)
        #expect(Set(batch.demos.map(\.slug)).count == 28)
        for demo in batch.demos {
            #expect(exercises.contains(demo.slug), "\(demo.name) → \(demo.slug)")
            #expect(demo.source.lastPathComponent.contains(demo.id), "\(demo.slug)")
        }
    }

    /// The app only ever plays from our site: never the Higgsfield CDN it was downloaded from.
    @Test func playsOnlyFromOurSite() {
        let site = Backend.current.web.host()
        for slug in ExerciseDemos.bundled {
            #expect(ExerciseDemos.url(slug)?.host() == site, "\(slug)")
            #expect(ExerciseDemos.poster(slug)?.host() == site, "\(slug)")
        }
        let sources = Set(batch.demos.compactMap { $0.source.host() })
        #expect(!sources.contains(site ?? ""))
    }

    /// The poster frame sits next to the clip; none for an exercise without a clip.
    @Test func posterNextToTheClip() {
        for slug in ExerciseDemos.bundled {
            #expect(ExerciseDemos.poster(slug)?.absoluteString == ExerciseDemos.url(slug)?.absoluteString
                .replacingOccurrences(of: ".mp4", with: ".jpg"))
        }
        #expect(ExerciseDemos.poster("not-an-exercise") == nil)
    }

    private func folder() -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "demo-cache-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func response(_ url: URL, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    /// First view downloads the clip into the cache; after that it plays from the phone, with no network.
    @Test func downloadsOnceThenPlaysOffline() async throws {
        let remote = URL(string: "https://barbrabell.com/exercises/demos/goblet-squat.mp4")!
        var fetches = 0
        let cache = DemoCache(folder: folder()) { url in
            fetches += 1
            return (Data("clip".utf8), Self.response(url, 200))
        }
        let first = try await cache.local(remote)
        #expect(first.isFileURL && first.lastPathComponent == "goblet-squat.mp4")
        #expect(try Data(contentsOf: first) == Data("clip".utf8))
        let offline = DemoCache(folder: cache.folder) { _ in throw URLError(.notConnectedToInternet) }
        #expect(try await offline.local(remote) == first)
        #expect(fetches == 1)
    }

    /// A clip that isn't on the site yet (404) or can't load fails, and nothing broken is left in the cache.
    @Test func missingClipFailsAndCachesNothing() async {
        let remote = URL(string: "https://barbrabell.com/exercises/demos/plank.mp4")!
        let cache = DemoCache(folder: folder()) { url in (Data("<html>Not found</html>".utf8), Self.response(url, 404)) }
        await #expect(throws: (any Error).self) { try await cache.local(remote) }
        #expect(!FileManager.default.fileExists(atPath: cache.folder.appending(path: "plank.mp4").path()))
    }
}
