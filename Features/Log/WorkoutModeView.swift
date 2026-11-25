import SwiftUI
import SwiftData

/// TKL-934 (W4): pure helpers for the rest card's draining level and final 3-second countdown.
enum RestMotion {
    nonisolated static func isFinalCountdown(_ seconds: Int) -> Bool {
        seconds >= 1 && seconds <= 3
    }

    nonisolated static func levelFraction(remaining: TimeInterval, total: TimeInterval) -> CGFloat {
        guard total > 0 else { return 0 }
        return CGFloat(max(0, min(1, remaining / total)))
    }
}

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
    /// TKL-801: the draft, the card on screen and the running rest, which the Live Activity's buttons change too.
    @State private var workout: LiveWorkout
    var reduceWorkoutMotion = false
    var onSaved: () -> Void = {}
    /// TKL-934 (C1): returns wins earned by this saved workout so Save can condense the finish card straight into the best win.
    var earnedWins: (() -> [WinItem])? = nil
    @State private var startedAt = Date.now
    @State private var peeking = false
    /// A card being dragged sideways, and whether the last move was back (the next card comes in from the left).
    @State private var dragX: CGFloat = 0
    @State private var backward = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { reduceWorkoutMotion || systemReduceMotion }
    @State private var haptics = HapticPlayer()
    /// The set on its way to (or back from) its segment, which fills when it lands.
    @State private var flight: Flight?
    /// Where the numbers are, for the chip that leaves them.
    @State private var numbers: CGPoint?
    @State private var movedOnAt = Date.distantPast
    @State private var banking = false
    @State private var doneCheckTrim: CGFloat = 0
    @State private var showingDoneCheck = false
    @State private var flashedBlock: Int?
    @State private var blockCompleteTick = 0
    @State private var activeBlockScale: Int?
    @State private var nudgedArrival = false
    @State private var previousExerciseKey: String?
    @State private var quitShake = 0
    @State private var undoTick = 0
    @State private var swapFlipAngle: Double = 0
    @State private var saving = false
    /// TKL-934 (C1): wins presented inline by condensing the finish card directly into the win card.
    @State private var inlineWins: [WinItem]?
    @State private var quitting = false
    @State private var voice = VoiceCapture()
    @State private var working: String?
    @State private var talked = false
    @State private var toast: Toast?
    @State private var message: String?
    /// FIT-53: groups I opted in to see each set as it happens.
    @State private var live: LiveShare?
    /// FIT-326: the lift being swapped, from the set card's name or the list.
    @State private var swapping: SwapTarget?
    /// TKL-793: the demo open full screen, by exercise.
    @State private var demo: String?
    @Namespace private var peekTransition
    @Namespace private var swapTransition
    @Namespace private var condenseTransition

    struct SwapTarget: Identifiable {
        var block: Int
        var exercise: String
        var id: String { "\(block) \(exercise)" }
    }

    typealias Rest = WorkoutCursor.Rest

    init(draft: WorkoutDraft, reduceWorkoutMotion: Bool = false, onSaved: @escaping () -> Void = {},
         earnedWins: (() -> [WinItem])? = nil) {
        _workout = State(initialValue: LiveWorkout(draft: draft))
        self.reduceWorkoutMotion = reduceWorkoutMotion
        self.onSaved = onSaved
        self.earnedWins = earnedWins
    }

    private var draft: WorkoutDraft {
        get { workout.draft }
        nonmutating set { workout.draft = newValue }
    }
    private var page: Int {
        get { workout.cursor.page }
        nonmutating set { workout.cursor.page = newValue }
    }
    /// The warm-up step on screen; past the last, the sets.
    private var warmStep: Int {
        get { workout.cursor.warmStep }
        nonmutating set { workout.cursor.warmStep = newValue }
    }
    private var rest: Rest? {
        get { workout.cursor.rest }
        nonmutating set { workout.cursor.rest = newValue }
    }
    private var draftBinding: Binding<WorkoutDraft> { Binding(get: { workout.draft }, set: { workout.draft = $0 }) }
    private var restBinding: Binding<Rest?> { Binding(get: { workout.cursor.rest }, set: { workout.cursor.rest = $0 }) }

    private struct Flight {
        var bank: Bank
        var block: Int
        var sets: Int
    }

    /// The second tap of a double tap lands on whatever the first one brought under the finger: the next set's Done,
    /// or Save on the last card.
    private var justMovedOn: Bool { Date.now.timeIntervalSince(movedOnAt) < 0.35 }

    private var names: [String: String] {
        Dictionary(templates.map { ($0.slug, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        let cards = draft.cards
        let names = names
        let warming = warmStep < draft.warmups.count
        let lockScreen = workout.content()
        let currentBlock = warming ? nil : set(at: page, in: cards).map { draft.rows[$0[0]].block }
        ZStack {
            if let inlineWins {
                CelebrationView(wins: inlineWins, reduceMotion: reduceMotion, cardNamespace: condenseTransition) {
                    leave()
                }
                .transition(.opacity)
            } else {
                workoutDeck(cards: cards, names: names, warming: warming, currentBlock: currentBlock)
            }
        }
        .onChange(of: page) { oldPage, newPage in handlePageChange(from: oldPage, to: newPage, names: names) }
        .onChange(of: currentBlock) { old, new in handleBlockChange(from: old, to: new) }
        .onChange(of: draft.rows.filter(\.done).count) { live?.update(draft.live(at: page, names: names)) }
        .onChange(of: lockScreen) { workout.publish() }
        .onChange(of: names) { workout.names = names }
        .overlay {
            if voice.listening || working != nil {
                ListeningVeil(voice: voice, working: working,
                              prompt: page == draft.cards.count ? "Add a note" : "Say how that set went")
            }
        }
        .overlay(alignment: .bottom) {
            if inlineWins == nil {
                ToastView(toast: $toast).padding(.bottom, 100)
            }
        }
        .animation(.settle, value: voice.listening || working != nil)
        .animation(.settle, value: toast)
        .alert("Couldn’t do that", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: { Text(message ?? "") }
        .onChange(of: voice.problem) { _, problem in if let problem { message = problem } }
        .hapticFallback(for: haptics)
        .sensoryFeedback(.tap, trigger: draft.rows.filter(\.done).count - (flight?.bank.reverse == true ? 0 : (flight?.sets ?? 0)))
        .sensoryFeedback(.tick, trigger: warmStep) { old, new in new > old }
        .sensoryFeedback(.tick, trigger: blockCompleteTick)
        .sensoryFeedback(.tick, trigger: undoTick)
        // A phone that locks mid-set loses the clock; keep it awake while training.
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            workout.names = names
            workout.onRestEnd = { end in restEnded(end) }
            workout.start()
            if Pilot.groups, account.user != nil, live == nil {
                live = LiveShare(workout: draft.session, startedAt: startedAt)
                live?.start()
                live?.update(draft.live(at: page, names: names))
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            workout.end()
            live?.end(saved: nil)
            live = nil
        }
        .confirmationDialog("Leave this workout?", isPresented: $quitting, titleVisibility: .visible) {
            Button("Discard sets", role: .destructive) { leave() }
        } message: {
            Text("Nothing is saved until you press Save on the last card.")
        }
        .sheet(isPresented: $peeking) { peek }
        .fullScreenCover(item: Binding(get: { demo.map(HowToID.init) }, set: { demo = $0?.id })) { item in
            FullScreenDemo(slug: item.id, name: names[item.id] ?? item.id)
        }
        .sheet(item: $swapping) { target in
            ExercisePicker(title: "Swap \(names[target.exercise] ?? target.exercise)", replacing: target.exercise,
                           excluding: Set(draft.rows.map(\.exercise))) { slug in swap(target, to: slug) }
                .modifier(SheetZoomTransition(sourceID: "swap", reduceMotion: reduceMotion, namespace: swapTransition))
        }
    }

    private func workoutDeck(cards: [WorkoutDraft.Card], names: [String: String], warming: Bool, currentBlock: Int?) -> some View {
        VStack(spacing: 0) {
            topBar
            segments(warming: warming, currentBlock: currentBlock)
                .padding(.horizontal, 22).padding(.top, 8)
            // FIT-377: the coach's note on the session, as it starts.
            if page == 0 && warmStep == 0, let note = sessionNote {
                SessionNote(text: note, by: pro.coaches.first?.name ?? "Your coach").padding(.horizontal, 22).padding(.top, 12)
            }
            Group {
                if warming {
                    warmupCard(draft.warmups[warmStep], names: names)
                } else if page >= cards.count {
                    FinishCardView(
                        draft: draftBinding,
                        startedAt: startedAt,
                        names: names,
                        templates: templates,
                        age: profiles.first?.age ?? 30,
                        reduceMotion: reduceMotion,
                        saving: saving,
                        namespace: condenseTransition,
                        onSave: save
                    )
                } else {
                    switch cards[page] {
                    case .set(let line):
                        setCard(line, index: page, cards: cards, names: names)
                    case .rest(let seconds):
                        RestCardView(
                            index: page,
                            seconds: seconds,
                            rest: restBinding,
                            reduceMotion: reduceMotion,
                            onSkip: { skipRest(from: page) }
                        )
                    }
                }
            }
            .id("\(warming ? warmStep : -1) \(page)")
            .transition(cardTransition)
            .offset(x: dragX)
            .rotationEffect(.degrees(Double(dragX) / 40))
            .modifier(Shake(trigger: quitShake, reduceMotion: reduceMotion))
            .gesture(swipe(cards: cards, page: page, warmStep: warmStep))
            .padding(.horizontal, 22)
            .padding(.top, 16)
            footer(cards: cards, names: names, warming: warming)
                .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 8)
            if Pilot.inAppAI { micArea(onFinish: page == cards.count).frame(height: 104) }
        }
        .animation(reduceMotion ? .out : .settle, value: page)
        .animation(reduceMotion ? .out : .settle, value: warmStep)
        .screenBackground()
        .banking(flight?.bank, onArrival: land)
    }

    private func handlePageChange(from oldPage: Int, to newPage: Int, names: [String: String]) {
        live?.update(draft.live(at: newPage, names: names))
        if newPage >= draft.cards.count { toast = nil }
        let oldKey = exerciseKey(at: oldPage, in: draft.cards)
        let newKey = exerciseKey(at: newPage, in: draft.cards)
        if oldKey != nil, oldKey != newKey { previousExerciseKey = oldKey }
        if nudgedArrival {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                nudgedArrival = false
            }
        }
    }

    private func handleBlockChange(from old: Int?, to new: Int?) {
        guard let new, old != new, !reduceMotion else { return }
        withAnimation(.release) { activeBlockScale = new }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
            withAnimation(.tap) {
                if activeBlockScale == new { activeBlockScale = nil }
            }
        }
    }

    /// TKL-801: a rest ran out (`LiveWorkout` times it, so it ends on time with the screen away too); `end` moves on.
    private func restEnded(_ end: () -> Void) {
        haptics.play(.ready)
        // Rest's over: next set card nudges in from the side.
        nudgedArrival = !reduceMotion
        backward = false
        withAnimation(reduceMotion ? .out : .release) { end() }
    }

    private var cardTransition: AnyTransition {
        if reduceMotion { return .opacity }
        if nudgedArrival {
            return .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .scale(scale: 0.96)).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            )
        }
        return .asymmetric(
            insertion: .move(edge: backward ? .leading : .trailing).combined(with: .opacity),
            removal: .move(edge: backward ? .trailing : .leading).combined(with: .opacity)
        )
    }

    private func exerciseKey(at index: Int, in cards: [WorkoutDraft.Card]) -> String? {
        guard let line = set(at: index, in: cards) else { return nil }
        return line.map { draft.rows[$0].exercise }.joined(separator: "+")
    }

    private var peek: some View {
        let cards = draft.cards
        let names = names
        return PeekSheetView(
            draft: draft,
            cards: cards,
            names: names,
            current: set(at: page, in: cards),
            reduceMotion: reduceMotion,
            onPick: { index in
                peeking = false
                withAnimation(reduceMotion ? .out : .settle) {
                    warmStep = draft.warmups.count
                    page = index
                }
            },
            onSwap: { target in
                peeking = false
                swapping = target
            },
            onClose: { peeking = false }
        )
        .modifier(SheetZoomTransition(sourceID: "peek", reduceMotion: reduceMotion, namespace: peekTransition))
    }

    private var topBar: some View {
        HStack {
            Button {
                if draft.rows.contains(where: \.done) {
                    if !reduceMotion { quitShake += 1 }
                    haptics.play(.warning)
                    quitting = true
                } else {
                    leave()
                }
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
            .matchedTransitionSource(id: "peek", in: peekTransition)
            .accessibilityLabel("Whole workout")
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
    }

    /// TKL-934 (W1, W2): small warm-up segment before the exercise blocks; filled with overshoot, flashed on block complete,
    /// and scaled when becoming current.
    private func segments(warming: Bool, currentBlock: Int?) -> some View {
        HStack(spacing: 4) {
            if !draft.warmups.isEmpty {
                let warmFraction = Double(min(warmStep, draft.warmups.count)) / Double(max(draft.warmups.count, 1))
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(.separator))
                        Capsule().fill(.primary).frame(width: proxy.size.width * warmFraction)
                    }
                }
                .frame(width: 26, height: 4)
                .opacity(warming ? 1 : 0.55)
                .animation(reduceMotion ? nil : .release, value: warmStep)
            }
            ForEach(draft.blocks, id: \.self) { block in
                let rows = draft.rows.filter { $0.block == block }
                let flying = flight.flatMap { !$0.bank.reverse && $0.block == block ? $0.sets : nil } ?? 0
                let doneCount = max(0, rows.filter(\.done).count - flying)
                let done = Double(doneCount) / Double(max(rows.count, 1))
                let isCurrent = !warming && currentBlock == block
                let isFlashing = flashedBlock == block
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(.separator))
                        Capsule()
                            .fill(isFlashing ? AnyShapeStyle(Plate.current.accent) : AnyShapeStyle(.primary))
                            .frame(width: proxy.size.width * done)
                    }
                }
                .frame(height: 4)
                .scaleEffect(y: activeBlockScale == block && !reduceMotion ? 2.0 : 1.0)
                .bankTarget(block)
                .opacity(isCurrent ? 1 : 0.55)
            }
        }
        .padding(.vertical, 5)
        .animation(reduceMotion ? nil : .release, value: draft.rows.filter(\.done).count)
        .animation(reduceMotion ? nil : .release, value: flight?.bank.id)
        .animation(reduceMotion ? .out : .tap, value: flashedBlock)
        .accessibilityHidden(true)
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
        let key = exercises.joined(separator: "+")
        let isNewExercise = previousExerciseKey != nil && previousExerciseKey != key
        return SetCardChrome(
            isSuperset: exercises.count > 1,
            isNewExercise: isNewExercise,
            cue: cue(rows),
            reduceMotion: reduceMotion
        ) { titleVisible, bracketTrim, cueVisible in
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Set \(first.round + 1) of \(rounds)\(exercises.count > 1 ? " · superset" : "")")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Plate.current.mark)
                    Spacer()
                    if done {
                        Label("Logged", systemImage: "checkmark.circle.fill").font(.footnote.weight(.semibold)).foregroundStyle(Color.inkMuted)
                    }
                }
                if exercises.count > 1 {
                    // TKL-934 (W10): superset names pair with a drawn bracket.
                    HStack(alignment: .center, spacing: 12) {
                        SupersetBracket()
                            .trim(from: 0, to: reduceMotion ? 1 : bracketTrim)
                            .stroke(Plate.current.mark, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .frame(width: 10)
                            .padding(.vertical, 4)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(exercises, id: \.self) { slug in
                                Text(names[slug] ?? slug)
                                    .font(.display(26))
                                    .lineLimit(1).minimumScaleFactor(0.7)
                            }
                        }
                        .offset(x: titleVisible || reduceMotion ? 0 : 32)
                        .opacity(titleVisible ? 1 : 0)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                } else {
                    // FIT-326 + TKL-934 (W8): swap zooms picker from/to name and flips the name on X.
                    Button {
                        if !done { swapping = SwapTarget(block: first.block, exercise: exercises[0]) }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(exercises.map { names[$0] ?? $0 }.joined(separator: " + "))
                                .font(.display(30)).lineLimit(2).minimumScaleFactor(0.7).multilineTextAlignment(.leading)
                                .rotation3DEffect(.degrees(reduceMotion ? 0 : swapFlipAngle), axis: (x: 1, y: 0, z: 0), perspective: 0.45)
                            if !done {
                                Image(systemName: "arrow.triangle.2.circlepath").font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Plate.current.mark)
                            }
                        }
                        .foregroundStyle(Color.ink)
                        .offset(x: titleVisible || reduceMotion ? 0 : 32)
                        .opacity(titleVisible ? 1 : 0)
                    }
                    .buttonStyle(.plain)
                    .matchedTransitionSource(id: "swap", in: swapTransition)
                    .padding(.top, 4)
                    .disabled(done)
                    .accessibilityHint(!done ? "Swap this exercise" : "")
                }
                if let cue = cue(rows) {
                    Text(cue).font(.subheadline).foregroundStyle(Color.inkMuted).padding(.top, 6).lineLimit(3)
                        .opacity(cueVisible ? 1 : 0)
                }
                // FIT-447: the form demo, small, while you set up; nothing when the lift has no clip or it can't load.
                if exercises.count == 1, ExerciseDemos.url(exercises[0]) != nil {
                    // TKL-793: tapped, it opens full screen with Slow.
                    Button { demo = exercises[0] } label: {
                        DemoClip(slug: exercises[0], corner: 14) { EmptyView() }
                            .frame(width: 104, height: 104)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("workout.demo")
                    .accessibilityLabel("Video: one rep of the movement")
                    .accessibilityHint("Opens it full screen")
                    .padding(.top, 12)
                }
                Spacer(minLength: 12)
                // TKL-934 (W3): reusable physical steppers with hold-to-repeat, directional roll, 1.04 scale, and pulsing "–".
                HStack(alignment: .top, spacing: 12) {
                    if let load {
                        PhysicalStepper(
                            value: load,
                            unit: SetRow.units[first.loadMetric ?? "load_lb"] ?? "lb",
                            lessLabel: "5 lb lighter",
                            moreLabel: "5 lb heavier",
                            isPlaceholder: load == "–",
                            reduceMotion: reduceMotion
                        ) { draft.adjust(line, load: true, by: $0) }
                    }
                    PhysicalStepper(
                        value: values,
                        unit: unit(first, pair: exercises.count > 1, plain: true),
                        lessLabel: "Fewer",
                        moreLabel: "More",
                        reduceMotion: reduceMotion
                    ) { draft.adjust(line, load: false, by: $0) }
                }
                .frame(maxWidth: .infinity)
                .bankSource { numbers = $0 }
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
    }

    /// A warm-up step (FIT-301): what to do and how much, big. Done moves on; nothing is logged.
    private func warmupCard(_ step: WorkoutDraft.Warmup, names: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(step.ramp ? "Warm-up · ramp" : "Warm-up").font(.subheadline.weight(.semibold)).foregroundStyle(Color.inkMuted)
            Text(step.exercise.map { names[$0] ?? $0 } ?? "Row, bike or walk, easy")
                .font(.display(30)).padding(.top, 4).lineLimit(2).minimumScaleFactor(0.7)
            Spacer(minLength: 12)
            Text(step.dose).font(.display(76, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.5).frame(maxWidth: .infinity)
            Spacer(minLength: 12)
        }
        .padding(EdgeInsets(top: 24, leading: 22, bottom: 22, trailing: 22))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardBackground()
    }

    /// Under the card: what's next (rolls on change), then the one action (draws checkmark inside Done on button tap).
    @ViewBuilder private func footer(cards: [WorkoutDraft.Card], names: [String: String], warming: Bool) -> some View {
        let nextLine = nextText(cards: cards, names: names, warming: warming)
        let shownPage = page
        let shownWarmStep = warmStep
        VStack(alignment: .leading, spacing: 12) {
            if let nextLine {
                ZStack(alignment: .leading) {
                    Text(nextLine)
                        .font(.subheadline)
                        .foregroundStyle(Color.inkMuted)
                        .lineLimit(1)
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .id(nextLine)
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: .move(edge: backward ? .top : .bottom).combined(with: .opacity),
                            removal: .move(edge: backward ? .bottom : .top).combined(with: .opacity)
                        ))
                }
                .clipped()
                .animation(reduceMotion ? .out : .tap, value: nextLine)
            }
            if warming {
                Button("Done") { forward(cards: cards, from: shownPage, warmStep: shownWarmStep, viaSwipe: false) }
                    .buttonStyle(.primary)
            } else if cards.indices.contains(page), case .set(let line) = cards[page] {
                let done = line.allSatisfy { draft.rows[$0].done }
                let restAfter: TimeInterval? = if cards.indices.contains(page + 1), case .rest(let seconds) = cards[page + 1] { seconds } else { nil }
                let label = done ? "Next" : restAfter.map { "Done · rest \(Duration.seconds($0).formatted(.time(pattern: .minuteSecond)))" } ?? "Done"
                Button {
                    forward(cards: cards, from: shownPage, warmStep: shownWarmStep, viaSwipe: false)
                } label: {
                    ZStack {
                        Text(label).opacity(showingDoneCheck ? 0 : 1)
                        if showingDoneCheck {
                            CheckmarkStroke()
                                .trim(from: 0, to: doneCheckTrim)
                                .stroke(Plate.current.onAccent, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                                .frame(width: 24, height: 24)
                        }
                    }
                }
                .buttonStyle(.primary)
                .accessibilityLabel(label)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func skipRest(from index: Int) {
        undoTick += 1
        backward = false
        nudgedArrival = false
        withAnimation(reduceMotion ? .out : .throw) { workout.cursor.skipRest(on: index) }
    }

    /// The card's main action, from its button or a swipe to the left: a warm-up step is done, a set is logged and its
    /// rest starts, a rest is skipped. The finish card stays (Save is its own button).
    private func forward(cards: [WorkoutDraft.Card], from shownPage: Int, warmStep shownWarmStep: Int,
                         viaSwipe: Bool, velocity: CGFloat = 0) {
        guard page == shownPage, warmStep == shownWarmStep, !justMovedOn, !banking else { return }
        backward = false
        nudgedArrival = false
        if warmStep < draft.warmups.count {
            movedOnAt = .now
            if viaSwipe, !reduceMotion {
                throwCardOff(velocity: velocity) {
                    warmStep += 1
                }
            } else {
                withAnimation(reduceMotion ? .out : .settle) { warmStep += 1 }
            }
            return
        }
        guard cards.indices.contains(page) else { return }
        if case .rest = cards[page] {
            movedOnAt = .now
            skipRest(from: page)
            return
        }
        guard case .set(let line) = cards[page] else { return }
        let alreadyDone = line.allSatisfy { draft.rows[$0].done }
        if alreadyDone || reduceMotion {
            movedOnAt = .now
            _ = swiped(from: page, .next, cards: cards)
            withAnimation(reduceMotion ? .out : .settle) { page += 1 }
            return
        }

        // TKL-934 (W1):
        // - From button: checkmark draws inside Done first (~200ms), then chip detaches and drops into segment, then card leaves.
        // - From swipe: card leaves immediately with finger velocity while chip banks into segment.
        banking = true
        movedOnAt = .now
        if viaSwipe {
            _ = swiped(from: shownPage, .next, cards: cards)
            throwCardOff(velocity: velocity) {
                page = shownPage + 1
                banking = false
                movedOnAt = .now
            }
        } else {
            showingDoneCheck = true
            doneCheckTrim = 0
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.20)) {
                doneCheckTrim = 1
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(210))
                guard page == shownPage else {
                    showingDoneCheck = false
                    doneCheckTrim = 0
                    banking = false
                    return
                }
                _ = swiped(from: shownPage, .next, cards: cards)
                // Let the chip travel toward the segment before throwing the card away.
                try? await Task.sleep(for: .milliseconds(320))
                showingDoneCheck = false
                doneCheckTrim = 0
                if page == shownPage {
                    withAnimation(.throw) { page = shownPage + 1 }
                }
                banking = false
                movedOnAt = .now
            }
        }
    }

    private func throwCardOff(velocity: CGFloat, completion: @escaping @MainActor () -> Void) {
        let speed = max(abs(velocity), 600)
        let duration = max(0.14, min(0.36, Double(460 / speed)))
        withAnimation(.timingCurve(0.2, 0.6, 0.4, 1.0, duration: duration), completionCriteria: .logicallyComplete) {
            dragX = -460
        } completion: {
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet) {
                dragX = 0
                completion()
            }
        }
    }

    /// A swipe to the right: the card before, the last warm-up step before the first set. A rest still running keeps
    /// running, and nothing is unlogged.
    private func back() {
        guard !banking else { return }
        backward = true
        nudgedArrival = false
        withAnimation(reduceMotion ? .out : .settle) {
            if warmStep < draft.warmups.count { warmStep = max(0, warmStep - 1) }
            else if page > 0 { page -= 1 }
            else if !draft.warmups.isEmpty { warmStep = draft.warmups.count - 1 }
        }
    }

    /// The card follows a sideways drag; far enough (or flicked) and it goes forward or back, else it springs home.
    private func swipe(cards: [WorkoutDraft.Card], page shownPage: Int, warmStep shownWarmStep: Int) -> some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard !banking, abs(value.translation.width) > abs(value.translation.height) else { return }
                if !reduceMotion { dragX = value.translation.width }
            }
            .onEnded { value in
                guard !banking else { return }
                let distance = value.predictedEndTranslation.width
                let vx = value.velocity.width
                guard abs(value.translation.width) > abs(value.translation.height) else {
                    withAnimation(reduceMotion ? nil : .release) { dragX = 0 }
                    return
                }
                if distance < -120 || vx < -600 {
                    forward(cards: cards, from: shownPage, warmStep: shownWarmStep, viaSwipe: true, velocity: vx)
                } else if distance > 120 || vx > 600 {
                    withAnimation(reduceMotion ? nil : .settle) { dragX = 0 }
                    back()
                } else {
                    withAnimation(reduceMotion ? nil : .release) { dragX = 0 }
                }
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
                let rows = line.map { draft.rows[$0] }
                let block = rows[0].block
                if let flight { land(flight.bank.id) }
                let sets = line.filter { !draft.rows[$0].done }.count
                let chip = Self.chipLabel(rows)
                var restLength: TimeInterval? = nil
                #if DEBUG
                if DebugRole.workoutMotionFixture { restLength = 10 }
                #endif
                workout.cursor.log(index, &workout.draft, restLength: restLength)
                if !reduceMotion, let numbers {
                    flight = Flight(bank: Bank(target: block, from: numbers, label: chip), block: block, sets: sets)
                } else {
                    checkBlockComplete(block)
                }
                if restAfter != nil {
                    // Offer Undo during the rest card (lifts the chip back out as the segment drains).
                    let liftName = Self.names(rows, names)
                    toast = Toast(text: "Logged \(liftName) \(chip)") {
                        unbank(line, returningTo: index)
                    }
                }
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

    private func land(_ id: Bank.ID) {
        guard let current = flight, current.bank.id == id else { return }
        let wasReverse = current.bank.reverse
        let block = current.block
        withAnimation(reduceMotion ? nil : .release) { flight = nil }
        if !wasReverse {
            checkBlockComplete(block)
        }
    }

    private func checkBlockComplete(_ block: Int) {
        let rows = draft.rows.filter { $0.block == block }
        guard !rows.isEmpty, rows.allSatisfy(\.done) else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            blockCompleteTick += 1
            withAnimation(reduceMotion ? .out : .tap) { flashedBlock = block }
            try? await Task.sleep(for: .milliseconds(420))
            withAnimation(.out) { if flashedBlock == block { flashedBlock = nil } }
        }
    }

    private func leave() {
        withPresentation(reduceMotion: reduceMotion) { dismiss() }
    }

    /// TKL-934 (W6): Undo lifts the chip back out of its segment as the segment drains and returns to the set's card.
    private func unbank(_ line: [Int], returningTo index: Int) {
        if let flight { land(flight.bank.id) }
        let rows = line.map { draft.rows[$0] }
        let block = rows[0].block
        let chip = Self.chipLabel(rows)
        rest = nil
        undoTick += 1
        withAnimation(reduceMotion ? .out : .settle) {
            draft.untick(line)
        }
        if !reduceMotion, let numbers {
            flight = Flight(bank: Bank(target: block, from: numbers, label: chip, reverse: true), block: block, sets: line.count)
        }
        backward = true
        withAnimation(reduceMotion ? .out : .settle) {
            page = index
        }
    }

    private func unlog(_ line: [Int]) {
        if let flight { land(flight.bank.id) }
        let before = draft
        let rows = line.map { draft.rows[$0] }
        let block = rows[0].block
        let chip = Self.chipLabel(rows)
        undoTick += 1
        withAnimation(reduceMotion ? .out : .settle) { draft.untick(line) }
        if !reduceMotion, let numbers {
            flight = Flight(bank: Bank(target: block, from: numbers, label: chip, reverse: true), block: block, sets: line.count)
        }
        withAnimation {
            toast = Toast(text: "Set \(draft.rows[line[0]].round + 1) unlogged") {
                draft = before
            }
        }
    }

    /// "reps × lb", "reps each × lb/hand", "seconds".
    private func unit(_ row: SetRow, pair: Bool = false, plain: Bool = false) -> String {
        let value = row.metric == "reps" ? (pair ? "reps each" : "reps") : row.metric == "duration_s" ? "seconds" : SetRow.units[row.metric] ?? ""
        guard !plain, let loadMetric = row.loadMetric else { return value }
        return "\(value) × \(SetRow.units[loadMetric] ?? "lb")"
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

    /// TKL-934 (W1): the flying banking chip text: "5 × 170", "8 × 135 + 8 × 115", "10 reps", "45 s".
    nonisolated static func chipLabel(_ rows: [SetRow]) -> String {
        rows.map { row in
            let v = Coach.number(row.value ?? 0)
            if let loadMetric = row.loadMetric, !loadMetric.isEmpty, let load = row.load {
                return "\(v) × \(Coach.number(load))"
            }
            if row.metric == "reps" { return "\(v) reps" }
            let u = SetRow.units[row.metric] ?? ""
            return u.isEmpty ? v : "\(v) \(u)"
        }.joined(separator: " + ")
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
                    withAnimation(.settle) {
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

    /// FIT-326 + TKL-934 (W8): swaps the lift's sets still to do, flipping the old name out on X and the new one in.
    private func swap(_ target: SwapTarget, to slug: String) {
        let exercise = Planner.catalog(templates).first { $0.slug == slug }
        let last = lastLoad(slug)
        let perHand = exercise.map { !$0.equipment.isDisjoint(with: ["dumbbells", "kettlebells"]) && !$0.equipment.contains("barbell") } ?? false
        let loadMetric: String? = exercise?.isLoaded == false ? nil : (last?.metric ?? (perHand ? "load_lb_hand" : "load_lb"))
        let logged = draft.rows.filter { $0.block == target.block && $0.exercise == target.exercise && $0.done }.count

        let applySwap = {
            draft.swap(block: target.block, from: target.exercise, to: slug, loadMetric: loadMetric, load: last?.value)
            let day = Calendar.current.startOfDay(for: startedAt)
            let items = planned.filter { $0.kind == .workout && Calendar.current.isDate($0.date, inSameDayAs: day) }
            guard !items.isEmpty else { return }
            var session = Planner.session(items, templates: templates)
            guard session.blocks.indices.contains(target.block),
                  let movement = session.blocks[target.block].movements.firstIndex(where: { $0.exercise == target.exercise }) else { return }
            session.swap(block: target.block, movement: movement, to: slug, after: logged,
                         loadMetric: loadMetric, load: loadMetric == nil ? nil : last?.value)
            let written = Planner.save(session, over: items, templates: templates, in: context)
            if let id = templates.first(where: { $0.slug == slug })?.id, let row = written.first(where: { $0.templateRef == id }) {
                for index in draft.rows.indices where draft.rows[index].block == target.block && draft.rows[index].exercise == slug && !draft.rows[index].done {
                    draft.rows[index].plannedRef = row.id
                }
            }
        }

        if reduceMotion {
            applySwap()
            return
        }
        // Flip out on X (0° → 90°), swap name + load, flip in (-90° → 0°).
        withAnimation(.easeIn(duration: 0.15)) { swapFlipAngle = 90 }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(155))
            applySwap()
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet) { swapFlipAngle = -90 }
            withAnimation(.tap) { swapFlipAngle = 0 }
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
        guard !saving, !justMovedOn else { return }
        saving = true
        toast = nil
        draft.duration = Date.now.timeIntervalSince(startedAt)
        draft.save(at: startedAt, templates: templates, in: context)
        // The zoom back takes its picture of Today as it starts, so Today has to show the day done by then: commit
        // now rather than at the next autosave, and give it a few frames to draw.
        try? context.save()
        live?.end(saved: (draft.rows.filter(\.done).count, draft.top(names: names)))
        live = nil
        onSaved()
        // TKL-934 (C1): if this workout earned wins, condense the finish card directly into the best win's card.
        if let wins = earnedWins?(), !wins.isEmpty {
            withAnimation(reduceMotion ? .out : .settle) {
                inlineWins = wins
            }
            return
        }
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            leave()
        }
    }
}

// MARK: - Subviews for TKL-934 workout motion moments

/// Drives per-card arrival motion: new exercise title push, superset bracket draw, and coach's cue fade-in.
private struct SetCardChrome<Content: View>: View {
    let isSuperset: Bool
    let isNewExercise: Bool
    let cue: String?
    let reduceMotion: Bool
    @ViewBuilder let content: (_ titleVisible: Bool, _ bracketTrim: CGFloat, _ cueVisible: Bool) -> Content

    @State private var titleVisible = false
    @State private var bracketTrim: CGFloat = 0
    @State private var cueVisible = false

    var body: some View {
        content(
            isNewExercise && !reduceMotion ? titleVisible : true,
            isSuperset && !reduceMotion ? bracketTrim : 1,
            cue != nil && !reduceMotion ? cueVisible : true
        )
        .onAppear {
            if reduceMotion {
                titleVisible = true
                bracketTrim = 1
                cueVisible = true
                return
            }
            if isNewExercise {
                titleVisible = false
                withAnimation(.settle.delay(0.06)) { titleVisible = true }
            } else {
                titleVisible = true
            }
            if isSuperset {
                bracketTrim = 0
                withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.42).delay(0.18)) {
                    bracketTrim = 1
                }
            } else {
                bracketTrim = 1
            }
            if cue != nil {
                cueVisible = false
                withAnimation(.reveal.delay(0.26)) { cueVisible = true }
            } else {
                cueVisible = true
            }
        }
    }
}

/// TKL-934 (W4): rest card with a draining level background, final 3-second tick + digit pulse,
/// directional numericText on −30 s / +30 s, springing bar, and sliding Skip.
private struct RestCardView: View {
    let index: Int
    let seconds: TimeInterval
    @Binding var rest: WorkoutModeView.Rest?
    let reduceMotion: Bool
    let onSkip: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var countsDown = true
    @State private var lastShownSecond: Int?
    @State private var pulseCount = 0
    @State private var adjustTick = 0
    @State private var adjustSpring = 0

    private var active: WorkoutModeView.Rest? { rest?.page == index ? rest : nil }

    var body: some View {
        TimelineView(.periodic(from: .now, by: reduceMotion ? 0.25 : 0.08)) { context in
            let left = active.map { max(0, $0.ends.timeIntervalSince(context.date)) } ?? seconds
            let total = max(active?.total ?? seconds, 1)
            let fraction = RestMotion.levelFraction(remaining: left, total: total)
            let shown = Int(left.rounded(.up))
            ZStack {
                // Draining level background beside the bar so a full rest is readable without reading digits.
                GeometryReader { proxy in
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Rectangle()
                            .fill(Plate.current.accent.opacity(colorScheme == .dark ? 0.18 : 0.12))
                            .frame(height: proxy.size.height * fraction)
                            .animation(reduceMotion ? nil : .release, value: adjustSpring)
                    }
                }
                .accessibilityHidden(true)

                VStack(spacing: 0) {
                    Text("Rest").font(.headline).foregroundStyle(Color.inkMuted)
                    Text(Duration.seconds(shown).formatted(.time(pattern: .minuteSecond)))
                        .font(.display(96, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(active == nil ? Color.inkFaint : Color.ink)
                        .contentTransition(reduceMotion ? .identity : .numericText(countsDown: countsDown))
                        .keyframeAnimator(initialValue: 1.0, trigger: pulseCount) { content, scale in
                            content.scaleEffect(reduceMotion ? 1.0 : scale)
                        } keyframes: { _ in
                            KeyframeTrack {
                                SpringKeyframe(1.08, duration: 0.12)
                                SpringKeyframe(1.0, duration: 0.2)
                            }
                        }
                        .onChange(of: shown) { old, new in
                            guard active != nil, old != new else { return }
                            countsDown = new < old
                            lastShownSecond = new
                            if RestMotion.isFinalCountdown(new) {
                                pulseCount += 1
                            }
                        }
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.fillStrong)
                            Capsule()
                                .fill(Plate.current.mark)
                                .frame(width: proxy.size.width * fraction)
                                .animation(reduceMotion ? nil : .release, value: adjustSpring)
                        }
                    }
                    .frame(width: 220, height: 6).padding(.top, 10)

                    HStack(spacing: 10) {
                        Button("−30 s") {
                            countsDown = true
                            adjustTick += 1
                            withAnimation(reduceMotion ? nil : .release) {
                                adjustSpring += 1
                                if let active {
                                    rest?.ends = max(.now, active.ends - 30)
                                } else if seconds > 30 {
                                    let now = Date.now
                                    rest = WorkoutModeView.Rest(started: now, ends: now + seconds - 30, total: seconds - 30, page: index)
                                } else {
                                    onSkip()
                                }
                            }
                        }
                        .accessibilityLabel("30 seconds less")
                        Button("+30 s") {
                            countsDown = false
                            adjustTick += 1
                            withAnimation(reduceMotion ? nil : .release) {
                                adjustSpring += 1
                                if let active {
                                    let remaining = max(0, active.ends.timeIntervalSinceNow)
                                    rest?.ends += 30
                                    rest?.total = max(active.total, remaining + 30)
                                } else {
                                    let now = Date.now
                                    rest = WorkoutModeView.Rest(started: now, ends: now + seconds + 30, total: seconds + 30, page: index)
                                }
                            }
                        }
                        .accessibilityLabel("30 seconds more")
                        Button("Skip", action: onSkip)
                    }
                    .buttonStyle(RestButton())
                    .padding(.top, 28)
                }
                .padding(22)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(.rect(cornerRadius: 24))
        .cardBackground()
        .sensoryFeedback(.tick, trigger: pulseCount)
        .sensoryFeedback(.tick, trigger: adjustTick)
    }

    private struct RestButton: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label.font(.headline)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(configuration.isPressed ? Color.fillStrong : Color.fill, in: .rect(cornerRadius: 18))
                .modifier(Pressed(pressed: configuration.isPressed))
        }
    }
}

/// TKL-934 (W13): finish card with counting-up stats, rising coach line, sliding FeelChoices, and sweeping Save fill.
private struct FinishCardView: View {
    @Binding var draft: WorkoutDraft
    let startedAt: Date
    let names: [String: String]
    let templates: [Template]
    let age: Int
    let reduceMotion: Bool
    let saving: Bool
    let namespace: Namespace.ID
    let onSave: () -> Void

    @State private var appeared = false
    @State private var shownMin = 0.0
    @State private var shownSets = 0.0
    @State private var shownVolume = 0.0
    @State private var coachVisible = false
    @State private var saveFilled = false

    var body: some View {
        let done = draft.rows.filter(\.done).count
        let total = draft.rows.count
        let minutes = max(1, Int((Date.now.timeIntervalSince(startedAt) / 60).rounded()))
        let main = Set(Planner.catalog(templates).filter(\.isGoalLift).map(\.slug))
        let lifts = draft.lifts(main: main, names: names, tier: AgeTier.of(age: age))
        VStack(alignment: .leading, spacing: 0) {
            Text("Finish").font(.subheadline).foregroundStyle(.secondary)
            Text(done == total ? "All \(total) sets" : "\(done) of \(total) sets")
                .font(.display(30, weight: .bold)).tracking(-0.4).padding(.top, 4)
            HStack(alignment: .top, spacing: 8) {
                stat(shownMin, "min")
                stat(shownSets, done == 1 ? "set" : "sets")
                stat(shownVolume, "lb")
            }
            .padding(.top, 22)
            Text(Coach.done(lifts, missedSets: total - done))
                .padding(.top, 20)
                .fixedSize(horizontal: false, vertical: true)
                .offset(y: coachVisible || reduceMotion ? 0 : 14)
                .opacity(coachVisible ? 1 : 0)
            Text("How did it feel?").font(.subheadline).foregroundStyle(.secondary).padding(.top, 24)
            FeelChoices(selected: draft.feel, reduceMotion: reduceMotion) {
                draft.feel = draft.feel == $0 ? nil : $0
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
            Button(action: onSave) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Plate.current.accent.opacity(done > 0 ? 0.25 : 0.4))
                    if done > 0 {
                        RoundedRectangle(cornerRadius: 18)
                            .fill(Plate.current.accent)
                            .scaleEffect(x: saveFilled || reduceMotion ? 1 : 0, anchor: .leading)
                    }
                    Text("Save workout")
                        .font(.headline)
                        .foregroundStyle(Plate.current.onAccent)
                }
                .frame(maxWidth: .infinity, minHeight: 56, maxHeight: 56)
                .clipShape(.rect(cornerRadius: 18))
                .opacity(done > 0 ? 1 : 0.45)
            }
            .buttonStyle(.plain)
            .disabled(done == 0 || saving)
            .accessibilityLabel("Save workout")
        }
        .padding(EdgeInsets(top: 26, leading: 24, bottom: 22, trailing: 24))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardBackground()
        .modifier(FinishCardMatch(namespace: namespace, reduceMotion: reduceMotion))
        .onAppear {
            guard !appeared else { return }
            appeared = true
            if reduceMotion {
                shownMin = Double(minutes)
                shownSets = Double(done)
                shownVolume = draft.volume
                coachVisible = true
                saveFilled = done > 0
                return
            }
            withAnimation(.timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.65).delay(0.12)) {
                shownMin = Double(minutes)
            }
            withAnimation(.timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.65).delay(0.20)) {
                shownSets = Double(done)
            }
            withAnimation(.timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.65).delay(0.28)) {
                shownVolume = draft.volume
            }
            withAnimation(.reveal.delay(0.45)) {
                coachVisible = true
            }
            if done > 0 {
                withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.48).delay(0.55)) {
                    saveFilled = true
                }
            }
        }
        .onChange(of: done) { _, newDone in
            shownSets = Double(newDone)
            shownVolume = draft.volume
            withAnimation(reduceMotion ? .out : .timingCurve(0.4, 0, 0.2, 1, duration: 0.45)) {
                saveFilled = newDone > 0
            }
        }
    }

    private func stat(_ value: Double, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CountingNumber(value: value)
                .font(.display(28, weight: .semibold, design: .rounded)).tracking(-0.4)
            Text(unit).font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FinishCardMatch: ViewModifier {
    let namespace: Namespace.ID
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.matchedGeometryEffect(id: "workout.finishCard", in: namespace)
        }
    }
}

/// TKL-934 (W14): the peek sheet opens scrolled to the current set with a soft highlight, and zooms from/to its button.
private struct PeekSheetView: View {
    let draft: WorkoutDraft
    let cards: [WorkoutDraft.Card]
    let names: [String: String]
    let current: [Int]?
    let reduceMotion: Bool
    let onPick: (Int) -> Void
    let onSwap: (WorkoutModeView.SwapTarget) -> Void
    let onClose: () -> Void

    @State private var highlightStrong = false
    @State private var pickTick = 0

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(draft.blocks, id: \.self) { block in
                        blockSection(block)
                    }
                }
                .onAppear { scrollToCurrent(proxy) }
            }
            .navigationTitle(draft.session)
            .navigationSubtitle("\(draft.rows.filter(\.done).count) of \(draft.rows.count) sets logged")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: onClose) } }
        }
        .sensoryFeedback(.tick, trigger: pickTick)
        .presentationDetents([.medium, .large])
    }

    private func blockSection(_ block: Int) -> some View {
        let blockRows = draft.rows.filter { $0.block == block }
        let heading = SessionPlan.letter(block) + " · " + WorkoutModeView.names(blockRows, names)
        return Section(heading) {
            ForEach(draft.lines(block: block), id: \.self) { line in
                peekRow(line)
            }
        }
    }

    private func peekRow(_ line: [Int]) -> some View {
        let rows = line.map { draft.rows[$0] }
        let done = rows.allSatisfy(\.done)
        let isCurrent = line == current
        let rowBg: Color = isCurrent
            ? Plate.current.accent.opacity(highlightStrong && !reduceMotion ? 0.22 : 0.12)
            : Color.clear
        return Button {
            pickTick += 1
            if let index = cards.firstIndex(of: .set(line)) {
                onPick(index)
            } else {
                onClose()
            }
        } label: {
            HStack {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(done ? .primary : .tertiary)
                Text("Set \(rows[0].round + 1)")
                Spacer()
                Text(WorkoutModeView.dose(rows)).foregroundStyle(.secondary).monospacedDigit()
            }
            .fontWeight(isCurrent ? .semibold : .regular)
            .contentShape(.rect)
        }
        .id(line)
        .buttonStyle(.plain)
        .listRowBackground(rowBg)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .swipeActions {
            if !done, rows.count == 1 {
                Button("Swap", systemImage: "arrow.triangle.2.circlepath") {
                    onSwap(WorkoutModeView.SwapTarget(block: rows[0].block, exercise: rows[0].exercise))
                }
                .tint(Plate.current.mark)
            }
        }
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy) {
        guard let current else { return }
        if reduceMotion {
            proxy.scrollTo(current, anchor: .center)
            return
        }
        withAnimation(.settle) { proxy.scrollTo(current, anchor: .center) }
        withAnimation(.tap.delay(0.22)) { highlightStrong = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(650))
            withAnimation(.reveal) { highlightStrong = false }
        }
    }
}

private struct SheetZoomTransition: ViewModifier {
    let sourceID: String
    let reduceMotion: Bool
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if reduceMotion {
            content.navigationTransition(.automatic)
        } else {
            content.navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        }
    }
}

/// A horizontal line, for the dashed "heard" underline.
struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        Path { $0.move(to: CGPoint(x: rect.minX, y: rect.midY)); $0.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)) }
    }
}

/// TKL-793: the set card's demo, full screen, with Slow; swipe down or ✕ goes back to the set.
struct FullScreenDemo: View {
    @Environment(\.dismiss) private var dismiss
    let slug: String
    let name: String
    @State private var slow = false
    @State private var drag: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            DemoClip(slug: slug, corner: 0, slow: slow) { HowToPhotos.photos(slug) }
                .offset(y: max(0, drag))
            VStack {
                HStack {
                    Text(name).font(.headline).foregroundStyle(.white)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.body.weight(.bold)).foregroundStyle(.white)
                            .frame(width: 44, height: 44).background(.white.opacity(0.2), in: .circle)
                    }
                    .accessibilityIdentifier("demo.close")
                    .accessibilityLabel("Close")
                }
                Spacer()
                Button { slow.toggle() } label: {
                    Label("Slow", systemImage: "tortoise.fill").font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .foregroundStyle(slow ? Color.black : Color.white)
                        .background(slow ? AnyShapeStyle(Color.white) : AnyShapeStyle(.white.opacity(0.2)), in: .capsule)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("demo.slow")
                .accessibilityLabel(slow ? "Normal speed" : "Slow")
            }
            .padding(16)
        }
        .contentShape(.rect)
        .gesture(DragGesture()
            .onChanged { drag = $0.translation.height }
            .onEnded { if $0.translation.height > 120 { dismiss() } else { withAnimation(.settle) { drag = 0 } } })
        .accessibilityAction(.escape) { dismiss() }
    }
}
