import Foundation

/// FIT-454: the server's monetization switch (shared/monetization.ts), read at launch from /monetization.json and kept
/// on the phone for the next launch. hard: the first launch's paywall has no way past it. freemium: it has Not Now,
/// into the free app. Until the server has answered once, freemium, as the server's own default.
enum Monetization: String, Codable, Sendable {
    case hard, freemium

    private static let savedKey = "monetization.saved"

    static var current: Monetization {
        #if DEBUG
        // `-monetization hard|freemium`: either one, without the server (UI tests, screenshots).
        if let forced = UserDefaults.standard.string(forKey: "monetization").flatMap(Monetization.init(rawValue:)) { return forced }
        #endif
        return UserDefaults.standard.string(forKey: savedKey).flatMap(Monetization.init(rawValue:)) ?? .freemium
    }

    /// Offline, or anything the app doesn't know, keeps what was saved.
    static func refresh(from web: URL = Backend.current.web) async {
        #if DEBUG
        if DebugRole.uiTesting || DebugRole.demo { return }
        #endif
        struct Answer: Decodable { var strategy: String }
        guard let (data, response) = try? await URLSession.shared.data(from: web.appending(path: "monetization.json")),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let answer = try? JSONDecoder().decode(Answer.self, from: data),
              let strategy = Monetization(rawValue: answer.strategy) else { return }
        UserDefaults.standard.set(strategy.rawValue, forKey: savedKey)
    }
}
