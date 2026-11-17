import SwiftUI

/// TKL-753: the one session editor. A block's sets, each a row whose numbers open the bottom stepper (`SetStepper`), and
/// its footer: rest, then ⋯ (superset, ungroup, move, remove last set, how-to, remove), Swap and + Set. Program › session
/// shows it in every block card; Today opens it in place under a lift. Every change goes through `session`.
struct BlockEditor: View {
    @Binding var session: SessionPlan
    let index: Int
    let names: [String: String]
    let templates: [Template]
    /// The number being changed in the bottom stepper.
    @Binding var selected: Cell?
    var onSwap: (_ block: Int, _ movement: Int, _ exercise: String) -> Void
    var onHowTo: (String) -> Void
    /// Today opens the card on its own fill, so the numbers sit on the surface colour there.
    var onFill = false

    /// The number being changed in the bottom stepper.
    struct Cell: Equatable {
        var block: Int, movement: Int, set: Int
        var metric: String
    }

    var body: some View {
        if session.blocks.indices.contains(index) {
            let block = session.blocks[index]
            let letter = SessionPlan.letter(session.blocks[..<index].filter { $0.rounds > 0 }.count)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(block.movements.enumerated()), id: \.element.id) { m, movement in
                    if block.isGroup {
                        Text("\(letter)\(m + 1)  \(names[movement.exercise] ?? movement.exercise)")
                            .font(.subheadline.weight(.semibold))
                    }
                    if let note = movement.working.first?.note, !note.isEmpty {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array(movement.sets.enumerated()), id: \.element.id) { s, set in
                        let label = set.isWarmup ? "W" : "\(movement.sets[..<s].filter { !$0.isWarmup }.count + 1)"
                        setRow(set, label: label, name: names[movement.exercise] ?? movement.exercise,
                               load: loadMetric(movement.exercise), weighted: weighted(movement.exercise),
                               id: { "set.\(m).\(label).\($0)" },
                               cell: { Cell(block: index, movement: m, set: s, metric: $0) })
                    }
                }
                footer(block)
            }
        }
    }

    /// The load a bodyweight exercise takes when one's added: each dumbbell or kettlebell, else pounds on the body.
    private func loadMetric(_ slug: String) -> String {
        let equipment = templates.first { $0.slug == slug }?.values("equipment") ?? []
        return !Set(equipment).isDisjoint(with: ["dumbbells", "kettlebells"]) && !equipment.contains("barbell") ? "load_lb_hand" : "load_lb"
    }

    /// Done with a weight (dumbbells, a barbell…): with none set yet it says so, never "bodyweight".
    private func weighted(_ slug: String) -> Bool {
        !Set(templates.first { $0.slug == slug }?.values("equipment") ?? []).isDisjoint(with: Exercise.weights)
    }

    private func setRow(_ set: SessionPlan.PlannedSet, label: String, name: String, load: String, weighted: Bool,
                        id: @escaping (String) -> String, cell: @escaping (String) -> Cell) -> some View {
        let metrics = WorkoutDetailView.editable(set)
        let fill = onFill ? Color.surface : Color.fill
        return HStack(spacing: 8) {
            Text(label).font(.subheadline.weight(.bold).monospacedDigit()).frame(width: 24)
                .foregroundStyle(set.isWarmup ? .tertiary : .secondary)
            ForEach(metrics, id: \.self) { metric in
                let isSelected = selected == cell(metric)
                let value = WorkoutDetailView.number(set.value(metric) ?? 0)
                let unit = SetRow.units[metric] ?? metric
                Button { withAnimation(.tap) { selected = isSelected ? nil : cell(metric) } } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(value).font(.title3.weight(.bold).monospacedDigit())
                        Text(unit).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(isSelected ? Color.primary.opacity(0.12) : fill, in: .rect(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isSelected ? Color.primary : .clear, lineWidth: 2))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(id(metric))
                .accessibilityLabel("\(value) \(unit)")
                .accessibilityHint("\(name), \(set.isWarmup ? "warm-up" : "set \(label)")")
            }
            if metrics.count == 1 {
                // FIT-81: tap to add a load ("bodyweight" until one's set; back to 0 is bodyweight again).
                let isSelected = selected == cell(load)
                let text = isSelected ? "0 \(SetRow.units[load] ?? "lb")" : weighted ? "add weight" : "bodyweight"
                Button { withAnimation(.tap) { selected = isSelected ? nil : cell(load) } } label: {
                    Text(text).font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(isSelected ? Color.primary.opacity(0.12) : .clear, in: .rect(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isSelected ? Color.primary : .clear, lineWidth: 2))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(id(load))
                .accessibilityLabel(text)
                .accessibilityHint("Adds a weight")
            }
        }
        .opacity(set.isWarmup ? 0.6 : 1)
    }

    /// Rest, then the block's edits: Swap, + Set and the rest in a menu.
    private func footer(_ block: SessionPlan.Block) -> some View {
        let restAfter = block.movements.last?.working.first.map { set in
            WorkoutDraft.rest(metric: ["duration_s", "distance_m"].first { set.value($0) != nil } ?? "reps", value: set.value("reps"))
        }
        let rest = restAfter.map { Text("Rest \(Duration.seconds($0).formatted(.time(pattern: .minuteSecond)))\(block.isGroup ? " / round" : "")")
            .font(.subheadline).foregroundStyle(.secondary).fixedSize() }
        // One line where it fits (Program's full-width card); on Today's narrower open lift, rest above the actions.
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                rest
                Spacer(minLength: 0)
                actions(block)
            }
            VStack(alignment: .leading, spacing: 10) {
                rest
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    actions(block)
                }
            }
        }
        .foregroundStyle(.primary)
    }

    /// ⋯, Swap and + Set.
    private func actions(_ block: SessionPlan.Block) -> some View {
        let fill = onFill ? Color.surface : Color.fill
        return HStack(spacing: 8) {
            Menu {
                if index + 1 < session.blocks.count {
                    Button("Superset with \(SessionPlan.letter(index + 1))", systemImage: "link") { withAnimation(.settle) { selected = nil; session.group(index) } }
                }
                if block.isGroup {
                    Button("Ungroup", systemImage: "square.split.1x2") { withAnimation(.settle) { selected = nil; session.ungroup(index) } }
                }
                if index > 0 {
                    Button("Move up", systemImage: "arrow.up") { withAnimation(.settle) { selected = nil; session.move(block: index, by: -1) } }
                }
                if index + 1 < session.blocks.count {
                    Button("Move down", systemImage: "arrow.down") { withAnimation(.settle) { selected = nil; session.move(block: index, by: 1) } }
                }
                if block.rounds > 1 {
                    Button(block.isGroup ? "Remove last round" : "Remove last set", systemImage: "minus") {
                        withAnimation(.settle) { selected = nil; session.removeSet(block: index) }
                    }
                }
                // FIT-75: how to do it, for exercises the model picked that you may not know.
                ForEach(block.movements, id: \.id) { movement in
                    if !(templates.first { $0.slug == movement.exercise }?.values("instructions") ?? []).isEmpty
                        || HowToPhotos.shows(movement.exercise)
                        || ExerciseVideos.bundled[movement.exercise] != nil {
                        Button(block.isGroup ? "How to Do \(names[movement.exercise] ?? movement.exercise)" : "How to Do It",
                               systemImage: "questionmark.circle") { onHowTo(movement.exercise) }
                    }
                }
                Divider()
                ForEach(Array(block.movements.enumerated()), id: \.element.id) { m, movement in
                    Button("Remove \(names[movement.exercise] ?? movement.exercise)", systemImage: "trash", role: .destructive) {
                        withAnimation(.settle) { selected = nil; session.remove(block: index, movement: m) }
                    }
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 44, height: 36)
                    .background(fill, in: .capsule)
            }
            .accessibilityIdentifier("session.more")
            .accessibilityLabel("More")
            // FIT-81: a short list for the movement, and search, not the whole catalog.
            if block.isGroup {
                Menu {
                    ForEach(Array(block.movements.enumerated()), id: \.element.id) { m, movement in
                        Button("Swap \(names[movement.exercise] ?? movement.exercise)") { onSwap(index, m, movement.exercise) }
                    }
                } label: { capsule("Swap", fill) }
                .accessibilityIdentifier("session.swap")
            } else if let movement = block.movements.first {
                Button { onSwap(index, 0, movement.exercise) } label: { capsule("Swap", fill) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("session.swap")
            }
            Button {
                withAnimation(.settle) { session.addSet(block: index) }
            } label: { capsule(block.isGroup ? "+ Round" : "+ Set", fill) }
            .buttonStyle(.plain)
            .accessibilityIdentifier("session.addSet")
        }
        .fixedSize()
    }

    private func capsule(_ title: String, _ fill: Color) -> some View {
        Text(title).font(.subheadline.weight(.semibold)).padding(.horizontal, 14).frame(height: 36)
            .background(fill, in: .capsule)
    }
}

/// TKL-753: the thumb stepper for the number `selected` names: ± by its step, Done, and Apply to remaining sets.
struct SetStepper: View {
    @Binding var session: SessionPlan
    @Binding var selected: BlockEditor.Cell?
    let names: [String: String]

    var body: some View {
        if let cell = selected, session.blocks.indices.contains(cell.block),
           session.blocks[cell.block].movements.indices.contains(cell.movement),
           session.blocks[cell.block].movements[cell.movement].sets.indices.contains(cell.set) {
            let movement = session.blocks[cell.block].movements[cell.movement]
            let set = movement.sets[cell.set]
            let number = movement.sets[..<cell.set].filter { !$0.isWarmup }.count + 1
            VStack(spacing: 12) {
                HStack {
                    Text("\(names[movement.exercise] ?? movement.exercise) · \(set.isWarmup ? "warm-up" : "set \(number)") · \(WorkoutDetailView.label(cell.metric).lowercased())")
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Button("Done") { withAnimation(.tap) { selected = nil } }.fontWeight(.semibold)
                        .accessibilityIdentifier("stepper.done")
                }
                HStack(spacing: 16) {
                    stepButton("minus", cell, -WorkoutDetailView.step(cell.metric)).accessibilityIdentifier("stepper.minus")
                    VStack(spacing: 0) {
                        Text(WorkoutDetailView.number(set.value(cell.metric) ?? 0))
                            .font(.display(48, weight: .bold).monospacedDigit())
                            .contentTransition(.numericText(value: set.value(cell.metric) ?? 0))
                        Text(SetRow.units[cell.metric] ?? "").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    stepButton("plus", cell, WorkoutDetailView.step(cell.metric)).accessibilityIdentifier("stepper.plus")
                }
                Button {
                    withAnimation(.settle) {
                        session.set(cell.metric, to: set.value(cell.metric) ?? 0, block: cell.block, movement: cell.movement,
                                    set: cell.set, remaining: true)
                        selected = nil
                    }
                } label: {
                    Text("Apply to remaining sets").font(.headline).frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 14))
                .accessibilityIdentifier("stepper.apply")
            }
            .padding(16)
        }
    }

    private func stepButton(_ symbol: String, _ cell: BlockEditor.Cell, _ delta: Double) -> some View {
        Button {
            let current = session.blocks[cell.block].movements[cell.movement].sets[cell.set].value(cell.metric) ?? 0
            withAnimation(.settle) {
                session.set(cell.metric, to: max(0, current + delta), block: cell.block, movement: cell.movement,
                            set: cell.set, remaining: false)
            }
        } label: {
            Image(systemName: symbol).font(.title2.weight(.bold)).frame(width: 64, height: 64)
                .background(Color.fill, in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(delta < 0 ? "Less" : "More")
        .sensoryFeedback(.tick, trigger: session.blocks[cell.block].movements[cell.movement].sets[cell.set].value(cell.metric))
    }
}
