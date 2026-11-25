import ActivityKit
import Foundation

/// FIT-304: starts, follows and ends the live workout's Live Activity. It's kept by id and looked up off the main
/// actor, since an Activity isn't Sendable.
@MainActor final class WorkoutActivity {
    private typealias Live = Activity<WorkoutActivityAttributes>
    private var id: String?

    func start(_ state: WorkoutActivityAttributes.ContentState) {
        guard id == nil, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let staleIDs = Set(Live.activities.map(\.id))
        id = try? Live.request(attributes: WorkoutActivityAttributes(plate: Plate.current.rawValue),
                               content: Self.content(state)).id
        if !staleIDs.isEmpty {
            Task.detached {
                for activity in Live.activities where staleIDs.contains(activity.id) {
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
            }
        }
    }

    /// TKL-801: a rest's end is the content's stale date, so the island shows "Rest over" even if the app is asleep
    /// then; `alert` lights up the island and plays a sound (when a rest ends with the app in the background).
    func update(_ state: WorkoutActivityAttributes.ContentState, alert: AlertConfiguration? = nil) {
        guard let id else { return }
        let content = Self.content(state)
        Task.detached { await Live.activities.first { $0.id == id }?.update(content, alertConfiguration: alert) }
    }

    /// What iOS holds: the state, going stale at the rest's end, when the island reads "Rest over" with no update from
    /// the app (TKL-1023: so a suspended app still shows it).
    nonisolated static func content(_ state: WorkoutActivityAttributes.ContentState) -> ActivityContent<WorkoutActivityAttributes.ContentState> {
        ActivityContent(state: state, staleDate: state.restEnds)
    }

    func end() {
        guard let id else { return }
        self.id = nil
        Task.detached { await Live.activities.first { $0.id == id }?.end(nil, dismissalPolicy: .immediate) }
    }

    /// Any left on the Lock Screen by a workout the app was closed during.
    nonisolated static func endAll() {
        Task.detached { for activity in Live.activities { await activity.end(nil, dismissalPolicy: .immediate) } }
    }
}
