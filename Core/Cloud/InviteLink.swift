import Foundation

/// FIT-58/105: a group invite as a link. join.barbrabell.com/CODE opens the app on the Join sheet when it's
/// installed (Associated Domains), and the invite page with the App Store when it isn't.
enum InviteLink {
    /// Each build invites to its own backend's groups: Debug to dev, Release (TestFlight, App Store) to prod.
    #if DEBUG
    static let base = URL(string: "https://dev.barbrabell.com/join/")!
    #else
    static let base = URL(string: "https://join.barbrabell.com/")!
    #endif

    static func url(code: String) -> URL { base.appending(path: code) }

    /// The code in a link the app was opened with, or nil when it isn't an invite.
    static func code(from url: URL) -> String? {
        guard url.scheme == "https", let host = url.host()?.lowercased(),
              host == "barbrabell.com" || host.hasSuffix(".barbrabell.com") else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        let code: String?
        switch parts.count {
        case 2 where parts[0] == "join": code = parts[1]
        case 1 where host.hasPrefix("join."): code = parts[0]
        default: code = nil
        }
        // Codes are the first 8 characters of an ID, upper-cased (infra/resolvers/createGroup.js).
        guard let code = code?.uppercased(), code.count == 8, code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return code
    }
}
