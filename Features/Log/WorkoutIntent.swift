import AppIntents
import Foundation

/// TKL-801: the Live Activity's buttons, Done set, −10s, +10s and Skip. Compiled into the widget extension too (its
/// buttons name the intent); the system runs `perform` in the app, waking it in the background if it must, where
/// it changes the workout on screen exactly as the workout screen's own buttons do.
struct WorkoutIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Workout step"
    static let isDiscoverable = false

    /// A `LiveWorkout.Action`'s raw value: "done", "less", "more" or "skip".
    @Parameter(title: "Action") var action: String

    init() {}

    init(_ action: String) {
        self.action = action
    }

    @MainActor func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        if let action = LiveWorkout.Action(rawValue: action) { LiveWorkout.current?.handle(action) }
        #endif
        return .result()
    }
}
