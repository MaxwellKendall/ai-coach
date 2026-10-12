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

    /// FIT-109: the code in pasted text: an invite link, the message it came in, or the code on its own.
    static func code(pasted text: String) -> String? {
        for word in text.split(whereSeparator: \.isWhitespace) {
            let word = word.trimmingCharacters(in: .punctuationCharacters.subtracting(["/", ":"]))
            if let url = URL(string: word), url.scheme != nil, let code = code(from: url) { return code }
            // On its own, a code has to look like one: 8 hex digits, so "tomorrow" isn't taken for one.
            if word.count == 8, word.allSatisfy(\.isHexDigit) { return word.uppercased() }
        }
        return nil
    }

    /// FIT-113/111: the id in a shared session's or program's link (barbrabell.com/s/ae79125c4c25, /p/…), or nil.
    static func shared(_ kind: String, from url: URL) -> String? {
        guard url.scheme == "https", let host = url.host()?.lowercased(),
              host == "barbrabell.com" || host.hasSuffix(".barbrabell.com") else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, parts[0] == kind, parts[1].count == 12, parts[1].allSatisfy(\.isHexDigit) else { return nil }
        return parts[1].lowercased()
    }

    static func shared(_ kind: String, pasted text: String) -> String? {
        text.split(whereSeparator: \.isWhitespace).lazy.compactMap { word in
            URL(string: word.trimmingCharacters(in: .punctuationCharacters.subtracting(["/", ":"]))).flatMap { shared(kind, from: $0) }
        }.first
    }

    static func session(from url: URL) -> String? { shared("s", from: url) }
    static func session(pasted text: String) -> String? { shared("s", pasted: text) }
    static func program(from url: URL) -> String? { shared("p", from: url) }
    static func program(pasted text: String) -> String? { shared("p", pasted: text) }

    /// FIT-122: a gift's code: 12 letters and digits without 0, 1, I or O, typed any way or in its link
    /// (barbrabell.com/g/ABCDEFGHJKLM).
    static func gift(_ text: String) -> String? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: text), url.scheme == "https" {
            guard let host = url.host()?.lowercased(), host == "barbrabell.com" || host.hasSuffix(".barbrabell.com") else { return nil }
            let parts = url.pathComponents.filter { $0 != "/" }
            guard parts.count == 2, parts[0] == "g" else { return nil }
            text = parts[1]
        }
        let code = text.uppercased().filter { $0 != "-" && !$0.isWhitespace }
        let alphabet = Set("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")
        return code.count == 12 && code.allSatisfy(alphabet.contains) ? code : nil
    }

    static func gift(from url: URL) -> String? { url.scheme == "https" ? gift(url.absoluteString) : nil }
}
