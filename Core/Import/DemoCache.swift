import Foundation

/// FIT-447: demo clips are loaded the first time an exercise is opened, then kept in Caches so they play offline
/// at the gym. Nothing is bundled in the app. The system may clear Caches, and then a clip is just loaded again.
struct DemoCache {
    typealias Fetch = (URL) async throws -> (Data, URLResponse)

    let folder: URL
    let fetch: Fetch

    init(folder: URL = URL.cachesDirectory.appending(path: "demos"),
         fetch: @escaping Fetch = { try await URLSession.shared.data(from: $0) }) {
        self.folder = folder
        self.fetch = fetch
    }

    /// The clip on the phone, loaded first if needed. Throws when it can't load (offline, or not on the site yet).
    func local(_ remote: URL) async throws -> URL {
        let file = folder.appending(path: remote.lastPathComponent)
        if FileManager.default.fileExists(atPath: file.path()) { return file }
        let (data, response) = try await fetch(remote)
        guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { throw URLError(.fileDoesNotExist) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        return file
    }
}
