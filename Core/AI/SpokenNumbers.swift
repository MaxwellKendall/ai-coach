import Foundation

/// The numbers a sentence says, from digits ("235") or words ("two thirty five", "thirty", "four").
/// Used to check that a number the model returned was actually said.
enum SpokenNumbers {
    private static let units = ["zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
                                "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
                                "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19]
    private static let tens = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70,
                               "eighty": 80, "ninety": 90]

    static func values(in text: String) -> Set<Double> {
        let words = text.lowercased().replacingOccurrences(of: "-", with: " ").split { !$0.isLetter && !$0.isNumber }.map(String.init)
        var found = Set(words.compactMap(Double.init))
        // Runs of number words: "thirty five" is 35; "two thirty five" is 235 (said like a weight).
        var run: [Int] = []
        func close() {
            var pairs: [Int] = []
            var index = 0
            while index < run.count {
                if run[index] >= 20, run[index] % 10 == 0, index + 1 < run.count, run[index + 1] < 10 {
                    pairs.append(run[index] + run[index + 1]); index += 2
                } else {
                    pairs.append(run[index]); index += 1
                }
            }
            // A weight said in two parts is only the weight, not its parts.
            index = 0
            while index < pairs.count {
                if pairs[index] < 10, index + 1 < pairs.count, pairs[index + 1] >= 10, pairs[index + 1] < 100 {
                    found.insert(Double(pairs[index] * 100 + pairs[index + 1])); index += 2
                } else {
                    found.insert(Double(pairs[index])); index += 1
                }
            }
            run = []
        }
        for word in words {
            if let value = units[word] ?? tens[word] { run.append(value) } else if word == "hundred", let last = run.popLast() {
                run.append(last * 100)
            } else { close() }
        }
        close()
        return found
    }

    /// Time said next to its unit: "thirty minutes" is 30, "an hour" 60, "half an hour" 30, "1.5 hours" 90.
    static func minutes(in text: String) -> Int? {
        let words = text.lowercased().replacingOccurrences(of: "-", with: " ").split { !$0.isLetter && !$0.isNumber && $0 != "." }
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        guard let unit = words.firstIndex(where: { $0.hasPrefix("min") || $0.hasPrefix("hour") }) else { return nil }
        let before = words[max(0, unit - 3)..<unit]
        let perUnit = words[unit].hasPrefix("hour") ? 60.0 : 1.0
        if perUnit == 60, before.suffix(3).joined(separator: " ").hasSuffix("half an") { return 30 }
        let amount = before.last.flatMap(Double.init) ?? values(in: before.joined(separator: " ")).max()
            ?? (before.last == "an" || before.last == "a" ? 1 : nil)
        return amount.map { Int(($0 * perUnit).rounded()) }
    }
}
