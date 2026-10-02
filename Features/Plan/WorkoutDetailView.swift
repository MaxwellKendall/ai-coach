import SwiftUI
import SwiftData

/// A planned session as blocks (FIT-21, prototype artboard 2). Tap a block to see every set, tap a number
/// to change it with a thumb stepper; Edit changes the structure: reorder, swap, group, remove, add.
/// Works on a copy; nothing is written until Save or Start.
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
    @State private var expanded: Set<UUID> = []
    @State private var restructuring = false
    @State private var selected: Cell?
    @State private var remaining = true

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
        Group {
            if restructuring { structure(names) } else { blocks(names) }
        }
        .background(Color(.secondarySystemBackground))
        .navigationTitle(items.first?.slot ?? "Workout")
        .navigationSubtitle(items.first.map { $0.date.formatted(.dateTime.weekday(.wide).hour().minute()) } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .primaryAction) {
                Button(restructuring ? "Done" : "Edit") {
                    withAnimation(.snappy) { selected = nil; restructuring.toggle() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save(); dismiss() }.disabled(session.items == original.items || session.blocks.isEmpty)
            }
        }
        .safeAreaInset(edge: .bottom) { bottom(names) }
    }

    // MARK: Blocks

    private func blocks(_ names: [String: String]) -> some View {
        ScrollView {
            VStack(spacing: 10) {
                Text(DayPage.summary(session)).font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(Array(session.blocks.enumerated()), id: \.element.id) { index, block in
                    blockCard(index, block, names)
                }
            }
            .padding(16)
        }
    }

    private func blockCard(_ index: Int, _ block: SessionPlan.Block, _ names: [String: String]) -> some View {
        let open = expanded.contains(block.id)
        return VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.snappy) { if open { expanded.remove(block.id) } else { expanded.insert(block.id) } }
            } label: {
                HStack(spacing: 12) {
                    BlockBadge(letter: SessionPlan.letter(index))
                    VStack(alignment: .leading, spacing: 2) {
                        if block.isGroup {
                            Text("\(block.movements.count == 2 ? "SUPERSET" : "CIRCUIT") · \(block.rounds) ROUND\(block.rounds == 1 ? "" : "S")")
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        ForEach(block.movements) { movement in
                            HStack(alignment: .firstTextBaseline) {
                                Text(names[movement.exercise] ?? movement.exercise).font(.headline)
                                Spacer()
                                Text(Self.compact(movement)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Image(systemName: "chevron.down").rotationEffect(.degrees(open ? 180 : 0)).foregroundStyle(.secondary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if open {
                ForEach(Array(block.movements.enumerated()), id: \.element.id) { m, movement in
                    if block.isGroup {
                        Text("\(SessionPlan.letter(index))\(m + 1) · \(names[movement.exercise] ?? movement.exercise)")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    if let note = movement.working.first?.note, !note.isEmpty {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array(movement.sets.enumerated()), id: \.element.id) { s, set in
                        setRow(set, label: set.isWarmup ? "W" : "\(movement.sets[..<s].filter { !$0.isWarmup }.count + 1)",
                               cell: { Cell(block: index, movement: m, set: s, metric: $0) })
                    }
                }
            }
        }
        .padding(14)
        .background(.background, in: .rect(cornerRadius: 20))
    }

    private func setRow(_ set: SessionPlan.PlannedSet, label: String, cell: @escaping (String) -> Cell) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.subheadline.weight(.bold).monospacedDigit()).frame(width: 24)
                .foregroundStyle(set.isWarmup ? .tertiary : .secondary)
            ForEach(Self.editable(set), id: \.self) { metric in
                let isSelected = selected == cell(metric)
                Button { withAnimation(.snappy) { selected = isSelected ? nil : cell(metric) } } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(Self.number(set.value(metric) ?? 0)).font(.title3.weight(.bold).monospacedDigit()).fontWidth(.condensed)
                        Text(SetRow.units[metric] ?? metric).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isSelected ? RootView.accent : .clear, lineWidth: 2))
                }
                .buttonStyle(.plain)
            }
        }
        .opacity(set.isWarmup ? 0.6 : 1)
    }

    // MARK: Structure

    private func structure(_ names: [String: String]) -> some View {
        let exercises = templates.filter { $0.kind == .exercise }
        return List {
            Section {
                ForEach(Array(session.blocks.enumerated()), id: \.element.id) { index, block in
                    HStack(spacing: 12) {
                        BlockBadge(letter: SessionPlan.letter(index))
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(block.movements) { Text(names[$0.exercise] ?? $0.exercise).font(.headline) }
                        }
                        Spacer()
                        Menu("Change \(SessionPlan.letter(index))", systemImage: "ellipsis.circle") {
                            ForEach(Array(block.movements.enumerated()), id: \.element.id) { m, movement in
                                let name = names[movement.exercise] ?? movement.exercise
                                Menu("Swap \(name)", systemImage: "arrow.left.arrow.right") {
                                    ForEach(exercises) { template in
                                        Button(template.name) { session.swap(block: index, movement: m, to: template.slug) }
                                    }
                                }
                                Button("Remove \(name)", systemImage: "trash", role: .destructive) {
                                    withAnimation { session.remove(block: index, movement: m) }
                                }
                            }
                            Divider()
                            if index + 1 < session.blocks.count {
                                Button("Superset with \(SessionPlan.letter(index + 1))", systemImage: "link") {
                                    withAnimation { session.group(index) }
                                }
                            }
                            if block.isGroup {
                                Button("Ungroup", systemImage: "link.badge.plus") { withAnimation { session.ungroup(index) } }
                            }
                        }
                        .labelStyle(.iconOnly)
                        .font(.title2)
                    }
                }
                .onMove { session.blocks.move(fromOffsets: $0, toOffset: $1) }
            } footer: {
                Text("Drag to reorder. Superset joins a block with the next one; its movements are done in rounds.")
            }
            Section {
                Menu("Add exercise", systemImage: "plus") {
                    ForEach(exercises) { template in Button(template.name) { session.add(template.slug) } }
                }
            }
        }
        .environment(\.editMode, .constant(.active))
    }

    // MARK: Bottom

    @ViewBuilder private func bottom(_ names: [String: String]) -> some View {
        if let cell = selected, session.blocks.indices.contains(cell.block) {
            let movement = session.blocks[cell.block].movements[cell.movement]
            let set = movement.sets[cell.set]
            VStack(spacing: 12) {
                HStack {
                    Text("\(names[movement.exercise] ?? movement.exercise) · \(set.isWarmup ? "warm-up" : "set \(movement.sets[..<cell.set].filter { !$0.isWarmup }.count + 1)") · \(Self.label(cell.metric).lowercased())")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Done") { withAnimation(.snappy) { selected = nil } }.fontWeight(.semibold)
                }
                HStack(spacing: 16) {
                    stepButton("minus", cell, -Self.step(cell.metric))
                    VStack(spacing: 0) {
                        Text(Self.number(set.value(cell.metric) ?? 0))
                            .font(.system(size: 44, weight: .bold).monospacedDigit()).fontWidth(.condensed)
                            .contentTransition(.numericText())
                        Text(SetRow.units[cell.metric] ?? "").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    stepButton("plus", cell, Self.step(cell.metric))
                }
                Toggle("Apply to remaining sets", isOn: $remaining).font(.subheadline)
            }
            .padding(16)
            .background(.bar)
            .transition(.move(edge: .bottom))
        } else if let startTitle, !restructuring {
            Button {
                let saved = save()
                dismiss()
                onStart(saved)
            } label: {
                Text(startTitle).font(.headline).frame(maxWidth: .infinity, minHeight: 56)
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
                            set: cell.set, remaining: remaining)
            }
        } label: {
            Image(systemName: symbol).font(.title2.weight(.bold)).frame(width: 60, height: 60)
                .background(Color(.secondarySystemBackground), in: .circle)
        }
        .buttonStyle(.plain)
    }

    @discardableResult
    private func save() -> [PlannedActivity] {
        guard session.items != original.items else { return items }
        return Planner.save(session, over: items, templates: templates, in: context)
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
            .foregroundStyle(RootView.accent)
            .frame(width: size, height: size)
            .background(Color(red: 0.08, green: 0.09, blue: 0.11), in: .rect(cornerRadius: size * 0.3))
    }
}
