import SwiftUI
import SwiftData

/// The workout (FIT-32, FIT-35): a deck of cards, one per set, each followed by its rest. Throwing a set to the
/// left logs it as shown and starts its rest; up skips a set or a rest; down unlogs a logged set; right brings
/// the last card back. Tap a number to change it. The list button shows the whole session. The last card is
/// the log: Save writes it.
struct WorkoutModeView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \LogEntry.timestamp) private var entries: [LogEntry]
    @Query private var templates: [Template]
    @Query private var profiles: [Profile]
    @State var draft: WorkoutDraft
    var onSaved: () -> Void = {}
    @State private var startedAt = Date.now
    @State private var page = 0
    @State private var peeking = false
    @State private var editing: Field?
    @State private var rest: Rest?
    @State private var restsFinished = 0
    @State private var quitting = false
    @State private var voice = VoiceCapture()
    @State private var working: String?
    @State private var talked = false
    @State private var toast: Toast?
    @State private var message: String?

    /// The running rest, on its card.
    struct Rest: Equatable {
        var ends: Date
        var total: TimeInterval
        var page: Int
    }

    /// The number being changed: a card's reps (or time) or its load.
    struct Field: Equatable {
        var page: Int
        var load: Bool
    }

    private var names: [String: String] {
        Dictionary(templates.map { ($0.slug, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        let cards = draft.cards
        let names = names
        VStack(spacing: 0) {
            topBar
            segments.padding(.horizontal, 22).padding(.top, 8)
            SwipeDeck(index: $page, count: cards.count + 1, vertical: { vertical($0, $1, cards: cards) },
                      hint: { hint($0, $1, cards: cards) }, swiped: { swiped(from: $0, $1, cards: cards) }) { index in
                if index == cards.count {
                    finishCard(names: names)
                } else {
                    switch cards[index] {
                    case .set(let line): setCard(line, index: index, cards: cards, names: names)
                    case .rest(let seconds): restCard(index: index, seconds: seconds, cards: cards, names: names)
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
            micArea(onFinish: page == cards.count).frame(height: 104)
        }
        .background(Color(.systemBackground))
        .onChange(of: page) { editing = nil }
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
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .confirmationDialog("Leave this workout?", isPresented: $quitting, titleVisibility: .visible) {
            Button("Discard sets", role: .destructive) { dismiss() }
        } message: {
            Text("Nothing is saved until you press Save on the last card.")
        }
        .sheet(isPresented: $peeking) { peek }
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
                                if let index = cards.firstIndex(of: .set(line)) { withAnimation(.snappy) { page = index } }
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
        let field = editing?.page == index ? editing : nil
        let next = nextSet(after: index, in: cards).map { draft.rows[$0[0]] }
        let hint = done ? "Swipe down to unlog" : next == nil ? "Swipe to finish" : next!.block != first.block ? "Swipe · \(names[next!.exercise] ?? next!.exercise)" : "Swipe when done"
        let values = rows.map { Coach.number($0.value ?? 0) }.joined(separator: "+")
        let loads = rows.compactMap(\.load).reduce(into: [Double]()) { if !$0.contains($1) { $0.append($1) } }
        let load = first.loadMetric == nil ? nil : loads.map(Coach.number).joined(separator: "/")
        let size: CGFloat = values.count + (load?.count ?? 0) > 6 ? 68 : 96
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Set \(first.round + 1) of \(rounds)\(exercises.count > 1 ? " · superset" : "")")
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if done {
                    Label("Logged", systemImage: "checkmark.circle.fill").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            Text(exercises.map { names[$0] ?? $0 }.joined(separator: " + "))
                .font(.system(size: 30, weight: .bold)).tracking(-0.4).padding(.top, 4)
                .lineLimit(2).minimumScaleFactor(0.7)
            Spacer(minLength: 12)
            VStack(spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    number(values, size: size, on: field?.load == false, heard: rows.contains(where: \.heard),
                           label: "\(values) \(unit(first, plain: true)). Change") {
                        editing = field?.load == false ? nil : Field(page: index, load: false)
                    }
                    if let load {
                        Text("×").font(.system(size: size * 0.3)).foregroundStyle(.tertiary)
                        number(load, size: size, on: field?.load == true, heard: false, label: "\(load) pounds. Change") {
                            editing = field?.load == true ? nil : Field(page: index, load: true)
                        }
                    }
                }
                .lineLimit(1).minimumScaleFactor(0.5)
                Text(unit(first, pair: exercises.count > 1)).font(.subheadline).foregroundStyle(.secondary)
                if let field {
                    HStack(spacing: 14) {
                        round("minus", field.load ? "5 lb less" : "Less") { draft.adjust(line, load: field.load, by: -1) }
                        Text(field.load ? "5 lb" : first.metric == "reps" ? "reps" : "5 \(SetRow.units[first.metric] ?? "")")
                            .font(.subheadline).foregroundStyle(.secondary).frame(minWidth: 72)
                        round("plus", field.load ? "5 lb more" : "More") { draft.adjust(line, load: field.load, by: 1) }
                    }
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .frame(maxWidth: .infinity)
            .animation(.snappy, value: field)
            Spacer(minLength: 12)
            HStack(alignment: .firstTextBaseline) {
                if first.round == 0, exercises.count == 1, let last = lastTime(exercises[0]) {
                    Text(last).foregroundStyle(.tertiary)
                }
                Spacer()
                Text(hint).foregroundStyle(.tertiary).lineLimit(1)
            }
            .font(.subheadline)
        }
        .padding(EdgeInsets(top: 26, leading: 24, bottom: 22, trailing: 24))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 30))
        .clipShape(.rect(cornerRadius: 30))
        .accessibilityAction(named: "Unlog") { if done { unlog(line) } }
    }

    /// Up skips a set or a rest; down unlogs a logged set.
    private func vertical(_ index: Int, _ edge: VerticalEdge, cards: [WorkoutDraft.Card]) -> CardThrow? {
        guard cards.indices.contains(index) else { return nil }
        if edge == .top { return .off }
        if case .set(let line) = cards[index], line.allSatisfy({ draft.rows[$0].done }) { return .back }
        return nil
    }

    /// What a swipe will do: green logs, blue skips, orange unlogs, gray just moves.
    private func hint(_ index: Int, _ swipe: CardSwipe, cards: [WorkoutDraft.Card]) -> SwipeHint? {
        guard cards.indices.contains(index) else { return swipe == .back ? SwipeHint("Back") : nil }
        switch (cards[index], swipe) {
        case (.set(let line), .next):
            return line.allSatisfy({ draft.rows[$0].done }) ? SwipeHint("Next") : SwipeHint("Log set", symbol: "checkmark", tint: .green)
        case (.set, .up):
            let restAfter = if cards.indices.contains(index + 1), case .rest = cards[index + 1] { true } else { false }
            return SwipeHint("Skip set", symbol: "forward.end", tint: .blue, to: restAfter ? index + 2 : nil)
        case (.set, .down): return SwipeHint("Unlog", symbol: "arrow.uturn.backward", tint: .orange)
        case (.rest, .next): return SwipeHint("Next set")
        case (.rest, .up): return SwipeHint("Skip rest", symbol: "forward.end", tint: .blue)
        case (_, .back): return SwipeHint("Back")
        default: return nil
        }
    }

    /// Swiping a set on logs it as shown and starts its rest. Swiping it up skips it, and its rest with it.
    /// Leaving a rest forward ends it; going back to look at the set keeps it running.
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

    private func number(_ text: String, size: CGFloat, on: Bool, heard: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: size, weight: .semibold, design: .rounded)).tracking(-2).monospacedDigit()
                .contentTransition(.numericText())
                .overlay(alignment: .bottom) {
                    if on {
                        Capsule().frame(height: 3).offset(y: 8)
                    } else if heard {
                        Line().stroke(style: StrokeStyle(lineWidth: 3, dash: [6, 5])).frame(height: 3)
                            .foregroundStyle(.tertiary).offset(y: 8)
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// "reps × lb", "reps each × lb/hand", "seconds".
    private func unit(_ row: SetRow, pair: Bool = false, plain: Bool = false) -> String {
        let value = row.metric == "reps" ? (pair ? "reps each" : "reps") : row.metric == "duration_s" ? "seconds" : SetRow.units[row.metric] ?? ""
        guard !plain, let loadMetric = row.loadMetric else { return value }
        return "\(value) × \(SetRow.units[loadMetric] ?? "lb")"
    }

    private func round(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button { withAnimation(.snappy, action) } label: {
            Image(systemName: symbol).font(.title3.weight(.medium)).frame(width: 56, height: 56)
                .background(Color(.systemBackground), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
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

    /// The rest after a set: a countdown with −10s, +10s and Skip. It runs when you arrive by logging the set;
    /// swiping on, or up, skips it.
    private func restCard(index: Int, seconds: TimeInterval, cards: [WorkoutDraft.Card], names: [String: String]) -> some View {
        let active = rest?.page == index ? rest : nil
        let next = nextSet(after: index, in: cards).map { $0.map { draft.rows[$0] } }
        let skip = { withAnimation(.snappy) { rest = nil; page = index + 1 } }
        let before = set(at: index - 1, in: cards) ?? []
        let done = before.map { draft.rows[$0] }
        return VStack(alignment: .leading, spacing: 0) {
            // The rest belongs to the set before it: talk now and it's that set you're changing.
            if let first = done.first {
                HStack {
                    Text("Rest after set \(first.round + 1)").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    if done.allSatisfy(\.done) {
                        Label("Logged", systemImage: "checkmark.circle.fill").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                Text(Self.names(done, names)).font(.title3.weight(.semibold)).lineLimit(1).padding(.top, 4)
                Text(Self.dose(done)).font(.title3).foregroundStyle(.secondary).monospacedDigit()
                    .overlay(alignment: .bottom) {
                        if done.contains(where: \.heard) {
                            Line().stroke(style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])).foregroundStyle(.tertiary)
                                .frame(height: 1.5).offset(y: 3)
                        }
                    }
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 12)
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                let left = active.map { max(0, $0.ends.timeIntervalSince(context.date)) } ?? seconds
                VStack(spacing: 0) {
                    Text(Duration.seconds(left.rounded(.up)).formatted(.time(pattern: .minuteSecond)))
                        .font(.system(size: 96, weight: .semibold, design: .rounded)).tracking(-2).monospacedDigit()
                        .foregroundStyle(active == nil ? .tertiary : .primary)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color(.separator))
                            Capsule().fill(.primary).frame(width: proxy.size.width * left / max(active?.total ?? seconds, 1))
                        }
                    }
                    .frame(width: 200, height: 4).padding(.top, 8)
                    HStack(spacing: 8) {
                        Button("−10s") {
                            if left > 10 { rest?.ends -= 10 } else { skip() }
                        }
                        .accessibilityLabel("10 seconds less")
                        Button("+10s") {
                            if let active { rest?.ends += 10; rest?.total = max(active.total, left + 10) }
                            else { rest = Rest(ends: .now + seconds + 10, total: seconds + 10, page: index) }
                        }
                        .accessibilityLabel("10 seconds more")
                        Button("Skip", action: skip)
                    }
                    .buttonStyle(RestButton())
                    .padding(.top, 22)
                    .opacity(active == nil ? 0 : 1)
                    .disabled(active == nil)
                }
                .frame(maxWidth: .infinity)
            }
            Spacer(minLength: 12)
            if let next {
                Text("Next · set \(next[0].round + 1)").font(.subheadline).foregroundStyle(.secondary)
                Text(Self.names(next, names)).font(.title3.weight(.semibold)).lineLimit(1).padding(.top, 2)
                Text(Self.dose(next)).font(.title3).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack {
                Spacer()
                Text("Swipe up to skip").font(.subheadline).foregroundStyle(.tertiary)
            }
            .padding(.top, 8)
        }
        .padding(EdgeInsets(top: 26, leading: 24, bottom: 22, trailing: 24))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 30))
        .contentShape(.rect(cornerRadius: 30))
    }

    /// "Back Squat", or "Row + Bench" for a superset round.
    static func names(_ rows: [SetRow], _ names: [String: String]) -> String {
        rows.map(\.exercise).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .map { names[$0] ?? $0 }.joined(separator: " + ")
    }

    /// "5 × 150", "30 s", "10+10 × 50/40".
    static func dose(_ rows: [SetRow]) -> String {
        guard let first = rows.first else { return "" }
        let values = rows.map { Coach.number($0.value ?? 0) }.joined(separator: "+")
            + (first.metric == "reps" ? "" : " " + (SetRow.units[first.metric] ?? ""))
        let loads = rows.compactMap(\.load).reduce(into: [Double]()) { if !$0.contains($1) { $0.append($1) } }
        return loads.isEmpty ? values : values + " × " + loads.map(Coach.number).joined(separator: "/")
    }

    private struct RestButton: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label.font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).frame(height: 36)
                .background(Color(.systemBackground), in: .capsule)
                .opacity(configuration.isPressed ? 0.6 : 1)
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
        .padding(EdgeInsets(top: 26, leading: 24, bottom: 22, trailing: 24))
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
