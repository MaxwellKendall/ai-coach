import ActivityKit
import Foundation

/// FIT-304: starts, follows and ends the live workout's Live Activity. It's kept by id and looked up off the main
/// actor, since an Activity isn't Sendable.
@MainActor final class WorkoutActivity {
    private typealias Live = Activity<WorkoutActivityAttributes>
    private var id: String?

    func start(_ state: WorkoutActivityAttributes.ContentState) {
        guard id == nil, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        Self.endAll()
        id = try? Live.request(attributes: WorkoutActivityAttributes(plate: Plate.current.rawValue),
                               content: ActivityContent(state: state, staleDate: nil)).id
    }

    func update(_ state: WorkoutActivityAttributes.ContentState) {
        guard let id else { return }
        Task.detached { await Live.activities.first { $0.id == id }?.update(ActivityContent(state: state, staleDate: nil)) }
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
