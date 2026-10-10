import SwiftUI
import SwiftData

/// FIT-40 (prototype board C): a new version of the week's sessions. Done, past and pinned ones stay; the rest show
/// what changes and why. Try another for a different one; Use this writes it. FIT-77: with Apple Intelligence the
/// model designs the new version (ProgramDesigner, about 20 s); otherwise, or when it can't, each session's first lift
/// is swapped as before (WeekRegenerator).
struct RegenerateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Pro.self) private var pro
    @Query private var profiles: [Profile]
    /// FIT-83: Pro's paywall, from here: a sheet can't be shown over this one from the root.
    @State private var paywall = false
    let week: Int
    let days: [Day]
    let catalog: [Exercise]
    let settings: TrainingSettings
    let history: [LoggedSet]
    let names: [String: String]
    /// The week as the designer reads it; nil without Apple Intelligence.
    var request: ProgramDesigner.Request?
    /// FIT-102: the model that designs the new version.
    var model: any AIModel = OnDeviceModel()
    let apply: ([(items: [PlannedActivity], workouts: [PlannedWorkout])]) -> Void
    @State private var variant = 0
    /// The model's version, by day, and each session's aim.
    @State private var designed: [Date: [PlannedWorkout]]?
    @State private var aims: [String: String] = [:]
    @State private var designing = false

    struct Day {
        var date: Date
        var session: String
        var items: [PlannedActivity]
        var workouts: [PlannedWorkout]
        /// Why it stays, or nil when it changes.
        var kept: String?
    }

    var body: some View {
        let alternatives = days.map { day in
            day.kept == nil && designed == nil
                ? WeekRegenerator.alternative(day.workouts, variant: variant, catalog: catalog, settings: settings, history: history) : nil
        }
        let sessions = days.map { day in day.kept == nil ? designed?[Calendar.current.startOfDay(for: day.date)] : nil }
        let changing = designing ? 0 : (designed == nil ? alternatives.compactMap { $0 }.count : sessions.compactMap { $0 }.count)
        VStack(alignment: .leading, spacing: 0) {
            Text("New plan for week \(week)").font(.title2.weight(.bold))
            Text(changing > 0 || designing ? "Done and pinned sessions stay as they are."
                 : "Everything left this week is kept. Unpin a session to let it change.")
                .font(.subheadline).foregroundStyle(.secondary).padding(.top, 4)
            ScrollView {
                VStack(spacing: 0) {
                    if designing {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Your coach is designing a new version…").font(.subheadline).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                    }
                    ForEach(days.indices, id: \.self) { index in
                        if let session = sessions[index] {
                            designedRow(days[index], session)
                        } else {
                            row(days[index], designing ? nil : alternatives[index])
                        }
                    }
                }
            }
            .scrollEdgeEffectHidden(true, for: .bottom)
            .padding(.top, 10)
            Button {
                let changes = designed == nil
                    ? days.indices.compactMap { index in alternatives[index].map { (items: days[index].items, workouts: marked($0)) } }
                    : days.indices.compactMap { index in
                        sessions[index].map { rows in
                            (items: days[index].items, workouts: rows.map { var row = $0; row.adjustedReason = "regenerated"; return row })
                        }
                    }
                apply(changes)
                dismiss()
            } label: {
                Text(changing > 0 || designing ? "Use this" : "OK").font(.headline).frame(maxWidth: .infinity, minHeight: 56)
                    .foregroundStyle(Color(.systemBackground)).background(Color.primary, in: .capsule)
                    .opacity(designing ? 0.3 : 1)
            }
            .buttonStyle(.plain)
            .disabled(designing)
            if changing > 0 {
                Button("Try another") {
                    guard redesign() else { return }
                    if designed != nil { Task { await design(differentFrom: designed!.values.flatMap { $0 }) } }
                    else { withAnimation(.snappy) { variant += 1 } }
                }
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 44).padding(.top, 6)
            }
        }
        .padding(EdgeInsets(top: 28, leading: 22, bottom: 12, trailing: 22))
        .task {
            // Opening it was the first redesign; ProgramScreen checked there was one left.
            _ = redesign()
            await design(differentFrom: days.flatMap(\.workouts))
        }
        .sheet(isPresented: $paywall) { PaywallView() }
        .presentationDetents([.fraction(0.66), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(.systemBackground))
    }

    /// FIT-83: a new version uses one of the free plan's redesigns this month; with none left, Pro's paywall instead.
    private func redesign() -> Bool {
        guard !pro.active, let profile = profiles.first else { return true }
        guard FreeLimits.redesignsLeft(profile.redesigns) > 0 else {
            paywall = true
            return false
        }
        profile.redesigns.append(.now)
        return true
    }

    /// FIT-77: the model's version of the open days; nil stays nil when it can't (the swap is the fallback).
    private func design(differentFrom current: [PlannedWorkout]) async {
        guard var request, days.contains(where: { $0.kept == nil }) else { return }
        request.differentFrom = current.filter { $0.note != TrainingGenerator.warmupNote }
        designing = true
        defer { designing = false }
        let result = await ProgramDesigner.week(request, model: model)
        guard result.source == .model else { return }
        let calendar = Calendar.current
        withAnimation(.snappy) {
            designed = Dictionary(grouping: result.week.workouts) { calendar.startOfDay(for: $0.date) }
            aims = Dictionary(result.why.compactMap { line -> (String, String)? in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                return (String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            }, uniquingKeysWith: { first, _ in first })
        }
    }

    private func designedRow(_ day: Day, _ rows: [PlannedWorkout]) -> some View {
        let working = rows.filter { $0.note != TrainingGenerator.warmupNote }
        let name = working.first?.session ?? day.session
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(day.date.formatted(.dateTime.weekday(.abbreviated))) · \(name)").font(.body.weight(.semibold))
                Spacer()
                Text("Changes").font(.footnote).foregroundStyle(.secondary)
            }
            Text(working.map(line).joined(separator: ", ")).font(.subheadline).contentTransition(.opacity)
            if let aim = aims[name], !aim.isEmpty { Text(aim).font(.footnote).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func row(_ day: Day, _ alternative: WeekRegenerator.Alternative?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(day.date.formatted(.dateTime.weekday(.abbreviated))) · \(day.session)").font(.body.weight(.semibold))
                Spacer()
                Text(day.kept ?? (designing ? "…" : alternative == nil ? "No change" : "Changes")).font(.footnote).foregroundStyle(.secondary)
            }
            if let alternative {
                Text("\(line(alternative.from)) → \(line(alternative.to))")
                    .font(.subheadline)
                    .contentTransition(.opacity)
                Text(alternative.why).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func line(_ workout: PlannedWorkout) -> String {
        "\(names[workout.exercise] ?? workout.exercise) \(Planner.SketchDay.dose(workout))"
    }

    /// The changed lift says why on Today, like any other adjustment.
    private func marked(_ alternative: WeekRegenerator.Alternative) -> [PlannedWorkout] {
        alternative.workouts.map { $0 == alternative.to ? { var changed = $0; changed.adjustedReason = alternative.why; return changed }($0) : $0 }
    }
}
