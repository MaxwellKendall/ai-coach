import SwiftUI

/// The whole program at once (FIT-44, prototype boards 4–5), peeked at like the whole workout: the check card's
/// Program rows, each edited in place, then every week. Tap a week to go to it.
struct WholeProgramSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var profile: Profile
    let goals: [Goal]
    let catalog: [Exercise]
    let names: [String: String]
    let current: Int
    let selected: Int
    /// Under each week's title: its dates and its sessions, or where the goals should be.
    let line: (Int) -> String
    let go: (Int) -> Void
    @State private var open: String?

    var body: some View {
        let weeks = profile.program ?? []
        NavigationStack {
            List {
                Section("Program") {
                    targetDate(weeks.count)
                    training
                    starts
                    equipment
                }
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 22, bottom: 0, trailing: 22))
                Section {
                    ForEach(weeks.indices, id: \.self) { index in weekRow(index, weeks: weeks) }
                } header: {
                    Text("Weeks")
                } footer: {
                    Text("Change anything here and the weeks ahead re-plan. Done and pinned sessions stay.")
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 22, bottom: 0, trailing: 22))
            }
            .listStyle(.plain)
            .navigationTitle("Your program")
            .navigationSubtitle(subtitle(weeks.count))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private var answers: OnboardingAnswers { OnboardingAnswers(profile, goals: goals) }

    private func opened(_ id: String) -> Binding<Bool> {
        Binding { open == id } set: { open = $0 ? id : nil }
    }

    private func day(_ date: Date) -> String { date.formatted(.dateTime.month(.abbreviated).day()) }

    private func subtitle(_ count: Int) -> String {
        guard let start = profile.programStart, let end = profile.targetDate else { return "" }
        return "\(count) weeks · \(day(start)) – \(day(end))"
    }

    // MARK: Program

    private func targetDate(_ count: Int) -> some View {
        let end = profile.targetDate ?? .now
        let earliest = max(OnboardingAnswers.weekRange.lowerBound, current + 1)
        return ValueRow(name: "Target date", value: end.formatted(.dateTime.month(.abbreviated).day().year()),
                        note: "\(count) weeks", open: opened("date")) {
            Nudge(label: day(end), lessLabel: "A week sooner", moreLabel: "A week later",
                  less: { setWeeks(max(earliest, count - 1)) },
                  more: { setWeeks(min(OnboardingAnswers.weekRange.upperBound, count + 1)) })
        }
    }

    private func setWeeks(_ count: Int) {
        guard let start = profile.programStart else { return }
        let end = Calendar.current.date(byAdding: .day, value: 6, to: ProgramPlan.monday(count - 1, start: start))!
        ProgramSettings.setTargetDate(end, profile: profile, goals: goals)
    }

    private var training: some View {
        ValueRow(name: "Training", value: answers.training, open: opened("training")) {
            VStack(alignment: .leading, spacing: 12) {
                DayCircles(days: Binding(get: { profile.trainingDays.sorted() }, set: { profile.trainingDays = $0; touched() }),
                           minimum: 1)
                Picker("Session length", selection: Binding(get: { profile.sessionMinutes }, set: { profile.sessionMinutes = $0; touched() })) {
                    ForEach([30, 45, 60, 75], id: \.self) { Text("\($0) min") }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private var starts: some View {
        let answers = answers
        let summary = answers.startSummary(catalog, names: names)
        return ValueRow(name: "Starting point", value: summary, muted: summary == "Found in week 1", open: opened("starts")) {
            VStack(spacing: 8) {
                ForEach(answers.startRows(catalog).filter { $0.measure != .age && $0.measure != .body }, id: \.id) { row in
                    startRow(row, start: answers.starts[row.id])
                }
            }
        }
    }

    /// A lift and a −/+ on its number: the load (reps stay), the reps or the hold.
    private func startRow(_ row: StartRow, start: StartingSet?) -> some View {
        let name = names[row.id] ?? row.id
        let barbell = catalog.first { $0.slug == row.id }?.equipment.contains("barbell") == true
        var label = "–", note = "Week 1 finds it"
        let values: (Double) -> [String: Double]
        let step: Double
        let value: Double
        switch row.measure {
        case .reps:
            value = start?.value("reps") ?? 5
            step = 1
            values = { ["reps": max(0, $0)] }
            if start != nil { label = "\(Coach.number(value)) reps"; note = "Most in a row" }
        case .hold:
            value = start?.value("duration_s") ?? 30
            step = 5
            values = { ["duration_s": max(5, $0)] }
            if start != nil { label = "\(Coach.number(value)) s"; note = "Longest hold" }
        default:
            value = start?.value("load_lb") ?? (barbell ? 95 : 25)
            let reps = start?.value("reps") ?? (barbell ? 5 : 10)
            step = 5
            values = { ["load_lb": max(0, $0), "reps": reps] }
            if start != nil {
                label = "\(Coach.number(value)) lb"
                note = "× \(Coach.number(reps)) · ≈ \(Int(ProgramPlan.estimatedMax(load: value, reps: reps).rounded())) max"
            }
        }
        // An empty row's first press fills in a sensible number to nudge from.
        let shift: Double = start == nil ? 0 : step
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline)
                Text(note).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Nudge(label: label, lessLabel: "Less \(name)", moreLabel: "More \(name)",
                  less: { setStart(row.id, values(value - shift)) }, more: { setStart(row.id, values(value + shift)) })
                .frame(width: 190)
        }
    }

    private func setStart(_ slug: String, _ values: [String: Double]) {
        let units = ["load_lb": "lb", "reps": "reps", "duration_s": "s"]
        let start = StartingSet(exercise: slug, measurements: values.keys.sorted().map {
            Measurement(metric: $0, value: values[$0]!, unit: units[$0] ?? "")
        })
        profile.starts = profile.starts.filter { $0.exercise != slug } + [start]
        touched()
    }

    private var equipment: some View {
        let have = Profile.allEquipment.filter(profile.equipment.contains).map { OnboardingAnswers.equipmentNames[$0] ?? $0 }
        let value = have.isEmpty ? "Bodyweight" : have.count > 2 ? have.prefix(2).joined(separator: ", ") + " +\(have.count - 2)" : have.joined(separator: ", ")
        return ValueRow(name: "Equipment", value: value, note: have.isEmpty ? nil : "\(have.count) things", open: opened("equipment")) {
            Flow {
                ForEach(Profile.allEquipment, id: \.self) { item in
                    Chip(title: OnboardingAnswers.equipmentNames[item] ?? item, on: profile.equipment.contains(item)) {
                        profile.equipment = profile.equipment.contains(item) ? profile.equipment.filter { $0 != item }
                            : Profile.allEquipment.filter { profile.equipment.contains($0) || $0 == item }
                        touched()
                    }
                }
            }
        }
    }

    private func touched() { profile.updatedAt = .now }

    // MARK: Weeks

    private func weekRow(_ index: Int, weeks: [ProgramWeek]) -> some View {
        let week = weeks[index]
        return Button { go(index) } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(index == current ? Color.primary : week.kind == .deload ? Color(.quaternaryLabel) : Color(.tertiaryLabel))
                    .frame(width: 14, height: PhaseBars.height(week))
                    .frame(width: 22, height: 30, alignment: .bottom)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(index + 1)  \(ProgramPlan.title(week))")
                        .fontWeight(index == selected ? .bold : .regular)
                        .foregroundStyle(week.kind == .deload ? .secondary : .primary)
                    Text(line(index)).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(index == current ? "This week" : index == current + 1 ? "Next" : "")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(index == selected ? .isSelected : [])
    }
}

/// What the whole-program sheet can change, kept to put back on Undo.
struct ProgramSettings: Equatable {
    var targetDate: Date?
    var trainingDays: [Int]
    var sessionMinutes: Int
    var equipment: [String]
    var starts: [StartingSet]

    init(_ profile: Profile) {
        targetDate = profile.targetDate
        trainingDays = profile.trainingDays.sorted()
        sessionMinutes = profile.sessionMinutes
        equipment = profile.equipment
        starts = profile.starts.sorted { $0.exercise < $1.exercise }
    }

    func restore(to profile: Profile, goals: [Goal]) {
        if let targetDate { Self.setTargetDate(targetDate, profile: profile, goals: goals) }
        profile.trainingDays = trainingDays
        profile.sessionMinutes = sessionMinutes
        profile.equipment = equipment
        profile.starts = starts
        profile.updatedAt = .now
    }

    /// The program's goals are due on its target date.
    static func setTargetDate(_ date: Date, profile: Profile, goals: [Goal]) {
        profile.targetDate = date
        profile.updatedAt = .now
        for goal in goals where goal.status == .active && GoalOption.all.contains(where: { $0.metric == goal.metric }) {
            goal.deadline = date
            goal.updatedAt = .now
        }
    }
}
