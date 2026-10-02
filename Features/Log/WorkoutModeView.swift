import SwiftUI
import SwiftData

/// Full-screen session (FIT-20): a running clock, one working set per page swiped sideways, a rest countdown
/// after each set, and the ratings page at the end. Saves through the same path as the log form.
struct WorkoutModeView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var templates: [Template]
    @State var draft: WorkoutDraft
    @State private var startedAt = Date.now
    @State private var page: Int? = 0
    @State private var restEnds: Date?
    @State private var restsFinished = 0
    @State private var quitting = false

    var body: some View {
        let names = Dictionary(templates.map { ($0.slug, $0.name) }, uniquingKeysWith: { first, _ in first })
        VStack(spacing: 0) {
            header
            progress.padding(.horizontal, 16).padding(.top, 10)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(draft.rows.indices, id: \.self) { index in
                        setPage(index, name: names[draft.rows[index].exercise] ?? draft.rows[index].exercise)
                            .containerRelativeFrame(.horizontal)
                    }
                    ratingsPage.id(draft.rows.count).containerRelativeFrame(.horizontal)
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
            .scrollPosition(id: $page)
            rest
        }
        .background(Color(.systemBackground))
        // Full-screen covers don't inherit the app's tint.
        .tint(RootView.accent)
        .sensoryFeedback(.success, trigger: restsFinished)
        .task(id: restEnds) {
            guard let restEnds else { return }
            try? await Task.sleep(for: .seconds(max(0, restEnds.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self.restEnds = nil
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
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 8)
    }

    /// One segment per set, filled when done; tapping one jumps to it.
    private var progress: some View {
        HStack(spacing: 3) {
            ForEach(draft.rows.indices, id: \.self) { index in
                Capsule()
                    .fill(draft.rows[index].done ? AnyShapeStyle(.tint)
                          : index == page ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary))
                    .frame(height: 5)
                    .onTapGesture { withAnimation(.snappy) { page = index } }
            }
        }
    }

    private func setPage(_ index: Int, name: String) -> some View {
        let row = $draft.rows[index]
        let sets = draft.rows.indices.filter { draft.rows[$0].exercise == draft.rows[index].exercise }
        let unit = SetRow.units[row.wrappedValue.metric] ?? ""
        return VStack(spacing: 18) {
            Spacer(minLength: 0)
            VStack(spacing: 4) {
                Text(name).font(.largeTitle.bold()).multilineTextAlignment(.center).minimumScaleFactor(0.6).lineLimit(2)
                Text("Set \((sets.firstIndex(of: index) ?? 0) + 1) of \(sets.count)").font(.headline).foregroundStyle(.secondary)
            }
            BigStepper(value: row.value, step: row.wrappedValue.metric == "reps" ? 1 : 5, unit: unit)
            if let loadMetric = row.wrappedValue.loadMetric {
                BigStepper(value: row.load, step: 5, unit: SetRow.units[loadMetric] ?? "")
            }
            BigStepper(value: row.rpe, step: 0.5, unit: "RPE", start: 8, range: 1...10)
            Spacer(minLength: 0)
            Button {
                if row.wrappedValue.done {
                    row.wrappedValue.done = false
                } else {
                    let next = draft.finish(index)
                    restEnds = .now + WorkoutDraft.rest(after: draft.rows[index])
                    withAnimation(.snappy) { page = next ?? draft.rows.count }
                }
            } label: {
                Label(row.wrappedValue.done ? "Done · tap to undo" : "Done", systemImage: "checkmark")
                    .font(.title3.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: 64)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 18))
            .tint(row.wrappedValue.done ? Color.secondary : RootView.accent)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private var ratingsPage: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            Text("How did it go?").font(.largeTitle.bold())
            Text("\(draft.rows.filter(\.done).count) of \(draft.rows.count) sets · "
                 + draft.completion.formatted(.percent.precision(.fractionLength(0))))
                .font(.headline).foregroundStyle(.secondary)
            rating("Effort", $draft.effort, of: 10)
            rating("Energy", $draft.energy, of: 5)
            rating("Form", $draft.form, of: 5)
            Spacer(minLength: 0)
            Button(action: finish) {
                Text("Finish workout").font(.title3.weight(.bold)).frame(maxWidth: .infinity, minHeight: 64)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 18))
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
                            .background(Int(value.wrappedValue) == score ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                                        in: .rect(cornerRadius: 10))
                            .foregroundStyle(Int(value.wrappedValue) == score ? Color(.systemBackground) : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Rest countdown pinned to the bottom, with skip and +30 s.
    @ViewBuilder private var rest: some View {
        if let restEnds, restEnds > .now {
            HStack {
                Text("Rest").font(.headline)
                Text(timerInterval: Date.now...restEnds, countsDown: true)
                    .font(.system(size: 28, weight: .bold).monospacedDigit()).fontWidth(.condensed)
                Spacer()
                Button("+30 s") { self.restEnds = restEnds + 30 }
                    .buttonStyle(.bordered).frame(minHeight: 44)
                Button("Skip") { self.restEnds = nil }
                    .buttonStyle(.bordered).frame(minHeight: 44)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.thinMaterial)
            .transition(.move(edge: .bottom))
        }
    }

    private func finish() {
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
                .background(.quaternary, in: .circle)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: value)
    }
}
