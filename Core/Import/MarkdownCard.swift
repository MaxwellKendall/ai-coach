import Foundation

/// A markdown file with flat YAML front matter (`key: value` or `key: [a, b]`) and `## Heading` sections.
/// This is the shape of fitness-planner exercise cards and grocery-planner recipes.
struct MarkdownCard {
    var fields: [(key: String, values: [String])] = []
    var sections: [(heading: String, items: [String])] = []

    func field(_ key: String) -> [String] {
        fields.first { $0.key == key }?.values ?? []
    }

    init?(_ text: String) {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return nil }

        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" ") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let raw = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields.append((key, Self.values(raw)))
        }

        var heading: String?
        var body: [String] = []
        func flush() {
            if let heading { sections.append((heading, Self.items(body))) }
            body = []
        }
        for line in lines[(end + 1)...] {
            if line.hasPrefix("## ") {
                flush()
                heading = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else {
                body.append(line)
            }
        }
        flush()
    }

    private static func values(_ raw: String) -> [String] {
        if raw.hasPrefix("["), raw.hasSuffix("]") {
            return raw.dropFirst().dropLast().split(separator: ",")
                .map { unquote($0.trimmingCharacters(in: .whitespaces)) }
                .filter { !$0.isEmpty }
        }
        let value = unquote(raw)
        return value.isEmpty ? [] : [value]
    }

    private static func unquote(_ s: String) -> String {
        for q in ["\"", "'"] where s.count >= 2 && s.hasPrefix(q) && s.hasSuffix(q) {
            return String(s.dropFirst().dropLast())
        }
        return s
    }

    /// List items ("- x", "1. x") become one item each; wrapped prose lines join into one paragraph.
    private static func items(_ lines: [String]) -> [String] {
        var result: [String] = []
        var paragraph: [String] = []
        func endParagraph() {
            if !paragraph.isEmpty { result.append(paragraph.joined(separator: " ")) }
            paragraph = []
        }
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty {
                endParagraph()
            } else if t.hasPrefix("- ") || t.hasPrefix("* ") {
                endParagraph()
                result.append(String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            } else if let dot = t.firstIndex(of: "."), t[..<dot].allSatisfy(\.isNumber), dot != t.startIndex {
                endParagraph()
                result.append(t[t.index(after: dot)...].trimmingCharacters(in: .whitespaces))
            } else {
                paragraph.append(t)
            }
        }
        endParagraph()
        return result
    }
}
