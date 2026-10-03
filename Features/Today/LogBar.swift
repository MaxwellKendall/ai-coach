import SwiftUI

/// FIT-9: the one place to log. Type or hold the mic, check, Save. Without Apple Intelligence it is just "+ Log".
struct LogBar: View {
    /// Hands over the cards to check.
    let onDraft: ([LogDraftEntry]) -> Void
    let recipes: [Template]
    @State private var voice = VoiceCapture()
    @State private var text = ""
    @State private var understanding = false
    @State private var heard = ""
    @State private var message: String?
    @FocusState private var focused: Bool

    private var hasModel: Bool { LanguageModel.isAvailable }

    var body: some View {
        HStack(spacing: 8) {
            if hasModel {
                TextField("Log a meal, sleep, weight…", text: $text)
                    .focused($focused).submitLabel(.send).onSubmit { send(text) }
                    .padding(.horizontal, 14).frame(height: 44)
                    .background(.background, in: .capsule)
                plus
                mic
            } else {
                plus
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { if voice.listening || understanding { listening.offset(y: -64) } }
        .animation(.snappy, value: voice.listening)
        .alert("Log", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: { Text(message ?? "") }
        .onChange(of: voice.problem) { _, problem in if let problem { message = problem } }
    }

    /// The manual path: pick a kind, get one blank card on the same check sheet.
    private var plus: some View {
        Menu {
            Button("Meal", systemImage: "fork.knife") { onDraft([.blank(.meal)]) }
            Button("Sleep", systemImage: "moon.fill") { onDraft([.blank(.sleep)]) }
            Button("Weight", systemImage: "scalemass") { onDraft([.blank(.bodyweight)]) }
            Button("Groceries", systemImage: "cart") { onDraft([.blank(.grocery)]) }
        } label: {
            if hasModel {
                Image(systemName: "plus").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
                    .background(.background, in: .circle)
            } else {
                Label("Log", systemImage: "plus").font(.headline).frame(maxWidth: .infinity).frame(height: 44)
                    .background(.tint, in: .capsule).foregroundStyle(.white)
            }
        }
        .accessibilityLabel("Log")
    }

    private var mic: some View {
        Image(systemName: "mic.fill").font(.title3).foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(RootView.accent, in: .circle)
            .scaleEffect(voice.listening ? 1.2 : 1)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !voice.listening && !understanding { focused = false; Task { await voice.start() } } }
                .onEnded { _ in send(voice.stop()) })
            .accessibilityLabel("Hold to talk")
    }

    private var listening: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(understanding ? "UNDERSTANDING · ON THIS IPHONE" : "LISTENING · ON THIS IPHONE")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(understanding ? heard : voice.transcript.isEmpty ? "Say what you ate, how you slept…" : voice.transcript)
                .font(.title3.weight(.medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(red: 0.08, green: 0.09, blue: 0.11), in: .rect(cornerRadius: 22))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
    }

    private func send(_ input: String) {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !understanding else { return }
        understanding = true
        heard = input
        focused = false
        Task {
            defer { understanding = false }
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
