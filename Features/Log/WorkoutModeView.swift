import SwiftUI
import SwiftData

/// The workout (FIT-301, design A, https://claude.ai/artifact/UV27EdoNaNCytWRRxd38Sa): one card at a time. The
/// warm-up first, a step each; then each set with its weight and reps big and − and + under them, and one Done that
/// logs it and starts its rest; the rest as a countdown with +30 s and Skip. A swipe to the left does what the card's
/// button does, and one to the right goes back a card (the author, 2026-10-30). The list button shows the whole session
/// and goes to any set. The last card is the log: Save writes it.
struct WorkoutModeView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(Account.self) private var account
    @Environment(Pro.self) private var pro
    @Query(sort: \LogEntry.timestamp) private var entries: [LogEntry]
    @Query private var templates: [Template]
    @Query private var profiles: [Profile]
    @Query private var planned: [PlannedActivity]
    @State var draft: WorkoutDraft
    var onSaved: () -> Void = {}
    @State private var startedAt = Date.now
    @State private var page = 0
    @State private var peeking = false
    /// The warm-up step on screen; past the last, the sets.
    @State private var warmStep = 0
    /// A card being dragged sideways, and whether the last move was back (the next card comes in from the left).
    @State private var dragX: CGFloat = 0
    @State private var backward = false
    @State private var rest: Rest?
    @State private var restsFinished = 0
    @State private var quitting = false
    @State private var voice = VoiceCapture()
    @State private var working: String?
    @State private var talked = false
    @State private var toast: Toast?
    @State private var message: String?
    /// FIT-53: groups I opted in to see each set as it happens.
    @State private var live: LiveShare?
    @State private var activity = WorkoutActivity()
    /// FIT-326: the lift being swapped, from the set card's name or the list.
    @State private var swapping: SwapTarget?

    struct SwapTarget: Identifiable {
        var block: Int
        var exercise: String
        var id: String { "\(block) \(exercise)" }
    }

    /// The running rest, on its card.
    struct Rest: Equatable {
        var ends: Date
        var total: TimeInterval
        var page: Int
    }

    private var names: [String: String] {
        Dictionary(templates.map { ($0.slug, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        let cards = draft.cards
        let names = names
        let warming = warmStep < draft.warmups.count
        let lockScreen = lockScreen(cards: cards, names: names, warming: warming)
        VStack(spacing: 0) {
            topBar
            segments.padding(.horizontal, 22).padding(.top, 8)
            // FIT-377: the coach's note on the session, as it starts.
            if page == 0 && warmStep == 0, let note = sessionNote {
                SessionNote(text: note, by: pro.coaches.first?.name ?? "Your coach").padding(.horizontal, 22).padding(.top, 12)
            }
            Group {
                if warming {
                    warmupCard(draft.warmups[warmStep], names: names)
                } else if page >= cards.count {
                    finishCard(names: names)
                } else {
                    switch cards[page] {
                    case .set(let line): setCard(line, index: page, cards: cards, names: names)
                    case .rest(let seconds): restCard(index: page, seconds: seconds, cards: cards, names: names)
                    }
                }
            }
            .id("\(warming ? warmStep : -1) \(page)")
            .motionTransition(.asymmetric(insertion: .move(edge: backward ? .leading : .trailing).combined(with: .opacity), removal: .opacity))
            .offset(x: dragX)
            .rotationEffect(.degrees(Double(dragX) / 40))
            .gesture(swipe(cards: cards))
            .padding(.horizontal, 22)
            .padding(.top, 16)
            footer(cards: cards, names: names, warming: warming)
                .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 8)
            if Pilot.inAppAI { micArea(onFinish: page == cards.count).frame(height: 104) }
        }
        .animation(.snappy, value: page)
        .animation(.snappy, value: warmStep)
        .screenBackground()
        .onChange(of: page) {
            live?.update(draft.live(at: page, names: names))
        }
        .onChange(of: draft.rows.filter(\.done).count) { live?.update(draft.live(at: page, names: names)) }
        .onChange(of: lockScreen) { activity.update(lockScreen) }
        .overlay {
            if voice.listening || working != nil {
                ListeningVeil(voice: voice, working: working,
                              prompt: page == draft.cards.count ? "Add a note" : "Say how that set went")
            }
        }
        .overlay(alignment: .bottom) { ToastView(toast: $toast).padding(.bottom, 116) }
        .animation(.snappy, value: voice.listening || working != nil)
        .animation(.snappy, value: toast)
        .alert("Couldn’t do that", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: { Text(message ?? "") }
        .onChange(of: voice.problem) { _, problem in if let problem { message = problem } }
        .sensoryFeedback(.success, trigger: restsFinished)
        .sensoryFeedback(.impact(weight: .light), trigger: draft.rows.filter(\.done).count)
        .task(id: rest?.ends) {
            guard let ends = rest?.ends, let on = rest?.page else { return }
            try? await Task.sleep(for: .seconds(max(0, ends.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            restsFinished += 1
            // Rest's over: on to the next set.
            withAnimation(.snappy) {
                rest = nil
                if page == on { page = on + 1 }
            }
        }
        // A phone that locks mid-set loses the clock; keep it awake while training.
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            activity.start(lockScreen)
            if Pilot.groups, account.user != nil, live == nil {
                live = LiveShare(workout: draft.session, startedAt: startedAt)
                live?.start()
                live?.update(draft.live(at: page, names: names))
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            activity.end()
            live?.end(saved: nil)
            live = nil
        }
        .confirmationDialog("Leave this workout?", isPresented: $quitting, titleVisibility: .visible) {
            Button("Discard sets", role: .destructive) { dismiss() }
        } message: {
            Text("Nothing is saved until you press Save on the last card.")
        }
        .sheet(isPresented: $peeking) { peek }
        .sheet(item: $swapping) { target in
            ExercisePicker(title: "Swap \(names[target.exercise] ?? target.exercise)", replacing: target.exercise,
                           excluding: Set(draft.rows.map(\.exercise))) { slug in swap(target, to: slug) }
        }
    }

    /// The whole session at a glance: every set, logged or not. Tap one to go to it.
    private var peek: some View {
        let cards = draft.cards
        let names = names
        let current = set(at: page, in: cards)
        return NavigationStack {
            List {
                ForEach(draft.blocks, id: \.self) { block in
                    Section(SessionPlan.letter(block) + " · " + Self.names(draft.rows.filter { $0.block == block }, names)) {
                        ForEach(draft.lines(block: block), id: \.self) { line in
                            let rows = line.map { draft.rows[$0] }
                            let done = rows.allSatisfy(\.done)
                            Button {
                                peeking = false
                                if let index = cards.firstIndex(of: .set(line)) {
                                    withAnimation(.snappy) { warmStep = draft.warmups.count; page = index }
                                }
                            } label: {
                                HStack {
                                    Image(systemName: done ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(done ? .primary : .tertiary)
                                    Text("Set \(rows[0].round + 1)")
                                    Spacer()
                                    Text(Self.dose(rows)).foregroundStyle(.secondary).monospacedDigit()
                                }
                                .fontWeight(line == current ? .semibold : .regular)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(line == current ? .isSelected : [])
                            .swipeActions {
                                if !done, rows.count == 1 {
                                    Button("Swap", systemImage: "arrow.triangle.2.circlepath") {
                                        peeking = false
                                        swapping = SwapTarget(block: rows[0].block, exercise: rows[0].exercise)
                                    }
                                    .tint(Plate.current.mark)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(draft.session)
            .navigationSubtitle("\(draft.rows.filter(\.done).count) of \(draft.rows.count) sets logged")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { peeking = false } } }
        }
        .presentationDetents([.medium, .large])
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
            Button { peeking = true } label: {
                Image(systemName: "list.bullet").font(.body.weight(.semibold)).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Whole workout")
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
    }

    /// One bar per exercise, filled by its logged sets; the one on screen is darker.
    private var segments: some View {
        let current = set(at: page, in: draft.cards).map { draft.rows[$0[0]].block }
        return HStack(spacing: 4) {
            ForEach(draft.blocks, id: \.self) { block in
                let rows = draft.rows.filter { $0.block == block }
                let done = Double(rows.filter(\.done).count) / Double(max(rows.count, 1))
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(.separator))
                        Capsule().fill(.primary).frame(width: proxy.size.width * done)
                    }
                }
                .frame(height: 4)
                .opacity(current == block ? 1 : 0.55)
            }
        }
        .padding(.vertical, 5)
        .animation(.snappy, value: draft.rows.filter(\.done).count)
        .accessibilityHidden(true)
    }

    // MARK: Lock Screen

    /// FIT-304: the Live Activity's one card: the step on screen; during a rest, the set after it and the rest's end.
    private func lockScreen(cards: [WorkoutDraft.Card], names: [String: String], warming: Bool) -> WorkoutActivityAttributes.ContentState {
        let progress = draft.rows.isEmpty ? 0 : Double(draft.rows.filter(\.done).count) / Double(draft.rows.count)
        if warming {
            let step = draft.warmups[warmStep]
            return .init(title: step.exercise.map { names[$0] ?? $0 } ?? "Row, bike or walk, easy",
                         detail: "Warm-up · \(step.dose)", step: "\(warmStep + 1)/\(draft.warmups.count)", load: nil, restEnds: nil, progress: 0,
                         lift: "Warm-up", set: step.dose)
        }
        let line: [Int]? = if page >= cards.count { nil } else if case .set(let line) = cards[page] { line } else { nextSet(after: page, in: cards) }
        guard let line else {
            return .init(title: draft.session, detail: "Done · save it in Barbrabell", step: "✓", load: nil, restEnds: nil, progress: progress)
        }
        let rows = line.map { draft.rows[$0] }
        let first = rows[0]
        let rounds = draft.lines(block: first.block).count
        let loads = rows.compactMap(\.load).reduce(into: [Double]()) { if !$0.contains($1) { $0.append($1) } }
        let load = first.loadMetric == nil || loads.isEmpty ? nil
            : loads.map(Coach.number).joined(separator: "/") + " " + (SetRow.units[first.loadMetric ?? "load_lb"] ?? "lb")
        let values = rows.map { Coach.number($0.value ?? 0) }.joined(separator: "+")
            + (first.metric == "reps" ? "" : " " + (SetRow.units[first.metric] ?? ""))
        let title = Self.names(rows, names)
        let weight = loads.isEmpty || first.loadMetric == nil ? (first.metric == "reps" ? "×" : "") : loads.map(Coach.number).joined(separator: "/") + "×"
        return .init(title: title, detail: "Set \(first.round + 1) of \(rounds) · " + (load.map { "\($0) × " } ?? "") + values,
                     step: "\(first.round + 1)/\(rounds)", load: load, restEnds: rest?.ends, progress: progress,
                     lift: WorkoutActivityAttributes.short(names[first.exercise] ?? title),
                     set: weight + values)
    }

    // MARK: Set card

    /// The set on a card, or the one a rest card follows.
    private func set(at index: Int, in cards: [WorkoutDraft.Card]) -> [Int]? {
        guard cards.indices.contains(index) else { return nil }
        if case .set(let line) = cards[index] { return line }
        return set(at: index - 1, in: cards)
    }

    /// The next set card after `index`.
    private func nextSet(after index: Int, in cards: [WorkoutDraft.Card]) -> [Int]? {
        cards[(index + 1)...].lazy.compactMap { if case .set(let line) = $0 { line } else { nil } }.first
    }

    private func setCard(_ line: [Int], index: Int, cards: [WorkoutDraft.Card], names: [String: String]) -> some View {
        let rows = line.map { draft.rows[$0] }
        let first = rows[0]
        let exercises = rows.map(\.exercise).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let rounds = draft.lines(block: first.block).count
        let done = rows.allSatisfy(\.done)
        let values = rows.map { Coach.number($0.value ?? 0) }.joined(separator: "+")
        let loads = rows.compactMap(\.load).reduce(into: [Double]()) { if !$0.contains($1) { $0.append($1) } }
        // FIT-326: a lift swapped in with no last time has its load to set: "–" until it's stepped.
        let load = first.loadMetric == nil ? nil : loads.isEmpty ? "–" : loads.map(Coach.number).joined(separator: "/")
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Set \(first.round + 1) of \(rounds)\(exercises.count > 1 ? " · superset" : "")")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Plate.current.mark)
                Spacer()
                if done {
                    Label("Logged", systemImage: "checkmark.circle.fill").font(.footnote.weight(.semibold)).foregroundStyle(Color.inkMuted)
                }
            }
            // FIT-326: the name swaps the lift for its sets still to do (a superset's names stay put).
            Button {
                if exercises.count == 1, !done { swapping = SwapTarget(block: first.block, exercise: exercises[0]) }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(exercises.map { names[$0] ?? $0 }.joined(separator: " + "))
                        .font(.display(30)).lineLimit(2).minimumScaleFactor(0.7).multilineTextAlignment(.leading)
                    if exercises.count == 1, !done {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.subheadline.weight(.semibold))
                            .foregroundStyle(Plate.current.mark)
                    }
                }
                .foregroundStyle(Color.ink)
            }
            .buttonStyle(.plain).padding(.top, 4)
            .disabled(exercises.count != 1 || done)
            .accessibilityHint(exercises.count == 1 && !done ? "Swap this exercise" : "")
            if let cue = cue(rows) {
                Text(cue).font(.subheadline).foregroundStyle(Color.inkMuted).padding(.top, 6).lineLimit(3)
            }
            Spacer(minLength: 12)
            // Weight and reps big, each with − and + under it: a change is a tap, right where it's read.
            HStack(alignment: .top, spacing: 12) {
                if let load {
                    stepper(load, unit: SetRow.units[first.loadMetric ?? "load_lb"] ?? "lb", less: "5 lb lighter", more: "5 lb heavier") {
                        draft.adjust(line, load: true, by: $0)
                    }
                }
                stepper(values, unit: unit(first, pair: exercises.count > 1, plain: true), less: "Fewer", more: "More") {
                    draft.adjust(line, load: false, by: $0)
                }
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 12)
            if first.round == 0, exercises.count == 1, let last = lastTime(exercises[0]) {
                Text(last).font(.subheadline).foregroundStyle(Color.inkMuted).frame(maxWidth: .infinity)
            }
        }
        .padding(EdgeInsets(top: 24, leading: 22, bottom: 22, trailing: 22))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipShape(.rect(cornerRadius: 24))
        .cardBackground()
        .accessibilityAction(named: "Unlog") { if done { unlog(line) } }
    }

    /// A big number with its unit, and − and + under it.
    private func stepper(_ value: String, unit: String, less: String, more: String, by step: @escaping (Double) -> Void) -> some View {
        VStack(spacing: 10) {
            Text(value).font(.display(value.count > 4 ? 52 : 76, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.5).contentTransition(.numericText())
            Text(unit).font(.subheadline).foregroundStyle(Color.inkMuted)
            HStack(spacing: 10) {
                round("minus", less) { step(-1) }
                round("plus", more) { step(1) }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
    }

    /// A warm-up step (FIT-301): what to do and how much, big. Done moves on; nothing is logged.
    private func warmupCard(_ step: WorkoutDraft.Warmup, names: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(step.ramp ? "Warm-up · ramp" : "Warm-up").font(.subheadline.weight(.semibold)).foregroundStyle(Color.inkMuted)
            Text(step.exercise.map { names[$0] ?? $0 } ?? "Row, bike or walk, easy")
                .font(.display(30)).padding(.top, 4).lineLimit(2).minimumScaleFactor(0.7)
            Spacer(minLength: 12)
            Text(step.dose).font(.display(76, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.5).frame(maxWidth: .infinity)
            Spacer(minLength: 12)
        }
        .padding(EdgeInsets(top: 24, leading: 22, bottom: 22, trailing: 22))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardBackground()
    }

    /// Under the card: what's next, then the one action. A set's Done logs it and starts its rest; a rest has its own
    /// buttons on the card, and the finish card its Save.
    @ViewBuilder private func footer(cards: [WorkoutDraft.Card], names: [String: String], warming: Bool) -> some View {
        let nextLine = nextText(cards: cards, names: names, warming: warming)
        VStack(alignment: .leading, spacing: 12) {
            if let nextLine { Text(nextLine).font(.subheadline).foregroundStyle(Color.inkMuted).lineLimit(1) }
            if warming {
                Button("Done") { forward(cards: cards) }.buttonStyle(.primary)
            } else if cards.indices.contains(page), case .set(let line) = cards[page] {
                let done = line.allSatisfy { draft.rows[$0].done }
                let restAfter: TimeInterval? = if cards.indices.contains(page + 1), case .rest(let seconds) = cards[page + 1] { seconds } else { nil }
                Button(done ? "Next" : restAfter.map { "Done · rest \(Duration.seconds($0).formatted(.time(pattern: .minuteSecond)))" } ?? "Done") {
                    forward(cards: cards)
                }
                .buttonStyle(.primary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The card's main action, from its button or a swipe to the left: a warm-up step is done, a set is logged and its
    /// rest starts, a rest is skipped. The finish card stays (Save is its own button).
    private func forward(cards: [WorkoutDraft.Card]) {
        backward = false
        if warmStep < draft.warmups.count { withAnimation(.snappy) { warmStep += 1 }; return }
        guard cards.indices.contains(page) else { return }
        _ = swiped(from: page, .next, cards: cards)
        withAnimation(.snappy) { page += 1 }
    }

    /// A swipe to the right: the card before, the last warm-up step before the first set. A rest still running keeps
    /// running, and nothing is unlogged.
    private func back() {
        backward = true
        withAnimation(.snappy) {
            if warmStep < draft.warmups.count { warmStep = max(0, warmStep - 1) }
            else if page > 0 { page -= 1 }
            else if !draft.warmups.isEmpty { warmStep = draft.warmups.count - 1 }
        }
    }

    /// The card follows a sideways drag; far enough (or flicked) and it goes forward or back, else it springs home.
    private func swipe(cards: [WorkoutDraft.Card]) -> some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                dragX = value.translation.width
            }
            .onEnded { value in
                let distance = value.predictedEndTranslation.width
                withAnimation(.snappy) { dragX = 0 }
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                if distance < -120 { forward(cards: cards) } else if distance > 120 { back() }
            }
    }

    /// "Next: Back Squat · 170 × 5", from the step on screen.
    private func nextText(cards: [WorkoutDraft.Card], names: [String: String], warming: Bool) -> String? {
        if warming, warmStep + 1 < draft.warmups.count {
            let next = draft.warmups[warmStep + 1]
            return "Next: \(next.exercise.map { names[$0] ?? $0 } ?? "Easy cardio") · \(next.dose)"
        }
        let line = warming ? cards.lazy.compactMap { if case .set(let line) = $0 { line } else { nil } }.first
            : cards.indices.contains(page) ? nextSet(after: page, in: cards) : nil
        guard let line else { return page < cards.count && !warming ? "Last one" : nil }
        let rows = line.map { draft.rows[$0] }
        return "Next: \(Self.names(rows, names)) · \(Self.dose(rows))"
    }

    /// FIT-377: the note on the session these sets were planned in.
    private var sessionNote: String? {
        let ids = Set(draft.rows.compactMap(\.plannedRef))
        return PlannedActivity.sessionNote(planned.filter { ids.contains($0.id) })
    }

    /// FIT-202: what the coach wrote on these sets' exercises (tempo, rest, AMRAP…), where the set is logged.
    private func cue(_ rows: [SetRow]) -> String? {
        let ids = Set(rows.compactMap(\.plannedRef))
        let notes = planned.filter { ids.contains($0.id) }.map(\.note)
            .filter { !$0.isEmpty && $0 != TrainingGenerator.warmupNote }
        let unique = notes.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return unique.isEmpty ? nil : unique.joined(separator: " · ")
    }

    /// Done on a set logs it as shown and starts its rest; Skip on a rest ends it.
    private func swiped(from index: Int, _ swipe: CardSwipe, cards: [WorkoutDraft.Card]) -> Int? {
        guard cards.indices.contains(index) else { return nil }
        let restAfter: TimeInterval? = if cards.indices.contains(index + 1), case .rest(let seconds) = cards[index + 1] { seconds } else { nil }
        switch (cards[index], swipe) {
        case (.set(let line), .next):
            if !line.allSatisfy({ draft.rows[$0].done }) {
                draft.tick(line)
                if let restAfter { rest = Rest(ends: .now + restAfter, total: restAfter, page: index + 1) }
            }
        case (.set, .up):
            return restAfter == nil ? nil : index + 2
        case (.set(let line), .down):
            unlog(line)
            if rest?.page == index + 1 { rest = nil } // no rest after a set that wasn't done
        case (.rest, .next), (.rest, .up):
            if rest?.page == index { rest = nil }
        default: break
        }
        return nil
    }

    private func unlog(_ line: [Int]) {
        let before = draft
        withAnimation(.snappy) { draft.untick(line) }
        withAnimation { toast = Toast(text: "Set \(draft.rows[line[0]].round + 1) unlogged") { draft = before } }
    }

    /// "reps × lb", "reps each × lb/hand", "seconds".
    private func unit(_ row: SetRow, pair: Bool = false, plain: Bool = false) -> String {
        let value = row.metric == "reps" ? (pair ? "reps each" : "reps") : row.metric == "duration_s" ? "seconds" : SetRow.units[row.metric] ?? ""
        guard !plain, let loadMetric = row.loadMetric else { return value }
        return "\(value) × \(SetRow.units[loadMetric] ?? "lb")"
    }

    private func round(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button { withAnimation(.snappy, action) } label: {
            Image(systemName: symbol).font(.title3.weight(.semibold)).frame(width: 52, height: 52)
                .background(Color.fill, in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// "Last time 155 × 5": the top set of the last session before today.
    private func lastTime(_ exercise: String) -> String? {
        let today = Calendar.current.startOfDay(for: startedAt)
        let sets = Planner.loggedSets(entries.filter { $0.timestamp < today }, templates: templates).filter { $0.exercise == exercise }
        guard let day = sets.last.map({ Calendar.current.startOfDay(for: $0.date) }) else { return nil }
        let top = sets.filter { Calendar.current.startOfDay(for: $0.date) == day }.max { ($0.value("load_lb") ?? 0) < ($1.value("load_lb") ?? 0) }
        guard let top, let reps = top.value("reps") else { return nil }
        return "Last time " + (top.value("load_lb").map { "\(Coach.number($0)) × " } ?? "") + Coach.number(reps)
    }

    /// The rest after a set (FIT-301): a big countdown and its bar, then +30 s and Skip; what's next is under the card.
    /// It runs when the set is done; a rest arrived at from the list is shown, not started, until +30 s.
    private func restCard(index: Int, seconds: TimeInterval, cards: [WorkoutDraft.Card], names: [String: String]) -> some View {
        let active = rest?.page == index ? rest : nil
        let skip = { withAnimation(.snappy) { rest = nil; page = index + 1 } }
        return VStack(spacing: 0) {
            Text("Rest").font(.headline).foregroundStyle(Color.inkMuted)
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                let left = active.map { max(0, $0.ends.timeIntervalSince(context.date)) } ?? seconds
                VStack(spacing: 0) {
                    Text(Duration.seconds(left.rounded(.up)).formatted(.time(pattern: .minuteSecond)))
                        .font(.display(96, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(active == nil ? Color.inkFaint : Color.ink)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.fillStrong)
                            Capsule().fill(Plate.current.mark).frame(width: proxy.size.width * left / max(active?.total ?? seconds, 1))
                        }
                    }
                    .frame(width: 220, height: 6).padding(.top, 10)
                }
            }
            HStack(spacing: 10) {
                // FIT-304: a rest can be cut short as well as stretched; one that runs out moves on as it would.
                Button("−30 s") {
                    if let active {
                        rest?.ends = max(.now, active.ends - 30)
                    } else if seconds > 30 {
                        rest = Rest(ends: .now + seconds - 30, total: seconds - 30, page: index)
                    } else {
                        skip()
                    }
                }
                .accessibilityLabel("30 seconds less")
                Button("+30 s") {
                    if let active {
                        let left = max(0, active.ends.timeIntervalSinceNow)
                        rest?.ends += 30
                        rest?.total = max(active.total, left + 30)
                    } else {
                        rest = Rest(ends: .now + seconds + 30, total: seconds + 30, page: index)
                    }
                }
                .accessibilityLabel("30 seconds more")
                Button("Skip", action: skip)
            }
            .buttonStyle(RestButton())
            .padding(.top, 28)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cardBackground()
    }

    /// "Back Squat", or "Row + Bench" for a superset round.
    static func names(_ rows: [SetRow], _ names: [String: String]) -> String {
        rows.map(\.exercise).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .map { names[$0] ?? $0 }.joined(separator: " + ")
    }

    /// "150 × 5", "30 s", "50/40 × 10+10": weight first, as on a ramp step.
    static func dose(_ rows: [SetRow]) -> String {
        guard let first = rows.first else { return "" }
        let values = rows.map { Coach.number($0.value ?? 0) }.joined(separator: "+")
            + (first.metric == "reps" ? "" : " " + (SetRow.units[first.metric] ?? ""))
        let loads = rows.compactMap(\.load).reduce(into: [Double]()) { if !$0.contains($1) { $0.append($1) } }
        return loads.isEmpty ? values : loads.map(Coach.number).joined(separator: "/") + " × " + values
    }

    private struct RestButton: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label.font(.headline)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(configuration.isPressed ? Color.fillStrong : Color.fill, in: .rect(cornerRadius: 18))
        }
    }

    // MARK: Mic

    private func micArea(onFinish: Bool) -> some View {
        VStack(spacing: 6) {
            if LanguageModel.isAvailable {
                MicButton(voice: voice, onHeard: heard)
                Text(talked ? " " : onFinish ? "Hold to add a note" : "Or say how it went")
                    .font(.footnote).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// FIT-32: on a rest card, what's said is about the set just done ("only got four on that one"); on a set
    /// card it's about that set, which is then logged and its rest starts. Heard values are dashed, with Undo.
    /// On the finish card, speech is the note. Nothing is stored until Save.
    private func heard(_ said: String) {
        talked = true
        let cards = draft.cards
        let position = page
        guard let line = set(at: position, in: cards) else {
            draft.note = said
            withAnimation { toast = Toast(text: "Note added") }
            return
        }
        let onSet = if case .set = cards[position] { true } else { false }
        let names = names
        let exercise = names[draft.rows[line[0]].exercise] ?? draft.rows[line[0]].exercise
        working = said
        Task {
            defer { working = nil }
            do {
                let differences = try await TodayRequestParser.parseSets(said, exercise: exercise)
                let before = draft
                let changed = SpokenLog.apply(differences, to: &draft, names: names, line: line)
                let row = draft.rows[changed.first ?? line[0]]
                let number = row.round + 1
                let text = if let index = changed.first, let value = draft.rows[index].value {
                    "Set \(number) · \(Coach.number(value)) \(draft.rows[index].metric == "reps" ? "reps" : SetRow.units[draft.rows[index].metric] ?? "")"
                } else {
                    "Set \(number) logged"
                }
                withAnimation { toast = Toast(text: text) { draft = before } }
                if onSet {
                    withAnimation(.snappy) {
                        if cards.indices.contains(position + 1), case .rest(let seconds) = cards[position + 1] {
                            rest = Rest(ends: .now + seconds, total: seconds, page: position + 1)
                        }
                        page = position + 1
                    }
                }
            } catch {
                message = "Couldn’t understand that. Swipe to log it, or try again."
            }
        }
    }

    // MARK: Finish card

    private func finishCard(names: [String: String]) -> some View {
        let done = draft.rows.filter(\.done).count
        let total = draft.rows.count
        let main = Set(Planner.catalog(templates).filter(\.isGoalLift).map(\.slug))
        let lifts = draft.lifts(main: main, names: names, tier: AgeTier.of(age: profiles.first?.age ?? 30))
        return VStack(alignment: .leading, spacing: 0) {
            Text("Finish").font(.subheadline).foregroundStyle(.secondary)
            Text(done == total ? "All \(total) sets" : "\(done) of \(total) sets")
                .font(.display(30, weight: .bold)).tracking(-0.4).padding(.top, 4)
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
            FeelChoices(selected: draft.feel) { draft.feel = draft.feel == $0 ? nil : $0 }
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
            Button("Save workout", action: save).buttonStyle(.primary).disabled(done == 0)
        }
        .padding(EdgeInsets(top: 26, leading: 24, bottom: 22, trailing: 24))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardBackground()
    }

    private func stat(_ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.display(28, weight: .semibold, design: .rounded)).tracking(-0.4)
            Text(unit).font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// FIT-326: swaps the lift's sets still to do, here and in today's plan, so the saved session, sync and the coach
    /// agree. The new lift starts from its last time, else with the load empty to set. No confirm: swapping back undoes it.
    private func swap(_ target: SwapTarget, to slug: String) {
        let exercise = Planner.catalog(templates).first { $0.slug == slug }
        let last = lastLoad(slug)
        let perHand = exercise.map { !$0.equipment.isDisjoint(with: ["dumbbells", "kettlebells"]) && !$0.equipment.contains("barbell") } ?? false
        let loadMetric: String? = exercise?.isLoaded == false ? nil : (last?.metric ?? (perHand ? "load_lb_hand" : "load_lb"))
        let logged = draft.rows.filter { $0.block == target.block && $0.exercise == target.exercise && $0.done }.count
        withAnimation(.snappy) {
            draft.swap(block: target.block, from: target.exercise, to: slug, loadMetric: loadMetric, load: last?.value)
        }
        // Today's plan: the day's rows, as Today edits them.
        let day = Calendar.current.startOfDay(for: startedAt)
        let items = planned.filter { $0.kind == .workout && Calendar.current.isDate($0.date, inSameDayAs: day) }
        guard !items.isEmpty else { return }
        var session = Planner.session(items, templates: templates)
        // The draft's blocks are the plan's, warm-up blocks included (WorkoutDraft.init).
        guard session.blocks.indices.contains(target.block),
              let movement = session.blocks[target.block].movements.firstIndex(where: { $0.exercise == target.exercise }) else { return }
        session.swap(block: target.block, movement: movement, to: slug, after: logged,
                     loadMetric: loadMetric, load: loadMetric == nil ? nil : last?.value)
        let written = Planner.save(session, over: items, templates: templates, in: context)
        // The swapped sets now point at the new lift's rows, so their logs match the plan.
        if let id = templates.first(where: { $0.slug == slug })?.id, let row = written.first(where: { $0.templateRef == id }) {
            for index in draft.rows.indices where draft.rows[index].block == target.block && draft.rows[index].exercise == slug && !draft.rows[index].done {
                draft.rows[index].plannedRef = row.id
            }
        }
    }

    /// The new lift's top load the last session before today, and its metric.
    private func lastLoad(_ slug: String) -> (metric: String, value: Double)? {
        let today = Calendar.current.startOfDay(for: startedAt)
        let sets = Planner.loggedSets(entries.filter { $0.timestamp < today }, templates: templates).filter { $0.exercise == slug }
        guard let day = sets.last.map({ Calendar.current.startOfDay(for: $0.date) }) else { return nil }
        for metric in ["load_lb", "load_lb_hand"] {
            if let top = sets.filter({ Calendar.current.startOfDay(for: $0.date) == day }).compactMap({ $0.value(metric) }).max() { return (metric, top) }
        }
        return nil
    }

    private func save() {
        draft.duration = Date.now.timeIntervalSince(startedAt)
        draft.save(at: startedAt, templates: templates, in: context)
        live?.end(saved: (draft.rows.filter(\.done).count, draft.top(names: names)))
        live = nil
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
