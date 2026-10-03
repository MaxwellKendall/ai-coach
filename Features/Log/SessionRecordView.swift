import SwiftUI
import SwiftData

/// A finished session (FIT-21, prototype artboard 4): totals, then one block per page, swiped or picked from
/// the letter tabs. Single lifts show their sets; supersets and circuits show one row per round. Each block
/// says what its estimated max is and what the progression rule plans next time.
struct SessionRecordView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \LogEntry.timestamp) private var entries: [LogEntry]
    @Query private var templates: [Template]
    @Query private var profiles: [Profile]
    let planned: [PlannedActivity]
    @State private var page = 0

    var body: some View {
        let bySlug = Dictionary(templates.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
        let day = planned.first?.date ?? .now
        let mine = SessionRecord.lastSession(
            entries.filter { $0.kind == .workout && Calendar.current.isDate($0.timestamp, inSameDayAs: day) },
            isSummary: { $0.templateRef == nil })
        let groups = Dictionary(planned.map { ($0.id, $0.group) }, uniquingKeysWith: { first, _ in first })
        // One set per entry, so each keeps its planned row's superset group.
        let pairs = mine.compactMap { entry in
            Planner.loggedSets([entry], templates: templates).first.map { ($0, entry.plannedRef.flatMap { groups[$0] } ?? nil) }
        }
        let record = SessionRecord(pairs.map(\.0), groups: pairs.map(\.1))
        let summary = mine.first { $0.templateRef == nil }?.measurements ?? []
        VStack(spacing: 14) {
            stats(record, summary: summary)
            if !record.blocks.isEmpty {
                tabs(record)
                SwipeDeck(index: $page, count: record.blocks.count) { index in
                    ScrollView { blockPage(index, record.blocks[index], bySlug) }
                        .background(Color(.secondarySystemBackground))
                }
                .padding(.horizontal, 16)
            } else {
                ContentUnavailableView("No sets logged", systemImage: "dumbbell")
            }
        }
        .padding(.top, 8)
        .background(Color(.secondarySystemBackground))
        .navigationTitle(planned.first?.slot ?? "Workout")
        .navigationSubtitle(day.formatted(.dateTime.weekday(.wide).month().day()))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }

    private func stats(_ record: SessionRecord, summary: [Measurement]) -> some View {
        func value(_ metric: String) -> Double? { summary.first { $0.metric == metric }?.value }
        let completion = value("completion_rate")
        let planned = completion.flatMap { $0 > 0 ? Int((Double(record.setCount) / $0).rounded()) : nil }
        let items: [(String, String)] = [
            ("Sets", planned.map { "\(record.setCount)/\($0)" } ?? "\(record.setCount)"),
            ("Time", value("duration_s").map { Duration.seconds($0).formatted(.time(pattern: .minuteSecond)) } ?? "–"),
            ("Volume", record.volume.formatted(.number.precision(.fractionLength(0))) + " lb"),
            ("Done", completion.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "–"),
        ]
        return HStack(spacing: 8) {
            ForEach(items, id: \.0) { title, text in
                VStack(spacing: 2) {
                    Text(text).font(.system(size: 22, weight: .bold).monospacedDigit()).fontWidth(.condensed)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 64)
                .background(.background, in: .rect(cornerRadius: 16))
            }
        }
        .padding(.horizontal, 16)
    }

    private func tabs(_ record: SessionRecord) -> some View {
        HStack(spacing: 6) {
            ForEach(record.blocks.indices, id: \.self) { index in
                Button { withAnimation(.snappy) { page = index } } label: {
                    Text(SessionPlan.letter(index))
                        .font(.system(size: 18, weight: .bold)).fontWidth(.condensed)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(index == page ? Color.primary : Color(.systemBackground), in: .rect(cornerRadius: 12))
                        .foregroundStyle(index == page ? Color(.systemBackground) : .primary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
    }

    private func blockPage(_ index: Int, _ block: SessionRecord.Block, _ bySlug: [String: Template]) -> some View {
        func name(_ slug: String) -> String { bySlug[slug]?.name ?? slug }
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                BlockBadge(letter: SessionPlan.letter(index), size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    if block.isGroup {
                        Text("\(block.exercises.count == 2 ? "SUPERSET" : "CIRCUIT") · \(block.rounds.count) ROUND\(block.rounds.count == 1 ? "" : "S")")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    Text(block.exercises.map(name).joined(separator: " + ")).font(.title3.bold())
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                if block.isGroup {
                    GridRow {
                        Text("Round")
                        ForEach(block.exercises.indices, id: \.self) { Text("\(SessionPlan.letter(index))\($0 + 1)") }
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(block.rounds.enumerated()), id: \.offset) { round, sets in
                        GridRow {
                            Text("\(round + 1)").fontWeight(.bold)
                            ForEach(block.exercises, id: \.self) { exercise in
                                Text(sets.first { $0.exercise == exercise }.map(Self.short) ?? "–")
                            }
                        }
                    }
                } else {
                    GridRow {
                        Text("Set"); Text("Did"); Text("RPE")
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(block.sets.enumerated()), id: \.offset) { number, set in
                        GridRow {
                            Text("\(number + 1)").fontWeight(.bold)
                            Text(Self.short(set))
                            Text(set.value("rpe").map(WorkoutDetailView.number) ?? "–").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .font(.body.monospacedDigit())
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: .rect(cornerRadius: 18))
            ForEach(block.exercises, id: \.self) { exercise in
                facts(name(exercise), block.sets(of: exercise), main: bySlug[exercise]?.values("tags").contains("goal_lift") ?? false,
                      many: block.isGroup)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func facts(_ name: String, _ sets: [LoggedSet], main: Bool, many: Bool) -> some View {
        let tier = AgeTier.of(age: profiles.first?.age ?? 30)
        let max = SessionRecord.estimated1RM(sets)
        let next = SessionRecord.nextLoad(sets, main: main, tier: tier)
        if max != nil || next != nil {
            VStack(alignment: .leading, spacing: 6) {
                if many { Text(name).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                if let max {
                    LabeledContent("Estimated max", value: "\(WorkoutDetailView.number(max.rounded())) lb")
                }
                if let next {
                    LabeledContent("Next time", value: next.to > next.from
                                   ? "+\(WorkoutDetailView.number(next.to - next.from)) lb → \(WorkoutDetailView.number(next.to))"
                                   : "hold \(WorkoutDetailView.number(next.from)) lb")
                }
            }
            .font(.subheadline)
            .padding(14)
            .background(.background, in: .rect(cornerRadius: 18))
        }
    }

    /// "5 × 200", "45 s", "30 m × 50/hand".
    nonisolated static func short(_ set: LoggedSet) -> String {
        let n = WorkoutDetailView.number
        let amount = set.value("reps").map(n) ?? set.value("duration_s").map { "\(n($0)) s" } ?? set.value("distance_m").map { "\(n($0)) m" } ?? ""
        if let load = set.value("load_lb") { return "\(amount) × \(n(load))" }
        if let load = set.value("load_lb_hand") { return "\(amount) × \(n(load))/hand" }
        return amount
    }
}
