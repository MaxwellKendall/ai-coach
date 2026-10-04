import SwiftUI
import SwiftData

/// FIT-16, after Apple Fitness › Sharing: the shared goal and how far everyone is together, then each member's
/// progress, then the group's wins to cheer. Invite and the rest are in the toolbar.
struct GroupScreen: View {
    @Environment(Account.self) private var account
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let summary: Cloud.GroupSummary

    @State private var group: Cloud.Group?
    @State private var failure: String?
    @State private var numbers = false
    @State private var confirmingLeave = false
    @State private var removing: Cloud.Member?

    private var me: String { account.user?.uid ?? "" }

    var body: some View {
        List {
            if let group {
                liveNow(group)
                header(group)
                members(group)
                activity(group)
            } else if let failure {
                Text(failure).foregroundStyle(.secondary)
            }
        }
        .overlay { if group == nil && failure == nil { ProgressView() } }
        .navigationTitle(group?.name ?? summary.name)
        .toolbar { if let group { toolbar(group) } }
        .refreshable { await load(publish: true) }
        .task {
            numbers = GroupSync.sharesNumbers(summary.groupId)
            await load(publish: true)
        }
        .task { await listenLive() }
        .task { await listen("onProgress") }
        .task { await listen("onFeed") }
        .confirmationDialog("Leave \(summary.name)?", isPresented: $confirmingLeave, titleVisibility: .visible) {
            Button("Leave Group", role: .destructive) { leave() }
        } message: {
            Text("Your progress is no longer shared with this group.")
        }
        .confirmationDialog("Remove \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { member in
            Button("Remove", role: .destructive) { remove(member) }
        } message: { _ in
            Text("They can rejoin only with a new invite code.")
        }
    }

    // MARK: Sections

    /// FIT-53: whoever is training right now, set by set, with the rest clock running.
    @ViewBuilder private func liveNow(_ group: Cloud.Group) -> some View {
        let live = group.live.filter { $0.uid != me && $0.isLive() }
        if !live.isEmpty {
            Section("Live Now") {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(live, id: \.uid) { set in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Circle().fill(.red).frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(group.members.first { $0.uid == set.uid }?.name ?? "Someone") · \(set.setLine)")
                                        .font(.body.weight(.medium))
                                    Text(set.what(now: context.date)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder private func header(_ group: Cloud.Group) -> some View {
        if let goal = group.goals.first {
            let pcts = group.progress.filter { $0.goalId == goal.goalId }.compactMap(\.pct)
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(goal.title).font(.title2.bold())
                    if let deadline = goal.deadlineDate {
                        let left = GroupProgress.daysLeft(until: deadline)
                        Text("By \(deadline.formatted(.dateTime.month(.abbreviated).day())) · \(left) \(left == 1 ? "day" : "days") left")
                            .foregroundStyle(.secondary)
                    }
                    if let together = GroupProgress.together(pcts) {
                        Gauge(value: together, in: 0...100) {
                            Text("Together")
                        } currentValueLabel: {
                            Text("\(Int(together))%")
                        }
                        .gaugeStyle(.linearCapacity)
                        .padding(.top, 10)
                    }
                }
                .padding(.vertical, 6)
            } footer: {
                let fresh = group.progress.filter { $0.goalId == goal.goalId && isThisWeek($0.updatedAt) }.count
                if group.members.count > 1 {
                    Text("\(fresh) of \(group.members.count) moved forward this week")
                }
            }
        }
    }

    private func members(_ group: Cloud.Group) -> some View {
        let goal = group.goals.first
        let sorted = group.members.sorted { ($0.uid == me ? 0 : 1, $0.name) < ($1.uid == me ? 0 : 1, $1.name) }
        return Section("Members") {
            ForEach(sorted) { member in
                MemberRow(member: member, isMe: member.uid == me, goal: goal,
                          progress: group.progress.first { $0.uid == member.uid && $0.goalId == goal?.goalId })
                    .swipeActions {
                        if group.createdBy == me && member.uid != me {
                            Button("Remove", role: .destructive) { removing = member }
                        }
                    }
            }
        }
    }

    @ViewBuilder private func activity(_ group: Cloud.Group) -> some View {
        let cheers = group.feed.filter { $0.kind == "cheer" }
        let items = group.feed.filter { $0.kind != "cheer" }
        if !items.isEmpty {
            Section("Activity") {
                ForEach(items) { item in
                    let mine = cheers.filter { $0.fields["to"] as? String == item.id }
                    FeedRow(item: item, who: group.members.first { $0.uid == item.uid }?.name ?? "Someone",
                            isMine: item.uid == me, cheers: mine.count, cheered: mine.contains { $0.uid == me }) {
                        cheer(item, in: group)
                    }
                }
            }
        }
    }

    @ToolbarContentBuilder private func toolbar(_ group: Cloud.Group) -> some ToolbarContent {
        ToolbarItem {
            ShareLink(item: Self.invite(group), subject: Text("Join \(group.name)")) {
                Label("Invite", systemImage: "person.badge.plus")
            }
        }
        ToolbarItem {
            Menu {
                Toggle("Share Workouts Live", systemImage: "dot.radiowaves.left.and.right",
                       isOn: Binding(get: { group.members.first { $0.uid == me }?.shareLive ?? false }, set: { setShareLive($0) }))
                Toggle("Share My Numbers", systemImage: "number", isOn: Binding(get: { numbers }, set: { setNumbers($0) }))
                Text("Invite code \(group.inviteCode)")
                if group.createdBy == me {
                    Button("New Invite Code", systemImage: "arrow.clockwise") { rotate(group) }
                }
                Divider()
                Button("Leave Group", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { confirmingLeave = true }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }

    static func invite(_ group: Cloud.Group) -> String {
        "Join my group “\(group.name)” in AI Coach. Open the app, go to You › Groups › Join with Code, and enter \(group.inviteCode)."
    }

    // MARK: Actions

    private func load(publish: Bool) async {
        do {
            guard var loaded = try await Cloud.group(summary.groupId) else {
                failure = "This group no longer exists."
                return
            }
            group = loaded
            failure = nil
            if publish, await GroupSync.publish(loaded, me: me, logs: GroupSync.Logs(context)),
               let fresh = try await Cloud.group(summary.groupId) {
                loaded = fresh
                group = loaded
            }
        } catch {
            if group == nil { failure = "Couldn't load the group. Pull to try again." }
        }
    }

    /// Any member's progress or a new feed item: reload. Groups are small, so a reload is one query.
    private func listen(_ field: String) async {
        do {
            for try await event in Cloud.changes(field, in: summary.groupId) {
                if case .data = event { await load(publish: false) }
            }
        } catch {}
    }

    /// Live sets go straight into the page: a set should show within about a second (FIT-53).
    private func listenLive() async {
        do {
            for try await event in Cloud.liveSets(in: summary.groupId) {
                guard case .data(.success(let set)) = event, var current = group else { continue }
                current.live.removeAll { $0.uid == set.uid }
                current.live.append(set)
                group = current
            }
        } catch {}
    }

    /// FIT-53 opt-in, per group, off by default. Turning it on is a moment to ask for notifications (FIT-59).
    private func setShareLive(_ on: Bool) {
        Task {
            try? await Cloud.setShareLive(on, in: summary.groupId)
            if on { await Push.request() }
            await load(publish: false)
        }
    }

    private func setNumbers(_ on: Bool) {
        numbers = on
        GroupSync.setSharesNumbers(on, summary.groupId)
        Task { await load(publish: true) }
    }

    private func cheer(_ item: Cloud.FeedItem, in group: Cloud.Group) {
        Task {
            try? await Cloud.post("cheer", ["to": item.id], in: group.id)
            await load(publish: false)
        }
    }

    private func rotate(_ group: Cloud.Group) {
        Task {
            _ = try? await Cloud.rotateInvite(group.id)
            await load(publish: false)
        }
    }

    private func remove(_ member: Cloud.Member) {
        Task {
            try? await Cloud.remove(member.uid, from: summary.groupId)
            await load(publish: false)
        }
    }

    private func leave() {
        Task {
            do {
                try await Cloud.leave(summary.groupId)
                dismiss()
            } catch {
                failure = "Couldn't leave the group. Try again."
            }
        }
    }

    private func isThisWeek(_ string: String) -> Bool {
        Cloud.date(string).map { $0 > .now.addingTimeInterval(-7 * 86_400) } ?? false
    }
}

/// One member: name, a bar to their own target, and the change or percent they chose to share.
private struct MemberRow: View {
    let member: Cloud.Member
    let isMe: Bool
    let goal: Cloud.GroupGoal?
    let progress: Cloud.Progress?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(isMe ? "\(member.name) (You)" : member.name).font(.body.weight(.medium))
                Spacer()
                Text(trailing).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let pct = progress?.pct {
                ProgressView(value: pct, total: 100)
                    .tint(.primary)
                    .accessibilityLabel("\(Int(pct)) percent")
            }
            if let pace = progress?.onPace {
                Text(pace ? "On pace" : "Behind").font(.caption).foregroundStyle(pace ? Color.secondary : Color.orange)
            } else if progress == nil {
                Text(goal?.metric == "weight_lb" ? "No weigh-in yet" : "Nothing logged yet").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var trailing: String {
        guard let progress else { return "" }
        if let value = progress.value, let baseline = progress.baseline, let goal {
            return GroupProgress.change(value, from: baseline, unit: goal.unit)
        }
        return progress.pct.map { "\(Int($0))%" } ?? ""
    }
}

/// A win or a finished workout, with a cheer like Apple Fitness's activity sharing.
private struct FeedRow: View {
    let item: Cloud.FeedItem
    let who: String
    let isMine: Bool
    let cheers: Int
    let cheered: Bool
    let cheer: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(text)
                if let date = Cloud.date(item.createdAt) {
                    Text(date, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(action: cheer) {
                Label(cheers > 0 ? "\(cheers)" : "Cheer", systemImage: cheered ? "hands.clap.fill" : "hands.clap")
                    .labelStyle(.titleAndIcon)
                    .font(.subheadline)
            }
            .buttonStyle(.borderless)
            .disabled(isMine || cheered)
            .accessibilityLabel(cheered ? "Cheered" : "Cheer \(who)")
        }
    }

    private var text: String {
        let fields = item.fields
        switch item.kind {
        case "milestone":
            let pct = fields["pct"] as? Int ?? 0
            return pct >= 100 ? "\(who) reached the goal" : "\(who) is \(pct)% of the way"
        case "session":
            return "\(who) finished \(fields["workout"] as? String ?? "a workout")"
        default:
            return "\(who) shared a win"
        }
    }
}
