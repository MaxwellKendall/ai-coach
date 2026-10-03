import SwiftUI
import SwiftData

/// "Shoulder hurts", "only 30 min Wednesday", "slept badly", "move Friday": re-plans the rest of the week
/// with one constraint, shows what changes, and applies it only on confirm.
struct AdjustSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var templates: [Template]
    @Query private var profiles: [Profile]
    let plan: Plan

    enum Reason: String, CaseIterable, Identifiable {
        case injury = "Injury or pain", time = "Short on time", energy = "Low energy", move = "Move a session"
        var id: String { rawValue }
    }

    @State private var reason = Reason.injury
    @State private var areas = ""
    @State private var day: Date?
    @State private var minutes = 30
    @State private var moveTo = 0

    private var sessionDays: [Date] {
        Array(Set(Planner.workouts(plan, templates: templates).map(\.date)))
            .filter { $0 >= Calendar.current.startOfDay(for: .now) }.sorted()
    }

    var body: some View {
        let result = preview()
        Form {
            Picker("What's up", selection: $reason) {
                ForEach(Reason.allCases) { Text($0.rawValue).tag($0) }
            }
            switch reason {
            case .injury:
                TextField("Area, e.g. shoulders, lower_back", text: $areas).textInputAutocapitalization(.never)
            case .time, .energy, .move:
                Picker("Session", selection: $day) {
                    Text("Choose").tag(Date?.none)
                    ForEach(sessionDays, id: \.self) { Text($0.formatted(.dateTime.weekday(.wide).hour().minute())).tag(Date?.some($0)) }
                }
                if reason == .time { Stepper("\(minutes) minutes available", value: $minutes, in: 10...90, step: 5) }
                if reason == .move {
                    Picker("To", selection: $moveTo) {
                        ForEach(0..<7, id: \.self) { Text(ProfileEditor.weekdays[$0]).tag($0) }
                    }
                }
            }
            if let result {
                Section("Changes") {
                    let changes = diff(result.before, result.after)
                    if changes.isEmpty { Text("Nothing changes.").foregroundStyle(.secondary) }
                    ForEach(changes, id: \.self) { line in
                        Text(line).font(.subheadline).foregroundStyle(line.hasPrefix("+") ? .green : .red)
                    }
                }
            } else if reason == .move, day != nil {
                Text("That day is within 48 hours of another session for the same muscles.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Adjust this week")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Apply") {
                    if let result {
                        try? Planner.apply(result.past + result.after, to: plan, templates: templates, in: context)
                    }
                    dismiss()
                }
                .disabled(result.map { diff($0.before, $0.after).isEmpty } ?? true)
            }
        }
    }

    private func preview() -> (past: [PlannedWorkout], before: [PlannedWorkout], after: [PlannedWorkout])? {
        guard let profile = profiles.first else { return nil }
        let catalog = Planner.catalog(templates)
        let bySlug = Dictionary(catalog.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
        return Planner.adjust(plan, templates: templates) { week in
            switch reason {
            case .injury:
                let set = BodyArea.muscles(for: Profile.list(areas))
                return set.isEmpty ? nil
                    : TrainingAdjuster.injury(week, areas: set, label: areas.trimmingCharacters(in: .whitespaces).lowercased(),
                                              settings: profile.trainingSettings, catalog: catalog)
            case .time:
                guard let day else { return nil }
                return TrainingAdjuster.time(week, on: day, minutes: minutes, sessionMinutes: profile.sessionMinutes) {
                    bySlug[$0.exercise]?.isGoalLift == true
                }
            case .energy:
                return day.map { TrainingAdjuster.energy(week, on: $0) }
            case .move:
                guard let day else { return nil }
                let calendar = Calendar.current
                let monday = Week.monday(of: day)
                let time = calendar.dateComponents([.hour, .minute], from: day)
                let target = calendar.date(byAdding: DateComponents(day: moveTo, hour: time.hour, minute: time.minute), to: monday)!
                return TrainingAdjuster.reschedule(week, from: day, to: target) { bySlug[$0]?.pattern }
            }
        }
    }

    /// Lines only in `before` (−) and only in `after` (+).
    private func diff(_ before: [PlannedWorkout], _ after: [PlannedWorkout]) -> [String] {
        let names = Dictionary(templates.map { ($0.slug, $0.name) }, uniquingKeysWith: { first, _ in first })
        func line(_ w: PlannedWorkout) -> String {
            let name = names[w.exercise] ?? w.exercise
            return "\(w.date.formatted(.dateTime.weekday(.abbreviated))) \(name)\(w.note.map { " (\($0))" } ?? "") \(Coach.targets(w.targets))"
        }
        let old = before.map(line), new = after.map(line)
        return old.filter { !new.contains($0) }.map { "− " + $0 } + new.filter { !old.contains($0) }.map { "+ " + $0 }
    }
}
