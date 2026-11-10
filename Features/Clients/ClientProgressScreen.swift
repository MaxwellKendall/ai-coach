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
    @Query private var templates: [Template]

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
                    lifts(sets)
                    weeks(client)
                    checkIns(client, weighIns: weighIns)
                    profile(client)
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

    @ViewBuilder private func lifts(_ sets: [LoggedSet]) -> some View {
        let lifts = ClientProgress.mainLifts(sets)
        section("Estimated max") {
            if lifts.isEmpty {
                Text("Nothing lifted with a weight yet.").font(.subheadline).foregroundStyle(Color.inkMuted)
            }
            ForEach(lifts, id: \.self) { slug in
                let trend = Training.estimated1RMTrend(sets, exercise: slug)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(names[slug] ?? slug).font(.headline)
                        Spacer()
                        if let last = trend.last {
                            Text("\(Coach.number(last.value.rounded())) lb").font(.headline).monospacedDigit()
                        }
                    }
                    if trend.count > 1 {
                        Chart(trend, id: \.date) { point in
                            LineMark(x: .value("Day", point.date), y: .value("lb", point.value))
                                .foregroundStyle(Plate.current.mark).interpolationMethod(.monotone)
                        }
                        .chartYScale(domain: .automatic(includesZero: false))
                        .chartXAxis(.hidden)
                        .frame(height: 64)
                    }
                }
            }
        }
    }

    private func weeks(_ client: Roster.Client) -> some View {
        let weeks = ClientProgress.weeks(client.units, today: .now)
        return section("Sessions, last 8 weeks") {
            Chart(weeks, id: \.sunday) { week in
                // Done, then what's left of the planned on top, so the bar is as tall as the week's plan.
                BarMark(x: .value("Week", week.sunday, unit: .weekOfYear), y: .value("Sessions", week.done))
                    .foregroundStyle(Plate.current.mark)
                BarMark(x: .value("Week", week.sunday, unit: .weekOfYear), y: .value("Sessions", max(0, week.planned - week.done)))
                    .foregroundStyle(Color.fill)
            }
            .chartXAxis { AxisMarks(values: .stride(by: .weekOfYear, count: 2)) { AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
            .frame(height: 120)
            let done = weeks.map(\.done).reduce(0, +), planned = weeks.map(\.planned).reduce(0, +)
            Text(planned == 0 ? "Nothing planned yet" : "\(done) of \(planned) sessions done")
                .font(.subheadline).foregroundStyle(Color.inkMuted)
        }
    }

    @ViewBuilder private func checkIns(_ client: Roster.Client, weighIns: [DatedValue]) -> some View {
        let sleep = ClientProgress.checkIns(client.units, "sleep_h").filter { $0.date > Date.now.addingTimeInterval(-7 * 86_400) }
        let notes = ClientProgress.notes(client.units).prefix(3)
        section("Check-ins") {
            if weighIns.isEmpty && sleep.isEmpty && notes.isEmpty {
                Text("No check-ins yet.").font(.subheadline).foregroundStyle(Color.inkMuted)
            }
            if let last = weighIns.last {
                HStack { Text("Weight"); Spacer(); Text("\(Coach.number(last.value)) lb").monospacedDigit().bold() }
                if weighIns.count > 1 {
                    Chart(weighIns, id: \.date) { LineMark(x: .value("Day", $0.date), y: .value("lb", $0.value)).foregroundStyle(Plate.current.mark) }
                        .chartYScale(domain: .automatic(includesZero: false)).chartXAxis(.hidden).frame(height: 56)
                }
            }
            if !sleep.isEmpty {
                let average = sleep.map(\.value).reduce(0, +) / Double(sleep.count)
                HStack { Text("Sleep, last 7 days"); Spacer(); Text("\(Coach.number((average * 10).rounded() / 10)) h a night").monospacedDigit().bold() }
            }
            ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                VStack(alignment: .leading, spacing: 2) {
                    Text("“\(note.text)”")
                    Text(note.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())).font(.footnote).foregroundStyle(Color.inkMuted)
                }
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
