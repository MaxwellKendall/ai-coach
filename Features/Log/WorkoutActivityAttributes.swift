import ActivityKit
import Foundation

/// FIT-304: the live workout on the Lock Screen and in the Dynamic Island. Compiled into the widget extension too.
struct WorkoutActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// "Back Squat", or a warm-up step.
        var title: String
        /// "Set 2 of 3 · 185 lb × 5".
        var detail: String
        /// "2/3", the Dynamic Island's left side.
        var step: String
        /// "185 lb", its right side; nil for a set with no load.
        var load: String?
        /// When the rest running now ends; the set shown is the one after it.
        var restEnds: Date?
        /// The session's sets done, 0...1.
        var progress: Double
    }

    /// The lifter's plate color (Plate's raw value), for the countdown.
    var plate: String
}
