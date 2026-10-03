import SwiftUI

/// FIT-9 prototype artboard 1: one capsule above the tab bar. Type, or hold the mic; then check and Save.
/// Without Apple Intelligence it is just "+ Log".
struct LogBar: View {
    let voice: VoiceCapture
    /// What is being understood; the listening sheet shows it while the model works.
    @Binding var heard: String?
    let recipes: [Template]
    /// Hands over the cards to check.
    let onDraft: ([LogDraftEntry]) -> Void
    @State private var text = ""
    @State private var message: String?
    @State private var cancelled = false
    @GestureState private var pressing = false
    @FocusState private var focused: Bool

    static let border = Color(red: 0.89, green: 0.87, blue: 0.84)

    var body: some View {
        Group {
            if LanguageModel.isAvailable {
                HStack(spacing: 6) {
                    TextField("Log a meal, sleep, weight…", text: $text)
                        .focused($focused).submitLabel(.send).onSubmit { send(text) }
                        .padding(.leading, 18)
                    kinds { circle("plus", fill: Color(.secondarySystemBackground)) }
                    mic
                }
                .padding(.trailing, 6)
            } else {
                kinds { Label("Log", systemImage: "plus").font(.headline).frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
        }
        .frame(height: 56)
        .background(Color(.systemBackground), in: .capsule)
        .overlay(Capsule().strokeBorder(Self.border))
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 10)
        .background(Color(.secondarySystemBackground))
        .foregroundStyle(.primary)
        .alert("Log", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: { Text(message ?? "") }
        .onChange(of: voice.problem) { _, problem in if let problem { message = problem } }
        .onChange(of: pressing) { _, pressing in pressing ? startListening() : stopListening() }
        .sensoryFeedback(.start, trigger: voice.listening) { _, listening in listening }
    }

    /// The manual path: pick a kind, get one blank card on the same check sheet.
    private func kinds(@ViewBuilder label: () -> some View) -> some View {
        Menu {
            Button("Meal", systemImage: "fork.knife") { onDraft([.blank(.meal)]) }
            Button("Sleep", systemImage: "moon.fill") { onDraft([.blank(.sleep)]) }
            Button("Weight", systemImage: "scalemass") { onDraft([.blank(.bodyweight)]) }
            Button("Groceries", systemImage: "cart") { onDraft([.blank(.grocery)]) }
        } label: {
            label()
        }
        .accessibilityLabel("Log by hand")
    }

    private func circle(_ symbol: String, fill: Color) -> some View {
        Image(systemName: symbol).font(.system(size: 17, weight: .bold))
            .frame(width: 44, height: 44).background(fill, in: .circle)
    }

    /// Hold to talk; let go to check it, or slide away to cancel.
    private var mic: some View {
        circle("mic.fill", fill: RootView.accent)
            .foregroundStyle(Color(red: 0.08, green: 0.09, blue: 0.11))
            .gesture(DragGesture(minimumDistance: 0)
                .updating($pressing) { _, pressing, _ in pressing = true }
                .onChanged { cancelled = hypot($0.translation.width, $0.translation.height) > 120 })
            .accessibilityLabel("Hold to talk")
    }

    private func startListening() {
        guard heard == nil else { return }
        focused = false
        cancelled = false
        Task {
            await voice.start()
            // Released while the permission prompt was up.
            if !pressing { _ = voice.stop() }
        }
    }

    private func stopListening() {
        let said = voice.stop()
        if !cancelled { send(said) }
    }

    private func send(_ input: String) {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, heard == nil else { return }
        heard = input
        focused = false
        Task {
            defer { heard = nil }
            do {
                let result = LogResolver.resolve(try await LogParser.parse(input), recipes: recipes)
                if !result.entries.isEmpty {
                    text = ""
                    onDraft(result.entries)
                } else if result.mentionedWorkout {
                    message = "Workouts are logged from today's session card."
                } else {
                    message = "Couldn't find anything to log. Try the + button."
                }
            } catch {
                message = "Couldn't understand that. Try again, or use the + button."
            }
        }
    }
}

/// Prototype 5a: the dark sheet with the live transcript while holding, then "Understanding".
struct ListeningSheet: View {
    let voice: VoiceCapture
    let heard: String?
    @State private var started = Date.now

    private static let ink = Color(red: 0.08, green: 0.09, blue: 0.11)
    private static let muted = Color(red: 0.66, green: 0.68, blue: 0.72)

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(red: 0.05, green: 0.06, blue: 0.07).opacity(0.5).ignoresSafeArea()
            TimelineView(.animation) { context in
                let elapsed = context.date.timeIntervalSince(started)
                VStack(alignment: .leading, spacing: 16) {
                    Capsule().fill(Color(white: 0.24)).frame(width: 40, height: 5).frame(maxWidth: .infinity)
                    HStack {
                        HStack(spacing: 8) {
                            Circle().fill(RootView.accent).frame(width: 8, height: 8)
                                .opacity(0.65 + 0.35 * sin(elapsed * 5))
                            Text(heard == nil ? "LISTENING · ON THIS IPHONE" : "UNDERSTANDING · ON THIS IPHONE")
                        }
                        .font(.caption.weight(.semibold)).tracking(1)
                        Spacer()
                        Text(Duration.seconds(elapsed).formatted(.time(pattern: .minuteSecond)))
                            .font(.system(size: 18, weight: .semibold)).fontWidth(.condensed).monospacedDigit()
                    }
                    .foregroundStyle(Self.muted)
                    transcript
                        .font(.system(size: 22, weight: .medium))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    HStack(spacing: 4) {
                        ForEach(0..<28, id: \.self) { index in
                            Capsule().fill(RootView.accent)
                                .frame(width: 4, height: heard == nil ? 8 + 36 * abs(sin(elapsed * 4 + Double(index) * 0.7)) : 6)
                        }
                    }
                    .frame(maxWidth: .infinity).frame(height: 44)
                    VStack(spacing: 10) {
                        Image(systemName: "mic.fill").font(.system(size: 32))
                            .foregroundStyle(Self.ink)
                            .frame(width: 88, height: 88)
                            .background(RootView.accent, in: .circle)
                            .background(RootView.accent.opacity(0.18), in: .circle.inset(by: -10))
                        Text(heard == nil ? "Let go to check it · slide away to cancel" : "Working it out…")
                            .font(.footnote).foregroundStyle(Self.muted)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 34)
            .frame(height: 430)
            .foregroundStyle(.white)
            .background(Self.ink, in: UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28))
            .ignoresSafeArea(edges: .bottom)
        }
        .allowsHitTesting(false)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    /// Settled words in white, the last two still being recognised in grey.
    private var transcript: Text {
        let words = (heard ?? voice.transcript).split(separator: " ")
        if words.isEmpty { return Text("Say what you ate, how you slept…").foregroundStyle(Color(white: 0.42)) }
        let settled = heard == nil ? words.dropLast(2) : words[...]
        let pending = heard == nil ? words.suffix(2) : []
        return Text(settled.joined(separator: " ") + (settled.isEmpty ? "" : " "))
            + Text(pending.joined(separator: " ")).foregroundStyle(Color(white: 0.42))
    }
}
