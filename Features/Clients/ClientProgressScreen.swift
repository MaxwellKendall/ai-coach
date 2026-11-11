import Charts
import SwiftData
import SwiftUI

/// FIT-337: a client at a glance, one tap from their screen: goals, their main lifts' estimated max over time, weeks
/// done of planned, check-ins, and their profile. Read-only: goals and profile are the client's own (principle 6; the
/// server lets a coach write only the plan and the logs), so a change is suggested in a message.
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
    /// FIT-344: why the check-in day didn't reach their phone.
    @State private var dayProblem: String?

    private var client: Roster.Client? { roster.clients.first { $0.id == id } }
    private var names: [String: String] { Dictionary(templates.map { ($0.slug, $0.name) }, uniquingKeysWith: { a, _ in a }) }

    var body: some View {
        ScrollView {
            if let client {
                let patterns = Dictionary(templates.map { ($0.slug, $0.values("movement_pattern").first ?? "") }, uniquingKeysWith: { a, _ in a })
                let sets = ClientProgress.sets(client.units, patterns: patterns)
                let weighIns = ClientProgress.checkIns(client.units, "weight_lb")
                VStack(alignment: .leading, spacing: 28) {
                    goals(client, sets: sets, weighIns: weighIns)
                    ProgressCharts(units: client.units, sets: sets, names: names) {
                        // FIT-344: the day they're asked for the weekly check-in, and reminded; Sunday until it's set.
                        Picker("Weekly check-in", selection: Binding(get: { ClientProgress.checkInDay(client.units) }, set: { setCheckInDay($0, client) })) {
                            ForEach(Week.ordered(Array(0...6)), id: \.self) { Text(Calendar.current.weekdaySymbols[Week.offset($0)]).tag($0) }
                        }
                        .font(.subheadline)
                        if let dayProblem { Text(dayProblem).font(.footnote).foregroundStyle(.red) }
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
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.inkMuted).padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 14) { content() }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading).cardBackground()
        }
    }

    @ViewBuilder private func goals(_ client: Roster.Client, sets: [LoggedSet], weighIns: [DatedValue]) -> some View {
        let goals = ClientProgress.goals(client.units)
        section("Goals") {
            if goals.isEmpty {
                Text("No goals yet. They set their own; suggest one in a message.").font(.subheadline).foregroundStyle(Color.inkMuted)
            }
            ForEach(Array(goals.enumerated()), id: \.offset) { _, goal in
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
        let body = SyncUnits.encode(WeeklyCheckIn.Day(day: day))
        var changed = client
        changed.units["checkin"] = body
        roster.update(changed, coach: account.user?.uid ?? "", names: names)
        dayProblem = nil
        Task {
            do {
                if !(try await Cloud.push("checkin", body: body, client: client.id)) { dayProblem = "Their phone had a newer copy. Pull to see it." }
            } catch {
                dayProblem = "Couldn’t send that. Try again."
            }
        }
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
