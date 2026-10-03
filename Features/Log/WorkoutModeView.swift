import SwiftUI
import SwiftData

/// The workout (FIT-28, prototype boards 3–4): a clock, one segment per exercise, and one card per exercise
/// swiped sideways. Tap ✓ to log a set as planned, tap its numbers to change them in place. The rest dock runs
/// at the bottom, a finished exercise moves on by itself, and the last card is the log: Save writes it.
struct WorkoutModeView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \LogEntry.timestamp) private var entries: [LogEntry]
    @Query private var templates: [Template]
    @Query private var profiles: [Profile]
    @State var draft: WorkoutDraft
    var onSaved: () -> Void = {}
    @State private var startedAt = Date.now
    @State private var page: Int? = 0
    @State private var open: [Int]?
    @State private var rest: Rest?
    @State private var restsFinished = 0
    @State private var quitting = false
    @State private var voice = VoiceCapture()
    @State private var working: String?
    @State private var talked = false
    @State private var toast: Toast?
    @State private var message: String?

    struct Rest: Equatable {
        var ends: Date
        var total: TimeInterval
    }

    var body: some View {
        let blocks = draft.blocks
        let names = Dictionary(templates.map { ($0.slug, $0.name) }, uniquingKeysWith: { first, _ in first })
        VStack(spacing: 0) {
            topBar
            segments(blocks).padding(.horizontal, 22).padding(.top, 8)
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { position, block in
                        exerciseCard(block, position: position, of: blocks.count, names: names)
                            .containerRelativeFrame(.horizontal).id(position)
                    }
                    finishCard(names: names).containerRelativeFrame(.horizontal).id(blocks.count)
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 22, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
            .scrollIndicators(.hidden)
            .scrollPosition(id: $page)
            .padding(.top, 16)
            dock.padding(.horizontal, 22).frame(height: 68).padding(.vertical, 10)
        }
        .background(Color(.systemBackground))
        .overlay {
            if voice.listening || working != nil {
                ListeningVeil(voice: voice, working: working,
                              prompt: page == draft.blocks.count ? "Add a note" : "Say how the sets went")
            }
        }
        .overlay(alignment: .bottom) { ToastView(toast: $toast).padding(.bottom, 100) }
        .animation(.snappy, value: voice.listening || working != nil)
        .animation(.snappy, value: toast)
        .alert("Couldn’t do that", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: { Text(message ?? "") }
        .onChange(of: voice.problem) { _, problem in if let problem { message = problem } }
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
        .confirmationDialog("Leave this workout?", isPresented: $quitting, titleVisibility: .visible) {
            Button("Discard sets", role: .destructive) { dismiss() }
        } message: {
            Text("Nothing is saved until you press Save on the last card.")
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                if draft.rows.contains(where: \.done) { quitting = true } else { dismiss() }
            } label: {
                Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close")
            Spacer()
            Text(startedAt, style: .timer)
                .font(.system(.body, design: .rounded).weight(.semibold)).monospacedDigit()
                .accessibilityLabel("Time")
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
    }

    /// One bar per exercise filled by its done sets, then one for the finish card. Tap one to jump there.
    private func segments(_ blocks: [Int]) -> some View {
        HStack(spacing: 4) {
            ForEach(0...blocks.count, id: \.self) { position in
                let lines = position < blocks.count ? draft.lines(block: blocks[position]) : []
                let done = lines.isEmpty ? 0 : Double(lines.filter { $0.allSatisfy { draft.rows[$0].done } }.count) / Double(lines.count)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(.separator))
                        Capsule().fill(.primary).frame(width: proxy.size.width * done)
                    }
                }
                .frame(height: 4)
                .opacity(page == position ? 1 : 0.55)
                .padding(.vertical, 5)
                .contentShape(.rect)
                .onTapGesture { withAnimation(.snappy) { page = position } }
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: Exercise card

    private func exerciseCard(_ block: Int, position: Int, of count: Int, names: [String: String]) -> some View {
        let lines = draft.lines(block: block)
        let exercises = lines.first?.map { draft.rows[$0].exercise } ?? []
        let next = lines.firstIndex { !$0.allSatisfy { draft.rows[$0].done } }
        return VStack(alignment: .leading, spacing: 0) {
            Text("\(position + 1) OF \(count)\(exercises.count > 1 ? " · SUPERSET" : "")")
                .font(.footnote.weight(.semibold)).tracking(0.4).foregroundStyle(.tertiary)
            Text(exercises.map { names[$0] ?? $0 }.joined(separator: " + "))
                .font(.system(size: 30, weight: .bold)).tracking(-0.4).padding(.top, 4)
                .lineLimit(2).minimumScaleFactor(0.7)
            if let cue = exercises.count == 1 ? cue(exercises[0]) : "One of each, then rest." {
                Text(cue).font(.subheadline).foregroundStyle(.secondary).padding(.top, 6)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { number, line in
                        setLine(line, number: number + 1, isNext: number == next)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .padding(.top, 18)
            HStack {
                if exercises.count == 1, let last = lastTime(exercises[0]) {
                    Text(last).foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    withAnimation(.snappy) { page = position + 1 }
                } label: {
                    Text("\(position + 1 < count ? names[draft.lines(block: draft.blocks[position + 1]).first.map { draft.rows[$0[0]].exercise } ?? ""] ?? "Next" : "Finish") ›")
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .padding(.top, 8)
        }
        .padding(EdgeInsets(top: 24, leading: 22, bottom: 20, trailing: 22))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 30))
    }

    private func setLine(_ line: [Int], number: Int, isNext: Bool) -> some View {
        let rows = line.map { draft.rows[$0] }
        let first = rows[0]
        let done = rows.allSatisfy(\.done)
        let bright = done || isNext
        let isOpen = open == line
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("\(number)").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary).frame(width: 16)
                Button {
                    withAnimation(.snappy) { open = isOpen ? nil : line }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(rows.map { Coach.number($0.value ?? 0) }.joined(separator: "+"))
                            .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                            .overlay(alignment: .bottom) {
                                if rows.contains(where: \.heard) {
                                    Line().stroke(style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])).frame(height: 1.5)
                                        .foregroundStyle(.tertiary).offset(y: 2)
                                }
                            }
                        Text(first.loadMetric == nil ? SetRow.units[first.metric] ?? "" : first.metric == "reps" ? "" : SetRow.units[first.metric] ?? "")
                            .font(.subheadline).foregroundStyle(bright ? .secondary : .tertiary)
                        if first.loadMetric != nil {
                            Text("×").font(.subheadline).foregroundStyle(bright ? .secondary : .tertiary)
                            Text(Coach.number(first.load ?? 0))
                                .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                            Text(SetRow.units[first.loadMetric!] ?? "").font(.subheadline).foregroundStyle(bright ? .secondary : .tertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(bright ? .primary : .tertiary)
                    .contentTransition(.numericText())
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Change")
                Button { toggle(line) } label: {
                    ZStack {
                        if done {
                            Circle().fill(.primary)
                            Image(systemName: "checkmark").font(.body.weight(.bold)).foregroundStyle(Color(.systemBackground))
                        } else {
                            Circle().strokeBorder(isNext ? Color.primary : Color(.tertiaryLabel), lineWidth: 2)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Set \(number) done")
                .accessibilityAddTraits(done ? .isSelected : [])
                .sensoryFeedback(.impact(weight: .light), trigger: done)
            }
            .frame(minHeight: 70)
            if isOpen {
                HStack(spacing: 10) {
                    stepper(first.metric == "reps" ? "reps" : SetRow.units[first.metric] ?? "", line: line, load: false)
                    if first.loadMetric != nil { stepper("lb", line: line, load: true) }
                }
                .padding(.leading, 28).padding(.bottom, 14)
                .transition(.opacity)
            }
        }
        .overlay(alignment: .top) { Divider() }
    }

    private func stepper(_ unit: String, line: [Int], load: Bool) -> some View {
        HStack {
            Button { withAnimation(.snappy) { draft.adjust(line, load: load, by: -1) } } label: {
                Image(systemName: "minus").frame(width: 36, height: 36)
            }
            .accessibilityLabel(load ? "5 lb less" : "Less")
            Spacer()
            Text(unit).font(.footnote).foregroundStyle(.secondary)
            Spacer()
            Button { withAnimation(.snappy) { draft.adjust(line, load: load, by: 1) } } label: {
                Image(systemName: "plus").frame(width: 36, height: 36)
            }
            .accessibilityLabel(load ? "5 lb more" : "More")
        }
        .font(.title3)
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .frame(height: 44)
        .background(Color(.systemBackground), in: .capsule)
    }

    private func toggle(_ line: [Int]) {
        if line.allSatisfy({ draft.rows[$0].done }) {
            draft.untick(line)
            return
        }
        let result = withAnimation(.snappy) { draft.tick(line) }
        open = nil
        withAnimation(.snappy) {
            rest = result.rest > 0 ? Rest(ends: .now + result.rest, total: result.rest) : nil
        }
        if result.blockDone, let block = line.first.map({ draft.rows[$0].block }), let position = draft.blocks.firstIndex(of: block) {
            Task {
                try? await Task.sleep(for: .milliseconds(650))
                withAnimation(.snappy) { page = position + 1 }
            }
        }
    }

    /// The shortest cue's first sentence: one thing to think about, not the whole card.
    private func cue(_ exercise: String) -> String? {
        let cues = templates.first { $0.slug == exercise }?.values("cues") ?? []
        return cues.map { String($0.prefix { $0 != "." }) + "." }.min { $0.count < $1.count }
    }

    /// "Last time 5 × 155": the top set of the last session before today.
    private func lastTime(_ exercise: String) -> String? {
        let today = Calendar.current.startOfDay(for: startedAt)
        let sets = Planner.loggedSets(entries.filter { $0.timestamp < today }, templates: templates).filter { $0.exercise == exercise }
        guard let day = sets.last.map({ Calendar.current.startOfDay(for: $0.date) }) else { return nil }
        let top = sets.filter { Calendar.current.startOfDay(for: $0.date) == day }.max { ($0.value("load_lb") ?? 0) < ($1.value("load_lb") ?? 0) }
        guard let top, let reps = top.value("reps") else { return nil }
        return "Last time \(Coach.number(reps))" + (top.value("load_lb").map { " × \(Coach.number($0))" } ?? "")
    }

    // MARK: Dock

    private var dock: some View {
        HStack(spacing: 12) {
            if let rest {
                restDock(rest).transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                Text(talked || !LanguageModel.isAvailable ? "" : "Tap ✓, or hold and say it")
                    .font(.subheadline).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if LanguageModel.isAvailable { MicButton(voice: voice, onHeard: heard) }
        }
        .animation(.snappy, value: rest)
    }

    /// FIT-31: on an exercise card, how its sets went ("only got four on the last one") ticks them, with the
    /// heard values dashed and Undo; on the finish card, it's the note. Nothing is stored until Save.
    private func heard(_ said: String) {
        talked = true
        let blocks = draft.blocks
        guard let position = page, blocks.indices.contains(position) else {
            draft.note = said
            withAnimation { toast = Toast(text: "Note added") }
            return
        }
        let block = blocks[position]
        let names = Dictionary(templates.map { ($0.slug, $0.name) }, uniquingKeysWith: { first, _ in first })
        let exercise = draft.lines(block: block).first.map { names[draft.rows[$0[0]].exercise] ?? draft.rows[$0[0]].exercise } ?? ""
        working = said
        Task {
            defer { working = nil }
            do {
                let differences = try await TodayRequestParser.parseSets(said, exercise: exercise)
                let before = draft
                let changed = SpokenLog.apply(differences, to: &draft, names: names, block: block)
                let count = draft.lines(block: block).count
                let text = if changed.count == 1, let index = changed.first, let value = draft.rows[index].value {
                    "Set \(draft.rows[..<index].filter { $0.exercise == draft.rows[index].exercise }.count + 1) · \(Coach.number(value)) \(draft.rows[index].metric == "reps" ? "reps" : SetRow.units[draft.rows[index].metric] ?? "")"
                } else {
                    "\(count) \(count == 1 ? "set" : "sets") done"
                }
                withAnimation {
                    rest = nil
                    toast = Toast(text: text) { draft = before }
                }
                try? await Task.sleep(for: .milliseconds(650))
                withAnimation(.snappy) { page = position + 1 }
            } catch {
                message = "Couldn’t understand that. Tap ✓ instead, or try again."
            }
        }
    }

    private func restDock(_ rest: Rest) -> some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let left = max(0, rest.ends.timeIntervalSince(context.date))
            HStack(spacing: 10) {
                ZStack {
                    Circle().stroke(Color(.separator), lineWidth: 3.5)
                    Circle().trim(from: 0, to: left / max(rest.total, 1))
                        .stroke(.primary, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 30, height: 30)
                .padding(.trailing, 2)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Rest").font(.caption).foregroundStyle(.secondary)
                    Text(Duration.seconds(left.rounded(.up)).formatted(.time(pattern: .minuteSecond)))
                        .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                }
                Spacer(minLength: 0)
                Button("+30") { self.rest?.ends += 30; self.rest?.total = max(rest.total, left + 30) }
                    .buttonStyle(DockButton())
                Button("Skip") { withAnimation { self.rest = nil } }
                    .buttonStyle(DockButton())
            }
            .padding(.leading, 14).padding(.trailing, 8)
            .frame(height: 64)
            .background(Color(.secondarySystemBackground), in: .capsule)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Rest")
        }
    }

    private struct DockButton: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label.font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12).frame(height: 40)
                .background(Color(.systemBackground), in: .capsule)
                .opacity(configuration.isPressed ? 0.6 : 1)
        }
    }

    // MARK: Finish card

    private func finishCard(names: [String: String]) -> some View {
        let done = draft.rows.filter(\.done).count
        let total = draft.rows.count
        let main = Set(Planner.catalog(templates).filter(\.isGoalLift).map(\.slug))
        let lifts = draft.lifts(main: main, names: names, tier: AgeTier.of(age: profiles.first?.age ?? 30))
        return VStack(alignment: .leading, spacing: 0) {
            Text("FINISH").font(.footnote.weight(.semibold)).tracking(0.4).foregroundStyle(.tertiary)
            Text(done == total ? "All \(total) sets" : "\(done) of \(total) sets")
                .font(.system(size: 30, weight: .bold)).tracking(-0.4).padding(.top, 4)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                HStack(alignment: .top, spacing: 8) {
                    stat("\(max(1, Int((context.date.timeIntervalSince(startedAt) / 60).rounded())))", "min")
                    stat("\(done)", done == 1 ? "set" : "sets")
                    stat(draft.volume.formatted(.number.precision(.fractionLength(0))), "lb")
                }
            }
            .padding(.top, 22)
            Text(Coach.done(lifts, missedSets: total - done)).padding(.top, 20).fixedSize(horizontal: false, vertical: true)
            Text("How did it feel?").font(.subheadline).foregroundStyle(.secondary).padding(.top, 24)
            HStack(spacing: 6) {
                ForEach(Feel.allCases) { feel in
                    let on = draft.feel == feel
                    Button { draft.feel = on ? nil : feel } label: {
                        Text(feel.label).font(.subheadline.weight(on ? .semibold : .regular))
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .foregroundStyle(on ? Color(.systemBackground) : .primary)
                            .background(on ? Color.primary : .clear, in: .capsule)
                            .overlay { if !on { Capsule().strokeBorder(Color(.tertiaryLabel)) } }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.top, 10)
            if !draft.note.isEmpty {
                HStack(alignment: .top) {
                    Text("“\(draft.note)”")
                    Spacer()
                    Button("Remove note", systemImage: "xmark") { draft.note = "" }.labelStyle(.iconOnly).foregroundStyle(.tertiary)
                }
                .font(.subheadline).padding(.top, 16)
            }
            Spacer(minLength: 16)
            Button(action: save) {
                Text("Save workout").font(.headline).frame(maxWidth: .infinity, minHeight: 58)
                    .foregroundStyle(Color(.systemBackground))
                    .background(Color.primary, in: .capsule)
            }
            .buttonStyle(.plain)
            .disabled(done == 0)
            .opacity(done == 0 ? 0.4 : 1)
        }
        .padding(EdgeInsets(top: 24, leading: 22, bottom: 22, trailing: 22))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 30))
    }

    private func stat(_ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: 28, weight: .semibold, design: .rounded)).tracking(-0.4)
            Text(unit).font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func save() {
        draft.duration = Date.now.timeIntervalSince(startedAt)
        draft.save(at: startedAt, templates: templates, in: context)
        onSaved()
        dismiss()
    }
}

/// A horizontal line, for the dashed "heard" underline.
struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        Path { $0.move(to: CGPoint(x: rect.minX, y: rect.midY)); $0.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)) }
    }
}
