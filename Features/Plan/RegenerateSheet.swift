import SwiftUI

/// FIT-40 (prototype board C): a new version of the week's sessions. Done, past and pinned ones stay; the rest show
/// what changes and why. Try another for a different one; Use this writes it.
struct RegenerateSheet: View {
    @Environment(\.dismiss) private var dismiss
    let week: Int
    let days: [Day]
    let catalog: [Exercise]
    let settings: TrainingSettings
    let history: [LoggedSet]
    let names: [String: String]
    let apply: ([(items: [PlannedActivity], workouts: [PlannedWorkout])]) -> Void
    @State private var variant = 0

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
            day.kept == nil ? WeekRegenerator.alternative(day.workouts, variant: variant, catalog: catalog, settings: settings, history: history) : nil
        }
        let changing = alternatives.compactMap { $0 }.count
        VStack(alignment: .leading, spacing: 0) {
            Text("New plan for week \(week)").font(.title2.weight(.bold))
            Text(changing > 0 ? "Done and pinned sessions stay as they are."
                 : "Everything left this week is kept. Unpin a session to let it change.")
                .font(.subheadline).foregroundStyle(.secondary).padding(.top, 4)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(days.indices, id: \.self) { index in
                        row(days[index], alternatives[index])
                    }
                }
            }
            .scrollEdgeEffectHidden(true, for: .bottom)
            .padding(.top, 10)
            HStack(spacing: 12) {
                if changing > 0 {
                    Button("Try another") { withAnimation(.snappy) { variant += 1 } }
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Color(.secondarySystemBackground), in: .capsule)
                }
                Button(changing > 0 ? "Use this" : "OK") {
                    let changes = days.indices.compactMap { index in
                        alternatives[index].map { (items: days[index].items, workouts: marked($0)) }
                    }
                    apply(changes)
                    dismiss()
                }
                .frame(maxWidth: .infinity, minHeight: 50)
                .foregroundStyle(Color(.systemBackground))
                .background(Color.primary, in: .capsule)
            }
            .font(.headline)
            .buttonStyle(.plain)
        }
        .padding(EdgeInsets(top: 28, leading: 22, bottom: 12, trailing: 22))
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func row(_ day: Day, _ alternative: WeekRegenerator.Alternative?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(day.date.formatted(.dateTime.weekday(.abbreviated))) · \(day.session)").font(.body.weight(.semibold))
                Spacer()
                Text(day.kept ?? (alternative == nil ? "No change" : "Changes")).font(.footnote).foregroundStyle(.secondary)
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
