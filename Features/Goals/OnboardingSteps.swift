import SwiftUI

/// One onboarding card: 0 goals, 1 exercises, 2 where you're starting, 3 schedule, 4 check the program.
struct OnboardingStepView: View {
    let index: Int
    @Binding var answers: OnboardingAnswers
    @Binding var open: String?
    let catalog: [Exercise]
    let names: [String: String]
    let history: [LoggedSet]
    let go: (Int) -> Void

    var body: some View {
        switch index {
        case 0: goals
        case 1: exercises
        case 2: starts
        case 3: schedule
        default: check
        }
    }

    private func opened(_ id: String, onOpen: @escaping () -> Void = {}) -> Binding<Bool> {
        Binding { open == id } set: {
            open = $0 ? id : nil
            if $0 { onOpen() }
        }
    }

    /// Touching a value makes it the user's: no longer dashed.
    private func touch(_ key: String) { answers.unconfirmed.remove(key) }

    // MARK: Goals

    private var goals: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(GoalOption.all) { option in
                let on = answers.goals.contains(option.id)
                Button {
                    withAnimation(.snappy) {
                        if on { answers.goals.removeAll { $0 == option.id } } else { answers.goals.append(option.id) }
                        touch("goals")
                    }
                } label: {
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(answers.targets[option.id].map(option.title(target:)) ?? option.title)
                                .font(.body)
                                .underline(on && answers.unconfirmed.contains("goals"), pattern: .dash, color: .secondary)
                            Text(option.why).font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .foregroundStyle(on ? Color.primary : Color(.tertiaryLabel))
                    }
                    .padding(.vertical, 12)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
                Divider()
            }
            targetDate.padding(.top, 18)
        }
    }

    private var targetDate: some View {
        let start = Week.monday(of: .now)
        let end = Calendar.current.date(byAdding: .day, value: 7 * answers.weeks - 1, to: start)!
        return ValueRow(name: "Target date", value: end.formatted(.dateTime.month(.abbreviated).day().year()),
                        note: "\(answers.weeks) weeks from \(start.formatted(.dateTime.month(.abbreviated).day()))",
                        dashed: answers.unconfirmed.contains("weeks"), open: opened("date")) {
            Nudge(label: end.formatted(.dateTime.month(.abbreviated).day()), lessLabel: "A week sooner", moreLabel: "A week later",
                  less: { setWeeks(answers.weeks - 1) }, more: { setWeeks(answers.weeks + 1) })
        }
    }

    private func setWeeks(_ weeks: Int) {
        answers.weeks = min(OnboardingAnswers.weekRange.upperBound, max(OnboardingAnswers.weekRange.lowerBound, weeks))
        touch("weeks")
    }

    // MARK: Exercises

    private static let groups = [("Squat", ["squat"]), ("Hinge", ["hinge"]), ("Push", ["push"]), ("Pull", ["pull"]),
                                 ("Carry and core", ["carry", "core"])]

    private var exercises: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("You have")
            Flow {
                ForEach(Profile.allEquipment, id: \.self) { item in
                    Chip(title: OnboardingAnswers.equipmentNames[item] ?? item, on: answers.equipment.contains(item)) {
                        if answers.equipment.contains(item) { answers.equipment.remove(item) } else { answers.equipment.insert(item) }
                    }
                }
            }
            ForEach(Self.groups, id: \.0) { group in
                Eyebrow(group.0).padding(.top, 14)
                Flow {
                    ForEach(catalog.filter { group.1.contains($0.pattern) }, id: \.slug) { exercise in
                        let missing = exercise.equipment.subtracting(answers.equipment)
                        let on = missing.isEmpty && !answers.avoid.contains(exercise.slug)
                        let name = names[exercise.slug] ?? exercise.slug
                        Chip(title: name, on: on, dashed: answers.unconfirmed.contains("move.\(exercise.slug)"), disabled: !missing.isEmpty) {
                            if answers.avoid.contains(exercise.slug) { answers.avoid.remove(exercise.slug) } else { answers.avoid.insert(exercise.slug) }
                            touch("move.\(exercise.slug)")
                        }
                        .accessibilityLabel(missing.isEmpty ? name : "\(name), needs "
                            + missing.sorted().map { (OnboardingAnswers.equipmentNames[$0] ?? $0).lowercased() }.joined(separator: " and "))
                    }
                }
            }
        }
    }

    // MARK: Where you're starting

    private var starts: some View {
        VStack(spacing: 0) {
            ForEach(answers.startRows(catalog), id: \.id) { row in startRow(row) }
        }
    }

    private func startRow(_ row: StartRow) -> some View {
        let start = answers.starts[row.id]
        let dashed = answers.unconfirmed.contains(row.measure == .age ? "age" : row.measure == .body ? "weight" : "start.\(row.id)")
        let (name, detail): (String, String) = switch row.measure {
        case .age: ("Age", "In years")
        case .body: ("Body weight", "This morning")
        case .load: (names[row.id] ?? row.id, "Best recent set")
        case .reps: (names[row.id] ?? row.id, "Most in a row")
        case .hold: (names[row.id] ?? row.id, "Longest hold")
        }
        var value = "Add", note: String? = row.measure == .age || row.measure == .body ? "Needed for your plan" : "Week 1 finds it"
        switch row.measure {
        case .age: if let age = answers.age { value = "\(age)"; note = nil }
        case .body: if let weight = answers.weight { value = "\(Coach.number(weight)) lb"; note = nil }
        case .load:
            if let load = start?.value("load_lb"), let reps = start?.value("reps") {
                value = "\(Coach.number(load)) × \(Coach.number(reps))"
                note = "≈ \(Int(ProgramPlan.estimatedMax(load: load, reps: reps).rounded())) max"
            }
        case .reps: if let reps = start?.value("reps") { value = "\(Coach.number(reps)) reps"; note = dashed ? "from your logs" : nil }
        case .hold: if let seconds = start?.value("duration_s") { value = "\(Coach.number(seconds)) s"; note = dashed ? "from your logs" : nil }
        }
        return ValueRow(name: name, detail: detail, value: value, note: note, dashed: dashed && value != "Add",
                        muted: value == "Add", open: opened(row.id) { fillDefault(row) }) {
            VStack(spacing: 10) {
                startEditor(row)
                if row.measure != .age && row.measure != .body {
                    Button("I don’t know") {
                        withAnimation(.snappy) { answers.starts[row.id] = nil; open = nil }
                    }
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(minHeight: 44)
                }
            }
        }
    }

    @ViewBuilder private func startEditor(_ row: StartRow) -> some View {
        let start = answers.starts[row.id]
        switch row.measure {
        case .age:
            Nudge(label: "\(answers.age ?? 35)", less: { answers.age = max(13, (answers.age ?? 35) - 1); touch("age") },
                  more: { answers.age = min(100, (answers.age ?? 35) + 1); touch("age") })
        case .body:
            Nudge(label: "\(Coach.number(answers.weight ?? 180)) lb", less: { answers.weight = max(60, (answers.weight ?? 180) - 1); touch("weight") },
                  more: { answers.weight = (answers.weight ?? 180) + 1; touch("weight") })
        case .load:
            let load = start?.value("load_lb") ?? 45, reps = start?.value("reps") ?? 5
            Nudge(label: "\(Coach.number(load)) lb", less: { set(row.id, load: max(0, load - 5), reps: reps) },
                  more: { set(row.id, load: load + 5, reps: reps) })
            Nudge(label: "\(Coach.number(reps)) reps", lessLabel: "Fewer reps", moreLabel: "More reps",
                  less: { set(row.id, load: load, reps: max(1, reps - 1)) }, more: { set(row.id, load: load, reps: min(20, reps + 1)) })
        case .reps:
            let reps = start?.value("reps") ?? 5
            Nudge(label: "\(Coach.number(reps)) reps", less: { set(row.id, ["reps": max(0, reps - 1)]) },
                  more: { set(row.id, ["reps": reps + 1]) })
        case .hold:
            let seconds = start?.value("duration_s") ?? 30
            Nudge(label: "\(Coach.number(seconds)) s", less: { set(row.id, ["duration_s": max(5, seconds - 5)]) },
                  more: { set(row.id, ["duration_s": seconds + 5]) })
        }
    }

    private func set(_ slug: String, load: Double, reps: Double) { set(slug, ["load_lb": load, "reps": reps]) }

    private func set(_ slug: String, _ values: [String: Double]) {
        let units = ["load_lb": "lb", "reps": "reps", "duration_s": "s"]
        answers.starts[slug] = StartingSet(exercise: slug, measurements: values.keys.sorted().map {
            Measurement(metric: $0, value: values[$0]!, unit: units[$0] ?? "")
        })
        touch("start.\(slug)")
    }

    /// Opening an empty row starts it somewhere sensible to nudge from.
    private func fillDefault(_ row: StartRow) {
        switch row.measure {
        case .age: if answers.age == nil { answers.age = 35 }
        case .body: if answers.weight == nil { answers.weight = 180 }
        case .load:
            guard answers.starts[row.id] == nil else { return }
            let barbell = catalog.first { $0.slug == row.id }?.equipment.contains("barbell") == true
            set(row.id, load: barbell ? 95 : 25, reps: barbell ? 5 : 10)
        case .reps: if answers.starts[row.id] == nil { set(row.id, ["reps": 5]) }
        case .hold: if answers.starts[row.id] == nil { set(row.id, ["duration_s": 30]) }
        }
    }

    // MARK: Schedule

    private var schedule: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("Days · \(answers.days.count) a week")
            DayCircles(days: Binding(get: { answers.days }, set: { answers.days = $0; touch("days") }),
                       dashed: answers.unconfirmed.contains("days"))
            Eyebrow("Each session").padding(.top, 14)
            Picker("Session length", selection: Binding(get: { answers.minutes }, set: { answers.minutes = $0; touch("minutes") })) {
                ForEach([30, 45, 60, 75], id: \.self) { Text("\($0) min") }
            }
            .pickerStyle(.segmented)
            Eyebrow("Work around").padding(.top, 14)
            Flow {
                ForEach(OnboardingAnswers.hurtAreas + answers.hurts.subtracting(OnboardingAnswers.hurtAreas).sorted(), id: \.self) { area in
                    let on = answers.hurts.contains(area)
                    Chip(title: area.prefix(1).uppercased() + area.dropFirst(), on: on, dashed: on && answers.unconfirmed.contains("hurts")) {
                        if on { answers.hurts.remove(area) } else { answers.hurts.insert(area) }
                        touch("hurts")
                    }
                }
            }
            Text(answers.hurts.isEmpty ? "Nothing picked. You can say it any time later."
                 : "Exercises that load your \(answers.hurts.sorted().formatted(.list(type: .and))) are left out.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    // MARK: Check

    private var check: some View {
        let weeks = ProgramPlan.weeks(count: answers.weeks, deloadEvery: AgeTier.of(age: answers.age ?? 35).deloadEveryWeeks)
        let picked = answers.goals.compactMap(GoalOption.with(id:))
        return VStack(alignment: .leading, spacing: 0) {
            Eyebrow("Check it").padding(.top, 18)
            Text("Your program").font(.system(size: 30, weight: .bold)).tracking(-0.4).padding(.top, 4)
            if !answers.unconfirmed.isEmpty || picked.contains(where: { answers.targets[$0.id] == nil }) {
                Text("Underlined values are what I heard or suggested. Tap one to change it.")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.top, 6)
            }
            Eyebrow("Goals").padding(.top, 22)
            if picked.isEmpty {
                ValueRow(name: "No goals yet", value: "Pick", muted: true, open: Binding(get: { false }, set: { _ in go(0) })) {}
            }
            ForEach(picked) { option in goalRow(option) }
            Eyebrow("Program").padding(.top, 22)
            targetDate
            ValueRow(name: "Training", value: answers.training, open: Binding(get: { false }, set: { _ in go(3) })) {}
            let startSummary = answers.startSummary(catalog, names: names)
            ValueRow(name: "Starting point", value: startSummary, muted: startSummary == "Found in week 1",
                     open: Binding(get: { false }, set: { _ in go(2) })) {}
            PhaseBars(weeks: weeks).padding(.top, 22)
            Text("Weeks 1–\(weeks.filter { $0.phase == .base }.count) build a base. Then the work climbs, the last weeks peak, and week \(weeks.count) tests your goals. A lighter deload comes every few weeks. Each week is planned when the one before ends, from how it went.")
                .font(.subheadline).foregroundStyle(.secondary).padding(.top, 12)
        }
    }

    private func goalRow(_ option: GoalOption) -> some View {
        let target = answers.target(option)
        let from = answers.baseline(option)
        let value = target.map { target in (from.map { "\(Coach.number($0)) → " } ?? "") + "\(Coach.number(target)) \(option.unit)" }
        return ValueRow(name: option.name, value: value ?? "Needs a starting point", dashed: target != nil && (answers.targets[option.id] == nil
                            || answers.unconfirmed.contains("target.\(option.id)")),
                        muted: target == nil, open: opened("goal.\(option.id)") { if target == nil { go(2) } }) {
            if let target {
                Nudge(label: "\(Coach.number(target)) \(option.unit)", lessLabel: "Lower", moreLabel: "Raise",
                      less: { answers.targets[option.id] = max(0, target - option.step); touch("target.\(option.id)") },
                      more: { answers.targets[option.id] = target + option.step; touch("target.\(option.id)") })
            }
        }
    }
}

extension OnboardingAnswers {
    /// "Mon Wed Fri · 45 min".
    var training: String {
        days.sorted().map { String(ProfileEditor.weekdays[$0].prefix(3)) }.joined(separator: " ") + " · \(minutes) min"
    }

    /// "Bench ≈185 · Squat ≈225", or "Found in week 1".
    func startSummary(_ catalog: [Exercise], names: [String: String]) -> String {
        let parts = startRows(catalog).filter { $0.measure != .age && $0.measure != .body }.compactMap { row -> String? in
            guard let start = starts[row.id] else { return nil }
            let name = (names[row.id] ?? row.id).split(separator: " ").first.map(String.init) ?? row.id
            if let load = start.value("load_lb"), let reps = start.value("reps") {
                return "\(name) ≈\(Int(ProgramPlan.estimatedMax(load: load, reps: reps).rounded()))"
            }
            if let reps = start.value("reps") { return "\(name) \(Coach.number(reps)) reps" }
            return start.value("duration_s").map { "\(name) \(Coach.number($0)) s" }
        }
        return parts.isEmpty ? "Found in week 1" : parts.prefix(3).joined(separator: " · ")
    }
}
