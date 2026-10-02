import Foundation

enum Slug {
    /// "Plank (Forearm)" → "plank-forearm"
    static func make(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        return folded.split { !($0.isLetter || $0.isNumber) || !$0.isASCII }.joined(separator: "-")
    }

    static func unique(_ name: String, existing: Set<String>) -> String {
        let base = make(name).isEmpty ? "item" : make(name)
        var candidate = base
        var n = 2
        while existing.contains(candidate) {
            candidate = "\(base)-\(n)"
            n += 1
        }
        return candidate
    }
}
