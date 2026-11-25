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
        /// TKL-934: when the current rest began, for `ProgressView(timerInterval:)` countdown rings.
        var restStarted: Date? = nil
        /// When the rest running now ends; the set shown is the one after it.
        var restEnds: Date?
        /// The session's sets done, 0...1.
        var progress: Double
        /// The lift in a word, for the Dynamic Island's left side beside `step`: "Squat", "Bench", "Warm-up".
        var lift: String = ""
        /// The set exactly, for its right side outside a rest: "185×5", "×10", "30 s".
        var set: String = ""
        /// TKL-801: what comes after the set shown, "Next: Bench 135×8", or "Last set".
        var next: String = ""
        /// Which lift of the session, "Lift 3 of 6" (0 while warming up).
        var liftIndex: Int = 0
        var lifts: Int = 0
        /// This lift's sets done and planned, for its dots (the warm-up's steps while warming up).
        var setsDone: Int = 0
        var sets: Int = 0
        /// The running rest's length, so its bar drains from full.
        var restTotal: TimeInterval?
        /// A rest just ran out and the set shown is up: "Rest over".
        var restOver: Bool = false
        /// Every set is done: the finish card is on screen.
        var isDone: Bool = false

        var warming: Bool { lift == "Warm-up" }
        /// The rest's start, for a countdown ring that drains as it runs.
        var restStarts: Date? { restStarted ?? restEnds.map { $0 - (restTotal ?? 60) } }
    }

    /// The lifter's plate color (Plate's raw value), for the countdown.
    var plate: String

    /// FIT-304: a lift in a word for the Dynamic Island: "Back Squat" → "Squat", "Bench Press" → "Bench",
    /// "Standing Military Press" → "Press", "Romanian Deadlift" → "RDL".
    nonisolated static func short(_ name: String) -> String {
        if name.localizedCaseInsensitiveContains("romanian deadlift") { return "RDL" }
        let skip: Set<String> = ["back", "barbell", "dumbbell", "standing", "seated", "front", "the"]
        let words = name.split(separator: " ").map(String.init).filter { !skip.contains($0.lowercased()) }
        guard let first = words.first else { return name }
        if words.count > 1, words.last == "Press", !["Bench", "Leg", "Floor"].contains(first) { return "Press" }
        return first
    }
}

/// What the Live Activity shows (TKL-801; here so the app's tests reach it): a set to do, a rest running, a rest that just ran out, or the session done.
enum ActivityPhase: Equatable {
    case lifting
    case resting(starts: Date, ends: Date)
    case restOver
    case done

    init(_ state: WorkoutActivityAttributes.ContentState, stale: Bool, now: Date = .now) {
        if state.isDone {
            self = .done
        } else if let ends = state.restEnds, let starts = state.restStarts {
            // Stale is the rest's end passing with the app asleep.
            self = stale || ends <= now ? .restOver : .resting(starts: starts, ends: ends)
        } else {
            self = state.restOver ? .restOver : .lifting
        }
    }
}
