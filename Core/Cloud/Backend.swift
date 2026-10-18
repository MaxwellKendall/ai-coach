import Foundation

/// Which backend this launch talks to. Release (TestFlight, the App Store) is always prod. A Debug build is dev unless
/// the You screen's switch (or `-backend prod`) says prod; each keeps its own store on the phone, so dev and prod data
/// never meet, and it's read once at launch because Amplify is configured once.
enum Backend: String, CaseIterable {
    case dev, prod

    #if DEBUG
    static let current = Backend(rawValue: UserDefaults.standard.string(forKey: "backend") ?? "") ?? .dev
    #else
    static let current = Backend.prod
    #endif

    /// Where this backend's data lives on the phone; nil is SwiftData's default store, the one each build always used.
    var store: URL? {
        #if DEBUG
        self == .prod ? URL.applicationSupportDirectory.appending(path: "prod.store") : nil
        #else
        nil
        #endif
    }
}
