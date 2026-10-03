import SwiftUI
import SwiftData

/// A planned session as blocks (FIT-21, prototype artboard 2). Everything is editable in place: every set
/// shows its reps and load, tapping one opens a thumb stepper, and each block's footer has Swap, + Set and
/// a menu for superset, move and remove. Works on a copy; nothing is written until Save or Start.
struct WorkoutDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Template.name) private var templates: [Template]
    let items: [PlannedActivity]
    var startTitle: String?
    /// Called with the saved rows when the user starts the session from here.
    var onStart: ([PlannedActivity]) -> Void = { _ in }
    @State private var session: SessionPlan
    @State private var original: SessionPlan
    @State private var collapsed: Set<UUID> = []
    @State private var selected: Cell?

    /// The number being changed in the bottom stepper.
    struct Cell: Equatable {
        var block: Int, movement: Int, set: Int
        var metric: String
    }

    init(items: [PlannedActivity], session: SessionPlan, startTitle: String? = nil,
         onStart: @escaping ([PlannedActivity]) -> Void = { _ in }) {
        self.items = items
        self.startTitle = startTitle
        self.onStart = onStart
        _session = State(initialValue: session)
        _original = State(initialValue: session)
    }

    var body: some View {
        let names = Dictionary(templates.map { ($0.slug, $0.name) }, uniquingKeysWith: { first, _ in first })
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    header
                    ForEach(Array(session.blocks.enumerated()), id: \.element.id) { index, block in
                        blockCard(index, block, names).id(block.id)
                    }
                    Menu {
                        ForEach(templates.filter { $0.kind == .exercise }) { template in
                            Button(template.name) { withAnimation(.snappy) { session.add(template.slug) } }
                        }
                    } label: {
                        Label("Add exercise", systemImage: "plus")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
                    }
                }
                .padding(16)
            }
            .onChange(of: selected) { _, cell in
                if let cell, session.blocks.indices.contains(cell.block) {
                    withAnimation { proxy.scrollTo(session.blocks[cell.block].id, anchor: .center) }
                }
            }
        }
        .background(Color(.secondarySystemBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save(); dismiss() }.disabled(session.items == original.items || session.blocks.isEmpty)
            }
        }
        .safeAreaInset(edge: .bottom) { bottom(names) }
    }

    // MARK: Header

    private var header: some View {
        let rpe = session.blocks.flatMap(\.movements).flatMap(\.sets).compactMap { $0.value("rpe") }.max()
        let sets = session.blocks.flatMap(\.movements).reduce(0) { $0 + $1.working.count }
        return VStack(alignment: .leading, spacing: 8) {
            if let date = items.first?.date {
                Text(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()).uppercased())
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            Text(items.first?.slot ?? "Workout")
                .font(.system(size: 40, weight: .heavy)).fontWidth(.condensed)
            HStack(spacing: 6) {
                chip("\(sets) working sets")
                if let rpe { chip("RPE ≤ \(Self.number(rpe))") }
                ForEach(Set(session.blocks.flatMap(\.movements).flatMap(\.sets).compactMap(\.adjustedReason)).sorted(), id: \.self) {
                    chip($0)
                }
            }
        }
        .padding(.bottom, 6)
    }

    private func chip(_ text: String) -> some View {
        Text(text).font(.footnote.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.background, in: .capsule)
    }

    // MARK: Blocks

    private func blockCard(_ index: Int, _ block: SessionPlan.Block, _ names: [String: String]) -> some View {
        let open = !collapsed.contains(block.id)
        let letter = SessionPlan.letter(index)
        return VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.snappy) { if open { collapsed.insert(block.id) } else { collapsed.remove(block.id) } }
            } label: {
                HStack(spacing: 12) {
                    BlockBadge(letter: letter)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Self.kind(block)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(block.movements.map { names[$0.exercise] ?? $0.exercise }.joined(separator: " + "))
                            .font(.headline).multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down").rotationEffect(.degrees(open ? 180 : 0)).foregroundStyle(.secondary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if open {
                ForEach(Array(block.movements.enumerated()), id: \.element.id) { m, movement in
                    if block.isGroup {
                        Text("\(letter)\(m + 1)  \(names[movement.exercise] ?? movement.exercise)")
                            .font(.subheadline.weight(.semibold))
                    }
                    if let note = movement.working.first?.note, !note.isEmpty {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array(movement.sets.enumerated()), id: \.element.id) { s, set in
                        setRow(set, label: set.isWarmup ? "W" : "\(movement.sets[..<s].filter { !$0.isWarmup }.count + 1)",
                               cell: { Cell(block: index, movement: m, set: s, metric: $0) })
                    }
                }
                footer(index, block, names)
            }
        }
        .padding(14)
        .background(.background, in: .rect(cornerRadius: 20))
    }

    private func setRow(_ set: SessionPlan.PlannedSet, label: String, cell: @escaping (String) -> Cell) -> some View {
        let metrics = Self.editable(set)
        return HStack(spacing: 8) {
            Text(label).font(.subheadline.weight(.bold).monospacedDigit()).frame(width: 24)
                .foregroundStyle(set.isWarmup ? .tertiary : .secondary)
            ForEach(metrics, id: \.self) { metric in
                let isSelected = selected == cell(metric)
                Button { withAnimation(.snappy) { selected = isSelected ? nil : cell(metric) } } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(Self.number(set.value(metric) ?? 0)).font(.title3.weight(.bold).monospacedDigit()).fontWidth(.condensed)
                        Text(SetRow.units[metric] ?? metric).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(isSelected ? Color.primary.opacity(0.12) : Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isSelected ? Color.primary : .clear, lineWidth: 2))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            if metrics.count == 1 {
                Text("bodyweight").font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
        }
        .opacity(set.isWarmup ? 0.6 : 1)
    }

    /// Rest, then the block's edits: Swap, + Set and the rest in a menu.
    private func footer(_ index: Int, _ block: SessionPlan.Block, _ names: [String: String]) -> some View {
        let exercises = templates.filter { $0.kind == .exercise }
        let restAfter = block.movements.last?.working.first.map { set in
            WorkoutDraft.rest(metric: ["duration_s", "distance_m"].first { set.value($0) != nil } ?? "reps", value: set.value("reps"))
        }
        return HStack(spacing: 8) {
            if let restAfter {
                Text("Rest \(Duration.seconds(restAfter).formatted(.time(pattern: .minuteSecond)))\(block.isGroup ? " / round" : "")")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Menu {
                if index + 1 < session.blocks.count {
                    Button("Superset with \(SessionPlan.letter(index + 1))", systemImage: "link") { withAnimation(.snappy) { session.group(index) } }
                }
                if block.isGroup {
                    Button("Ungroup", systemImage: "square.split.1x2") { withAnimation(.snappy) { session.ungroup(index) } }
                }
                if index > 0 {
                    Button("Move up", systemImage: "arrow.up") { withAnimation(.snappy) { selected = nil; session.move(block: index, by: -1) } }
                }
                if index + 1 < session.blocks.count {
                    Button("Move down", systemImage: "arrow.down") { withAnimation(.snappy) { selected = nil; session.move(block: index, by: 1) } }
                }
                if block.rounds > 1 {
                    Button(block.isGroup ? "Remove last round" : "Remove last set", systemImage: "minus") {
                        withAnimation(.snappy) { selected = nil; session.removeSet(block: index) }
                    }
                }
                Divider()
                ForEach(Array(block.movements.enumerated()), id: \.element.id) { m, movement in
                    Button("Remove \(names[movement.exercise] ?? movement.exercise)", systemImage: "trash", role: .destructive) {
                        withAnimation(.snappy) { selected = nil; session.remove(block: index, movement: m) }
                    }
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 44, height: 36)
                    .background(Color(.secondarySystemBackground), in: .capsule)
            }
            Menu {
                ForEach(Array(block.movements.enumerated()), id: \.element.id) { m, movement in
                    Menu(block.isGroup ? "Swap \(names[movement.exercise] ?? movement.exercise)" : "Swap with") {
                        ForEach(exercises) { template in
                            Button(template.name) { session.swap(block: index, movement: m, to: template.slug) }
                        }
                    }
                }
            } label: {
                Text("Swap").font(.subheadline.weight(.semibold)).padding(.horizontal, 14).frame(height: 36)
                    .background(Color(.secondarySystemBackground), in: .capsule)
            }
            Button {
                withAnimation(.snappy) { session.addSet(block: index) }
            } label: {
                Text(block.isGroup ? "+ Round" : "+ Set").font(.subheadline.weight(.semibold)).padding(.horizontal, 14).frame(height: 36)
                    .background(Color(.secondarySystemBackground), in: .capsule)
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.primary)
    }

    // MARK: Bottom

    @ViewBuilder private func bottom(_ names: [String: String]) -> some View {
        if let cell = selected, session.blocks.indices.contains(cell.block),
           session.blocks[cell.block].movements.indices.contains(cell.movement),
           session.blocks[cell.block].movements[cell.movement].sets.indices.contains(cell.set) {
            let movement = session.blocks[cell.block].movements[cell.movement]
            let set = movement.sets[cell.set]
            let number = movement.sets[..<cell.set].filter { !$0.isWarmup }.count + 1
            VStack(spacing: 12) {
                HStack {
                    Text("\(names[movement.exercise] ?? movement.exercise) · \(set.isWarmup ? "warm-up" : "set \(number)") · \(Self.label(cell.metric).lowercased())")
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Button("Done") { withAnimation(.snappy) { selected = nil } }.fontWeight(.semibold)
                }
                HStack(spacing: 16) {
                    stepButton("minus", cell, -Self.step(cell.metric))
                    VStack(spacing: 0) {
                        Text(Self.number(set.value(cell.metric) ?? 0))
                            .font(.system(size: 48, weight: .bold).monospacedDigit()).fontWidth(.condensed)
                            .contentTransition(.numericText())
                        Text(SetRow.units[cell.metric] ?? "").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    stepButton("plus", cell, Self.step(cell.metric))
                }
                Button {
                    withAnimation(.snappy) {
                        session.set(cell.metric, to: set.value(cell.metric) ?? 0, block: cell.block, movement: cell.movement,
                                    set: cell.set, remaining: true)
                        selected = nil
                    }
                } label: {
                    Text("Apply to remaining sets").font(.headline).frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 14))
            }
            .padding(16)
            .background(.bar)
            .transition(.move(edge: .bottom))
        } else if let startTitle {
            Button {
                let saved = save()
                dismiss()
                onStart(saved)
            } label: {
                Label(startTitle, systemImage: "play.fill").font(.headline).frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 18))
            .tint(Color(.label))
            .foregroundStyle(Color(.systemBackground))
            .disabled(session.blocks.isEmpty)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private func stepButton(_ symbol: String, _ cell: Cell, _ delta: Double) -> some View {
        Button {
            let current = session.blocks[cell.block].movements[cell.movement].sets[cell.set].value(cell.metric) ?? 0
            withAnimation(.snappy) {
                session.set(cell.metric, to: max(0, current + delta), block: cell.block, movement: cell.movement,
                            set: cell.set, remaining: false)
            }
        } label: {
            Image(systemName: symbol).font(.title2.weight(.bold)).frame(width: 64, height: 64)
                .background(Color(.secondarySystemBackground), in: .circle)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: session.blocks[cell.block].movements[cell.movement].sets[cell.set].value(cell.metric))
    }

    @discardableResult
    private func save() -> [PlannedActivity] {
        guard session.items != original.items else { return items }
        return Planner.save(session, over: items, templates: templates, in: context)
    }

    /// "MAIN LIFT", "SUPERSET · 3 ROUNDS" or "ACCESSORY" above the block's name.
    nonisolated static func kind(_ block: SessionPlan.Block) -> String {
        if block.isGroup {
            return "\(block.movements.count == 2 ? "SUPERSET" : "CIRCUIT") · \(block.rounds) ROUND\(block.rounds == 1 ? "" : "S")"
        }
        let sets = block.movements.first?.sets ?? []
        let dose = block.movements.first.map(compact) ?? ""
        return (sets.contains(where: \.isWarmup) ? "MAIN LIFT · " : "") + dose
    }

    // MARK: Formatting

    /// The numbers a set can change: its reps (or time or distance) and its load.
    nonisolated static func editable(_ set: SessionPlan.PlannedSet) -> [String] {
        ["reps", "duration_s", "distance_m", "load_lb", "load_lb_hand"].filter { set.value($0) != nil }
    }

    /// "3×5 · 140" for the working sets; differing numbers show as a range, "3×10 · 85–90".
    nonisolated static func compact(_ movement: SessionPlan.Movement) -> String {
        let working = movement.working
        guard let first = working.first else { return "" }
        func range(_ metric: String) -> String {
            let values = working.compactMap { $0.value(metric) }
            guard let low = values.min(), let high = values.max() else { return "" }
            return low == high ? number(low) : "\(number(low))–\(number(high))"
        }
        let metrics = editable(first)
        let amount = metrics.first.map(range) ?? ""
        let load = metrics.dropFirst().first.map { " · \(range($0))" } ?? ""
        return "\(working.count)×\(amount)\(load)"
    }

    nonisolated static func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...1))) }

    nonisolated static func step(_ metric: String) -> Double {
        switch metric {
        case "rpe": 0.5
        case "duration_s", "distance_m", "load_lb", "load_lb_hand": 5
        default: 1
        }
    }

    nonisolated static func label(_ metric: String) -> String {
        ["sets": "Sets", "reps": "Reps", "load_lb": "Load", "load_lb_hand": "Load per hand", "rpe": "RPE cap",
         "duration_s": "Time", "distance_m": "Distance"][metric] ?? Goal.label(metric)
    }
}

/// The block letter in a dark rounded square, as in the prototype.
struct BlockBadge: View {
    let letter: String
    var size: CGFloat = 36

    var body: some View {
        Text(letter)
            .font(.system(size: size * 0.55, weight: .bold)).fontWidth(.condensed)
            .foregroundStyle(Color.primary)
            .frame(width: size, height: size)
            .background(Color(red: 0.08, green: 0.09, blue: 0.11), in: .rect(cornerRadius: size * 0.3))
    }
}
