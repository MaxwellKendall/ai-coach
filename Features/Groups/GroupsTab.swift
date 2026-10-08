import SwiftUI

/// FIT-64: the Groups tab says which group, when there's one, and shows when someone in your groups is training live.
@MainActor @Observable
final class GroupsTab {
    private(set) var title = "Groups"
    private(set) var live = false

    /// The tab's title: the group's name when you're in exactly one.
    nonisolated static func title(for names: [String]) -> String {
        names.count == 1 ? names[0] : "Groups"
    }

    func refresh(me: String?) async {
        guard let me, let groups = try? await Cloud.myGroups() else {
            if me == nil { title = "Groups"; live = false }
            return
        }
        title = Self.title(for: groups.map(\.name))
        var anyone = false
        for summary in groups.prefix(5) {
            if let group = try? await Cloud.group(summary.groupId), group.live.contains(where: { $0.uid != me && $0.isLive() }) {
                anyone = true
                break
            }
        }
        live = anyone
    }
}
