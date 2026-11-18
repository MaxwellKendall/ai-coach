import Foundation

/// FIT-447: demo clips are loaded the first time an exercise is opened, then kept in Caches so they play offline
/// at the gym. No clip is bundled in the app (TKL-793 bundles only the photos the how-to falls back to). The system may clear Caches, and then a clip is just loaded again.
struct DemoCache {
    typealias Fetch = (URL) async throws -> (Data, URLResponse)

    let folder: URL
    let fetch: Fetch

    init(folder: URL = Self.defaultFolder,
         fetch: @escaping Fetch = { try await URLSession.shared.data(from: $0) }) {
        self.folder = folder
        self.fetch = fetch
    }

    /// Caches/demos. Debug only (TKL-793): `-demoCache <name>` uses Caches/<name>, so a UI test starts with nothing cached.
    static var defaultFolder: URL {
        #if DEBUG
        if let other = UserDefaults.standard.string(forKey: "demoCache"), !other.isEmpty { return URL.cachesDirectory.appending(path: other) }
        #endif
        return URL.cachesDirectory.appending(path: "demos")
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
