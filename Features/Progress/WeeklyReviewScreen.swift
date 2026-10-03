import SwiftUI
import SwiftData

/// FIT-8, prototype board C: the week's numbers, goals, alerts and the 4-week check-in. The paragraph is written on
/// the phone from the numbers below it; alerts and goal changes are offers, applied with Undo.
struct WeeklyReviewScreen: View {
    let report: WeekReport
    let profile: Profile?
    @Environment(\.dismiss) private var dismiss
    @State private var paragraph: String?
    @State private var writing = LanguageModel.isAvailable
    /// What was picked on an alert or check-in, by its title.
    @State private var picked: [String: String] = [:]
    @State private var toast: Toast?

    var body: some View {
        NavigationStack {
            ScrollView { content }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .overlay(alignment: .bottom) { ToastView(toast: $toast).padding(.bottom, 8) }
            .animation(.snappy, value: toast)
            .animation(.snappy, value: picked)
            .animation(.easeOut, value: writing)
        }
        .task { paragraph = await WeekSummary.write(report.facts); writing = false }
    }

    // MARK: Sections

    var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            top
            numbers.padding(.top, 18)
            if !report.goals.isEmpty {
                heading("Goals this week")
                goals
            }
            if !report.alerts.isEmpty {
                heading("Worth a look")
                VStack(spacing: 8) { ForEach(report.alerts, id: \.title, content: alert) }
            }
            let checks = report.goals.filter { $0.checkIn != nil }
            if !checks.isEmpty {
                heading("4-week check-in")
                Text("Your goals, your call. Nothing changes unless you pick.")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.bottom, 8).padding(.top, -6)
                VStack(spacing: 8) { ForEach(checks, content: checkIn) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 100)
    }

    private var top: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(caption).font(.footnote.weight(.semibold)).tracking(0.4).foregroundStyle(.secondary)
            Text("Your week").font(.system(size: 30, weight: .bold)).tracking(-0.4).padding(.top, 2)
            if writing {
                Text("Writing a short summary of this week from the numbers below, on this iPhone, in two or three lines.")
                    .font(.body).redacted(reason: .placeholder).padding(.top, 10)
                    .accessibilityLabel("Writing a summary")
            } else if let paragraph {
                Text(paragraph).font(.body).lineSpacing(3).padding(.top, 10).transition(.opacity)
                Text("Written on this iPhone from the numbers below.").font(.caption).foregroundStyle(.tertiary).padding(.top, 8)
            }
        }
        .padding(.horizontal, 8)
    }

    /// "WEEK 8 OF 16 · SEP 28 – OCT 4".
    private var caption: String {
        let last = Calendar.current.date(byAdding: .day, value: -1, to: report.days.upperBound)!
        let range = "\(report.days.lowerBound.formatted(.dateTime.month(.abbreviated).day())) – \(last.formatted(.dateTime.month(.abbreviated).day()))"
        guard let week = report.programWeek, let weeks = report.programWeeks else { return range.uppercased() }
        return "Week \(week + 1) of \(weeks) · \(range)".uppercased()
    }

    private var numbers: some View {
        let n = report.numbers
        var tiles: [(String, String, String)] = []
        if n.workoutsPlanned > 0 { tiles.append(("Workouts", "\(n.workoutsDone) of \(n.workoutsPlanned)", WeeklyReview.count(n.sets, "set"))) }
        if let protein = n.protein { tiles.append(("Protein", "\(Int(protein.rounded())) g", "a day")) }
        if let kcal = n.kcal { tiles.append(("Calories", Int(kcal.rounded()).formatted(), "a day")) }
        if let sleep = n.sleep {
            let minutes = Int((sleep * 60).rounded())
            tiles.append(("Sleep", minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60)", "a night"))
        }
        if let weight = n.weight {
            if let change = n.weightChange {
                tiles.append(("Weight", (change > 0 ? "+" : change < 0 ? "−" : "") + Coach.number(abs(change)), "lb · \(Coach.number(weight))"))
            } else {
                tiles.append(("Weight", Coach.number(weight), "lb"))
            }
        }
        if n.push > 0 && n.pull > 0 {
            tiles.append(("Push : pull", "1 : \(Coach.number((Double(n.pull) / Double(n.push) * 10).rounded() / 10))", "sets"))
        }
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(tiles, id: \.0) { title, value, sub in
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                    Text(value).font(.system(.title3, design: .rounded, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
                        .padding(.top, 1)
                    Text(sub).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 16))
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// One card per goal, swiped sideways with the next peeking in.
    private var goals: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(report.goals) { row in
                    let delta = row.week.to - row.week.from
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(row.option.name).font(.subheadline).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            PaceChip(pace: row.week.pace)
                        }
                        Text(delta == 0 ? "No change" : (delta > 0 ? "+" : "−") + report.format(abs(delta), row.option) + " " + row.goal.unit)
                            .font(.system(size: 26, weight: .bold, design: .rounded)).padding(.top, 6)
                        Text((delta == 0 ? "" : "\(report.format(row.week.from, row.option)) → ")
                             + "\(report.format(row.week.to, row.option)) \(row.goal.unit) · goal \(report.format(row.goal.target, row.option))")
                            .font(.footnote).foregroundStyle(.secondary).padding(.top, 2)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 20))
                    .containerRelativeFrame(.horizontal) { width, _ in width * 0.8 }
                    .accessibilityElement(children: .combine)
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .padding(.horizontal, -16)
    }

    private func alert(_ alert: WeeklyReview.Alert) -> some View {
        offer(title: alert.title, detail: alert.detail, choices: alert.area != nil) {
            if let area = alert.area {
                choice(alert.title, "Go easy on the \(area)", primary: true) {
                    guard let profile else { return nil }
                    profile.injuredAreas.append(area)
                    profile.updatedAt = .now
                    return ("Added: go easy on the \(area).", Toast(text: "Plans go easy on the \(area)") {
                        profile.injuredAreas.removeAll { $0 == area }
                        profile.updatedAt = .now
                    })
                }
                choice(alert.title, "It’s fine", primary: false) { ("Okay, nothing changes.", nil) }
            }
        }
    }

    private func checkIn(_ row: WeekReport.GoalRow) -> some View {
        let check = row.checkIn!
        let unit = row.goal.unit, target = row.goal.target, name = WeekReport.short(row.option)
        let new = report.format(check.proposed, row.option), old = report.format(target, row.option)
        let end = report.end?.formatted(.dateTime.month(.abbreviated).day()) ?? "the end"
        let title = check.ahead
            ? "\(name): \(report.format(row.week.to, row.option)) of \(old), with \(check.weeksLeft) weeks to go"
            : "\(name): \(report.format(row.forecast ?? row.week.to, row.option)) \(unit) by \(end) at this rate"
        let detail = check.ahead
            ? "You’re ahead. Raise the goal so the last \(check.weeksLeft) weeks still count?"
            : "\(old) needs \(Coach.number(abs(row.perWeek))) \(unit) a week from here. Or aim for \(new) at today’s pace."
        let change = { () -> (String, Toast?)? in
            row.goal.target = check.proposed
            row.goal.updatedAt = .now
            return ("Goal is now \(new) \(unit).", Toast(text: "\(name) goal is now \(new) \(unit)") {
                row.goal.target = target
                row.goal.updatedAt = .now
            })
        }
        return offer(title: title, detail: detail) {
            if check.ahead {
                choice(title, "Raise to \(new)", primary: true, change)
                choice(title, "Keep \(old)", primary: false) { ("Keeping \(old).", nil) }
            } else {
                choice(title, "Keep \(old)", primary: true) { ("Keeping \(old).", nil) }
                choice(title, "Move to \(new)", primary: false, change)
            }
        }
    }

    // MARK: Parts

    private func heading(_ text: String) -> some View {
        Text(text).font(.title3.weight(.bold)).padding(.horizontal, 8).padding(.top, 26).padding(.bottom, 8)
    }

    private func offer(title: String, detail: String, choices hasChoices: Bool = true,
                       @ViewBuilder choices: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail).font(.subheadline).foregroundStyle(.secondary).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            if let result = picked[title] {
                Text(result).font(.subheadline.weight(.semibold)).padding(.top, 9).transition(.opacity)
            } else if hasChoices {
                HStack(spacing: 8) { choices() }.padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 20))
    }

    /// A pick: it says what happened in place, and a change comes with Undo.
    private func choice(_ key: String, _ label: String, primary: Bool, _ action: @escaping () -> (String, Toast?)?) -> some View {
        Button {
            guard let (result, undoable) = action() else { return }
            picked[key] = result
            if let undoable, let undo = undoable.undo {
                toast = Toast(text: undoable.text) {
                    undo()
                    picked[key] = nil
                }
            }
        } label: {
            Text(label).font(.subheadline.weight(.semibold)).padding(.horizontal, 16).frame(minHeight: 40)
                .foregroundStyle(primary ? Color(.systemBackground) : .primary)
                .background(primary ? Color.primary : Color(.tertiarySystemFill), in: .capsule)
        }
        .buttonStyle(.plain)
    }
}

/// The review's way in, on Today on the last day of the week.
struct WeekReviewCard: View {
    let report: WeekReport
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Your week · \(report.days.lowerBound.formatted(.dateTime.month(.abbreviated).day())) – \(Calendar.current.date(byAdding: .day, value: -1, to: report.days.upperBound)!.formatted(.dateTime.month(.abbreviated).day()))".uppercased())
                    .font(.footnote.weight(.semibold)).tracking(0.4).opacity(0.6)
                Text(report.headline).font(.title3.weight(.bold)).padding(.top, 6)
                Text(report.subline).font(.subheadline).opacity(0.75).padding(.top, 3)
                HStack(spacing: 4) {
                    Text("See the week")
                    Image(systemName: "chevron.right").font(.footnote.weight(.bold))
                }
                .font(.subheadline.weight(.semibold)).padding(.top, 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(Color(.systemBackground))
            .padding(18)
            .background(Color.primary, in: .rect(cornerRadius: 22))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
