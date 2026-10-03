import SwiftUI
import SwiftData

/// Full-screen session (FIT-20, redesigned in FIT-21 from prototype artboards 3a/3b): dark, a running clock,
/// progress per block, one set per page swiped sideways, and a rest screen after each set or superset round
/// with a countdown ring, RPE for the set just done and what's next. Saves through the same path as the log form.
struct WorkoutModeView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var templates: [Template]
    @State var draft: WorkoutDraft
    @State private var startedAt = Date.now
    @State private var page: Int? = 0
    @State private var rest: Rest?
    @State private var restsFinished = 0
    @State private var quitting = false

    struct Rest: Equatable {
        var ends: Date
        var total: TimeInterval
        /// The set just done, rated on the rest screen.
        var after: Int
    }

    static let background = Color(red: 0.055, green: 0.059, blue: 0.071)

    var body: some View {
        let names = Dictionary(templates.map { ($0.slug, $0.name) }, uniquingKeysWith: { first, _ in first })
        VStack(spacing: 0) {
            header
            progress.padding(.horizontal, 16).padding(.top, 8)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(draft.rows.indices, id: \.self) { index in
                        setPage(index, names: names).containerRelativeFrame(.horizontal)
                    }
                    ratingsPage.id(draft.rows.count).containerRelativeFrame(.horizontal)
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
            .scrollPosition(id: $page)
        }
        .overlay {
            if let rest { restScreen(rest, names: names).transition(.opacity) }
        }
        .background(Self.background)
        .preferredColorScheme(.dark)
        // Full-screen covers don't inherit the app's tint.
        .tint(Color.primary)
        .sensoryFeedback(.success, trigger: restsFinished)
        .task(id: rest?.ends) {
            guard let ends = rest?.ends else { return }
            try? await Task.sleep(for: .seconds(max(0, ends.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            withAnimation { rest = nil }
            restsFinished += 1
        }
        // A phone that locks mid-set loses the clock; keep it awake while training.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .confirmationDialog("End workout?", isPresented: $quitting, titleVisibility: .visible) {
            if draft.rows.contains(where: \.done) {
                Button("Save and finish") { finish() }
            }
            Button("Discard", role: .destructive) { dismiss() }
        }
    }

    private var header: some View {
        HStack {
            Button("End", systemImage: "xmark") { quitting = true }
                .labelStyle(.iconOnly)
                .font(.title3.weight(.semibold))
                .frame(width: 44, height: 44)
            Spacer()
            VStack(spacing: 0) {
                Text(draft.session.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(startedAt, style: .timer)
                    .font(.system(size: 28, weight: .bold).monospacedDigit()).fontWidth(.condensed)
            }
            Spacer()
            Text("\(draft.rows.filter(\.done).count)/\(draft.rows.count)")
                .font(.headline.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
        }
        .padding(.horizontal, 8)
    }

    /// One bar per block, filled by its done sets; tapping one jumps to its first set left.
    private var progress: some View {
        let blocks = Array(Set(draft.rows.map(\.block))).sorted()
        let current = page.flatMap { draft.rows.indices.contains($0) ? draft.rows[$0].block : nil }
        return HStack(spacing: 4) {
            ForEach(blocks, id: \.self) { block in
                let rows = draft.rows.indices.filter { draft.rows[$0].block == block }
                let done = Double(rows.filter { draft.rows[$0].done }.count) / Double(rows.count)
                VStack(spacing: 4) {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.15))
                            Capsule().fill(Color.primary).frame(width: proxy.size.width * done)
                        }
                    }
                    .frame(height: 6)
                    Text(SessionPlan.letter(block)).font(.caption2.weight(.bold))
                        .foregroundStyle(block == current ? Color.primary : .secondary)
                }
                .frame(maxWidth: .infinity)
                .contentShape(.rect)
                .onTapGesture {
                    withAnimation(.snappy) { page = rows.first { !draft.rows[$0].done } ?? rows.first }
                }
            }
        }
    }

    private func setPage(_ index: Int, names: [String: String]) -> some View {
        let row = $draft.rows[index]
        let current = draft.rows[index]
        let block = draft.rows.filter { $0.block == current.block }
        let movements = block.map(\.exercise).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let rounds = (block.map(\.round).max() ?? 0) + 1
        let sets = block.filter { $0.exercise == current.exercise }.count
        let letter = SessionPlan.letter(current.block)
        return VStack(spacing: 16) {
            VStack(spacing: 8) {
                if movements.count > 1 {
                    HStack(spacing: 6) {
                        ForEach(Array(movements.enumerated()), id: \.offset) { m, exercise in
                            Text("\(letter)\(m + 1) \(names[exercise] ?? exercise)")
                                .font(.caption.weight(.semibold)).lineLimit(1)
                                .padding(.horizontal, 10).frame(height: 28)
                                .background(exercise == current.exercise ? Color.primary : .white.opacity(0.1), in: .capsule)
                                .foregroundStyle(exercise == current.exercise ? Self.background : .primary)
                        }
                    }
                }
                Text(names[current.exercise] ?? current.exercise)
                    .font(.system(size: 40, weight: .heavy)).fontWidth(.condensed)
                    .multilineTextAlignment(.center).minimumScaleFactor(0.6).lineLimit(2)
                Text(movements.count > 1 ? "Round \(current.round + 1) of \(rounds)" : "Set \(current.round + 1) of \(sets)")
                    .font(.headline).foregroundStyle(.secondary)
            }
            .padding(.top, 16)
            Spacer(minLength: 0)
            BigStepper(value: row.value, step: current.metric == "reps" ? 1 : 5, unit: SetRow.units[current.metric] ?? "")
            if let loadMetric = current.loadMetric {
                BigStepper(value: row.load, step: 5, unit: SetRow.units[loadMetric] ?? "")
            }
            Spacer(minLength: 0)
            Button {
                if current.done {
                    row.wrappedValue.done = false
                } else {
                    done(index)
                }
            } label: {
                Label(current.done ? "Done · tap to undo" : "Done", systemImage: "checkmark")
                    .font(.title3.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: 72)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 22))
            .tint(current.done ? Color.secondary : Color.primary)
            .foregroundStyle(Self.background)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    /// Ticks the set and moves on: straight to a superset partner, otherwise via the rest screen.
    private func done(_ index: Int) {
        let next = draft.finish(index)
        let seconds = draft.rest(after: index)
        withAnimation(.snappy) {
            page = next ?? draft.rows.count
            if seconds > 0, next != nil { rest = Rest(ends: .now + seconds, total: seconds, after: index) }
        }
    }

    private func restScreen(_ rest: Rest, names: [String: String]) -> some View {
        let next = page.flatMap { draft.rows.indices.contains($0) ? draft.rows[$0] : nil }
        return VStack(spacing: 20) {
            Text("REST").font(.caption.weight(.bold)).tracking(2).foregroundStyle(.secondary).padding(.top, 60)
            TimelineView(.periodic(from: .now, by: 0.2)) { context in
                let left = max(0, rest.ends.timeIntervalSince(context.date))
                ZStack {
                    Circle().stroke(.white.opacity(0.12), lineWidth: 14)
                    Circle().trim(from: 0, to: left / max(rest.total, left))
                        .stroke(Color.primary, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text(Duration.seconds(left.rounded(.up)).formatted(.time(pattern: .minuteSecond)))
                        .font(.system(size: 64, weight: .bold).monospacedDigit()).fontWidth(.condensed)
                }
                .frame(width: 230, height: 230)
            }
            HStack(spacing: 10) {
                Button("+30 s") { self.rest?.ends += 30; self.rest?.total += 30 }
                Button("Skip") { withAnimation { self.rest = nil } }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            VStack(alignment: .leading, spacing: 8) {
                Text("How hard was that \(names[draft.rows[rest.after].exercise] ?? "set")?")
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 4) {
                    ForEach([6, 7, 7.5, 8, 8.5, 9, 10], id: \.self) { rpe in
                        let on = draft.rows[rest.after].rpe == rpe
                        Button { draft.rows[rest.after].rpe = on ? nil : rpe } label: {
                            Text(WorkoutDetailView.number(rpe)).font(.headline.monospacedDigit())
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(on ? Color.primary : .white.opacity(0.1), in: .rect(cornerRadius: 10))
                                .foregroundStyle(on ? Self.background : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text("RPE: 10 is nothing left, 8 is two more reps in the tank.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let next {
                HStack(spacing: 12) {
                    BlockBadge(letter: SessionPlan.letter(next.block), size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("NEXT").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                        Text(names[next.exercise] ?? next.exercise).font(.headline)
                        Text(next.measurements.map(\.display).joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(14)
                .background(.white.opacity(0.08), in: .rect(cornerRadius: 18))
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Self.background)
    }

    private var ratingsPage: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            Text("How did it go?").font(.system(size: 40, weight: .heavy)).fontWidth(.condensed)
            Text("\(draft.rows.filter(\.done).count) of \(draft.rows.count) sets · "
                 + draft.completion.formatted(.percent.precision(.fractionLength(0))))
                .font(.headline).foregroundStyle(.secondary)
            rating("Effort", $draft.effort, of: 10)
            rating("Energy", $draft.energy, of: 5)
            rating("Form", $draft.form, of: 5)
            Spacer(minLength: 0)
            Button(action: finish) {
                Text("Finish workout").font(.title3.weight(.bold)).frame(maxWidth: .infinity, minHeight: 72)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 22))
            .foregroundStyle(Self.background)
            .disabled(!draft.rows.contains(where: \.done))
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private func rating(_ title: String, _ value: Binding<Double>, of max: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            HStack(spacing: 4) {
                ForEach(1...max, id: \.self) { score in
                    Button { value.wrappedValue = Double(score) } label: {
                        Text("\(score)").font(.headline.monospacedDigit())
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(Int(value.wrappedValue) == score ? AnyShapeStyle(.tint) : AnyShapeStyle(.white.opacity(0.1)),
                                        in: .rect(cornerRadius: 10))
                            .foregroundStyle(Int(value.wrappedValue) == score ? Self.background : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func finish() {
        draft.duration = Date.now.timeIntervalSince(startedAt)
        draft.save(at: startedAt, templates: templates, in: context)
        dismiss()
    }
}

/// A number you change with your thumb: big value between big − and + buttons.
private struct BigStepper: View {
    @Binding var value: Double?
    let step: Double
    let unit: String
    var start: Double = 0
    var range: ClosedRange<Double> = 0...10_000

    var body: some View {
        HStack(spacing: 12) {
            button("minus") { -step }
            VStack(spacing: 0) {
                Text(value.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "–")
                    .font(.system(size: 52, weight: .bold).monospacedDigit()).fontWidth(.condensed)
                    .contentTransition(.numericText())
                Text(unit).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            button("plus") { step }
        }
    }

    private func button(_ symbol: String, delta: @escaping () -> Double) -> some View {
        Button {
            withAnimation(.snappy) {
                // An empty value (RPE before it's rated) starts at `start` on first tap.
                value = value.map { min(range.upperBound, max(range.lowerBound, $0 + delta())) } ?? start
            }
        } label: {
            Image(systemName: symbol).font(.title.weight(.bold)).frame(width: 64, height: 64)
                .background(.white.opacity(0.12), in: .circle)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: value)
    }
}
