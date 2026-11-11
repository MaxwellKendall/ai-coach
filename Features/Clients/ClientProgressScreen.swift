import Charts
import SwiftData
import SwiftUI

/// FIT-337: a client at a glance, one tap from their screen: goals, their main lifts' estimated max over time, weeks
/// done of planned, check-ins, and their profile. FIT-376: the coach adds, changes and drops their goals and edits their
/// profile with the client's own editors (ClientScratch); it goes to their phone with the coach's name on it.
struct ClientProgressScreen: View {
    struct Ref: Hashable { var client: String }

    let id: String
    @Environment(Roster.self) private var roster
    @Environment(Account.self) private var account
    @Environment(\.dismiss) private var dismiss
    @Query private var templates: [Template]
    /// FIT-339: removing them, asked first.
    @State private var removing = false
    @State private var problem: String?
    /// FIT-376: a goal or the profile being changed, on a store of their units made for it.
    @State private var editing: Editing?
    @State private var toast: Toast?

    struct Editing: Identifiable {
        enum Kind { case newGoal, goal(String), profile }
        let id = UUID()
        var kind: Kind
        var scratch: ClientScratch
    }
    @Environment(\.dynamicTypeSize) private var typeSize

    private var client: Roster.Client? { roster.clients.first { $0.id == id } }
    private var names: [String: String] { Dictionary(templates.map { ($0.slug, $0.name) }, uniquingKeysWith: { a, _ in a }) }

    var body: some View {
        ScrollView {
            if let client {
                let patterns = Dictionary(templates.map { ($0.slug, $0.values("movement_pattern").first ?? "") }, uniquingKeysWith: { a, _ in a })
                let sets = ClientProgress.sets(client.units, patterns: patterns)
                let weighIns = ClientProgress.checkIns(client.units, "weight_lb")
                VStack(alignment: .leading, spacing: 28) {
                    UnsentCard(id: id, first: first, names: names) { said($0, done: "Sent") }
                    goals(client, sets: sets, weighIns: weighIns)
                    ProgressCharts(units: client.units, sets: sets, names: names) {
                        // FIT-344: the day they're asked for the weekly check-in, and reminded; Sunday until it's set.
                        // FIT-367: said what it is: a menu alone read as a stray "Sunday".
                        // Accessibility sizes stack the label over the day, so neither hyphenates.
                        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout())
                        layout {
                            Text("Check-in day").font(.subheadline)
                            if !typeSize.isAccessibilitySize { Spacer() }
                            Picker("Check-in day", selection: Binding(get: { ClientProgress.checkInDay(client.units) }, set: { setCheckInDay($0, client) })) {
                                ForEach(Week.ordered(Array(0...6)), id: \.self) { Text(Calendar.current.weekdaySymbols[Week.offset($0)]).tag($0) }
                            }
                            .labelsHidden()
                            .font(.subheadline)
                        }
                    }
                    profile(client)
                    remove(client)
                }
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 32)
            }
        }
        .screenBackground()
        .navigationTitle(client.map { "\($0.name.split(separator: " ").first.map(String.init) ?? $0.name)’s progress" } ?? "Progress")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.visible, for: .navigationBar)
        .overlay(alignment: .bottom) { ToastView(toast: $toast).padding(.bottom, 24) }
        .animation(.settle, value: toast)
        .sheet(item: $editing, onDismiss: sendEdits) { editing in
            Group {
                switch editing.kind {
                case .newGoal:
                    NewGoalSheet()
                case .goal(let key):
                    if let goal = editing.scratch.goal(key), let option = GoalOption.all.first(where: { $0.metric == goal.metric }) {
                        GoalChangeSheet(goal: goal, option: option, seenBy: "\(first) sees the change, with your name on it.") {
                            goal.status = .abandoned
                            goal.updatedAt = .now
                        }
                    }
                case .profile:
                    if let profile = editing.scratch.profile {
                        NavigationStack {
                            ProfileEditor(profile: profile, isNew: false)
                                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { self.editing = nil } } }
                        }
                    }
                }
            }
            .environment(\.modelContext, editing.scratch.context)
            .tint(RootView.accent)
        }
    }

    /// The scratch store the last sheet edited, sent once it's closed.
    @State private var pending: ClientScratch?

    private var first: String { client.map { $0.name.split(separator: " ").first.map(String.init) ?? $0.name } ?? "your client" }

    private func open(_ kind: Editing.Kind, _ client: Roster.Client) {
        do {
            let scratch = try ClientScratch(units: client.units, templates: templates)
            pending = scratch
            editing = Editing(kind: kind, scratch: scratch)
        } catch {
            toast = Toast(text: "Couldn’t open that")
        }
    }

    /// What the sheet changed, sent to their phone with the coach's name on it.
    private func sendEdits() {
        guard let scratch = pending else { return }
        pending = nil
        let coach = account.user?.name.map { $0.split(separator: " ").first.map(String.init) ?? $0 } ?? "Your coach"
        guard let units = try? scratch.changes(by: coach), !units.isEmpty else { return }
        Task { said(await roster.send(units, to: id, coach: account.user?.uid ?? "", names: names), done: "Sent to \(first)") }
    }

    private func said(_ sent: Roster.Sent, done: String?) {
        switch sent {
        case .sent: if let done { toast = Toast(text: done) }
        case .theirsWasNewer: toast = Toast(text: "\(first)’s phone had a newer copy, shown here")
        case .failed: toast = Toast(text: "Couldn’t send that to \(first)")
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.inkMuted).padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 14) { content() }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading).cardBackground()
        }
    }

    @ViewBuilder private func goals(_ client: Roster.Client, sets: [LoggedSet], weighIns: [DatedValue]) -> some View {
        let goals = ClientProgress.keyedGoals(client.units)
        section("Goals") {
            if goals.isEmpty {
                Text("No goals yet.").font(.subheadline).foregroundStyle(Color.inkMuted)
            }
            ForEach(goals, id: \.key) { key, goal in
                let now = GoalProgress.current(goal.metric, sets: sets, weighIns: weighIns, since: .distantPast)
                let from = goal.baseline ?? now ?? 0
                let fraction = goal.target == from ? 1 : min(1, max(0, ((now ?? from) - from) / (goal.target - from)))
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(Self.goalName(goal.metric, names: names)).font(.headline)
                        Spacer()
                        Text("\(now.map(Coach.number) ?? "–") → \(Coach.number(goal.target)) \(goal.unit)")
                            .font(.subheadline).foregroundStyle(Color.inkMuted).monospacedDigit()
                    }
                    ProgressView(value: fraction).tint(Plate.current.mark)
                    if let deadline = goal.deadline {
                        Text("By \(deadline.formatted(.dateTime.month(.abbreviated).day().year()))").font(.footnote).foregroundStyle(Color.inkMuted)
                    }
                }
                .contentShape(.rect)
                .onTapGesture { open(.goal(key), client) }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Change or drop this goal")
            }
            Button { open(.newGoal, client) } label: {
                Label("Add a Goal", systemImage: "plus").font(.subheadline.weight(.semibold))
            }
        }
    }

    /// "Back Squat max", "Bodyweight", or the metric itself.
    static func goalName(_ metric: String, names: [String: String]) -> String {
        if metric == "weight_lb" { return "Bodyweight" }
        let parts = metric.split(separator: ".").map(String.init)
        guard parts.count == 2, let name = names[parts[0]] else { return metric }
        return parts[1] == "1rm_lb" ? "\(name) max" : parts[1] == "reps" ? "\(name) reps" : name
    }

    /// FIT-344: the check-in day, kept here at once and sent to their phone as the `checkin` unit.
    private func setCheckInDay(_ day: Int, _ client: Roster.Client) {
        let units: [String: String?] = ["checkin": SyncUnits.encode(WeeklyCheckIn.Day(day: day))]
        Task { said(await roster.send(units, to: client.id, coach: account.user?.uid ?? "", names: names), done: nil) }
    }

    @ViewBuilder private func profile(_ client: Roster.Client) -> some View {
        if let profile = client.units["profile"].flatMap({ try? SyncUnits.decode(SyncUnits.ProfileBody.self, $0) }) {
            section("Profile") {
                row("Trains", Week.ordered(profile.trainingDays).map { Self.weekday($0) }.joined(separator: ", "))
                row("Session", "\(profile.sessionMinutes) min")
                row("Age", "\(profile.age)")
                row("Bodyweight", "\(Coach.number(profile.weightLb)) lb")
                row("Equipment", profile.equipment.count >= Profile.allEquipment.count ? "Full gym"
                    : profile.equipment.map { $0.replacingOccurrences(of: "_", with: " ") }.joined(separator: ", "))
                if !profile.injuredAreas.isEmpty { row("Injuries", profile.injuredAreas.joined(separator: ", ")) }
                Button { open(.profile, client) } label: {
                    Label("Edit Profile", systemImage: "pencil").font(.subheadline.weight(.semibold))
                }
            }
        }
    }

    /// FIT-339: ending the link, at the bottom as Contacts puts Delete; asked first, and they're told on their phone.
    private func remove(_ client: Roster.Client) -> some View {
        VStack(spacing: 8) {
            Button { removing = true } label: {
                Text("Remove from Your Clients").foregroundStyle(.red).frame(maxWidth: .infinity).padding(.vertical, 14).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .cardBackground()
            if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
        }
        .confirmationDialog("Remove \(client.name)?", isPresented: $removing, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                Task {
                    do {
                        try await Cloud.removeClient(client.id)
                        roster.remove(client.id)
                        dismiss()
                    } catch {
                        problem = "Couldn’t remove them. Try again."
                    }
                }
            }
        } message: {
            Text("You’ll no longer see or change their training. They keep everything they’ve logged.")
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(Color.inkMuted)
            Spacer(minLength: 16)
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }

    /// 0 = Monday, as training days are kept.
    private static func weekday(_ day: Int) -> String {
        Calendar.current.shortWeekdaySymbols[(day + 1) % 7]
    }
}
