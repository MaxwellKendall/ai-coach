import ActivityKit
import Foundation

/// FIT-304: the live workout on the Lock Screen and in the Dynamic Island. Compiled into the widget extension too.
struct WorkoutActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// "Back Squat", or a warm-up step.
        var title: String
        /// "Set 2 of 3 · 185 lb × 5".
        var detail: String
        /// "2/3", the set of its rounds (or the warm-up's step).
        var step: String
        /// "185 lb", its right side; nil for a set with no load.
        var load: String?
        /// When the rest running now ends; the set shown is the one after it.
        var restEnds: Date?
        /// The session's sets done, 0...1.
        var progress: Double
        /// The lift in a word, for the Dynamic Island's left side beside `step`: "Squat", "Bench", "Warm-up".
        var lift: String = ""
        /// The set exactly, for its right side outside a rest: "185×5", "×10", "30 s".
        var set: String = ""
    }

    /// The lifter's plate color (Plate's raw value), for the countdown.
    var plate: String

    /// FIT-304: a lift in a word for the Dynamic Island: "Back Squat" → "Squat", "Bench Press" → "Bench",
    /// "Standing Military Press" → "Press", "Romanian Deadlift" → "RDL".
    static func short(_ name: String) -> String {
        if name.localizedCaseInsensitiveContains("romanian deadlift") { return "RDL" }
        let skip: Set<String> = ["back", "barbell", "dumbbell", "standing", "seated", "front", "the"]
        let words = name.split(separator: " ").map(String.init).filter { !skip.contains($0.lowercased()) }
        guard let first = words.first else { return name }
        if words.count > 1, words.last == "Press", !["Bench", "Leg", "Floor"].contains(first) { return "Press" }
        return first
    }
}
