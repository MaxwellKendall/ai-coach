import SwiftUI
import SwiftData

/// FIT-103: a conversation with the coach about this week or the program. Each answer may leave changes in one draft,
/// shown as a card under the conversation; nothing changes until Apply (principle 7), and Apply has Undo. It's Pro
/// (FIT-120): without it, sending shows the offer.
struct CoachChatView: View {
    let scope: CoachChat.Scope
    @Environment(\.modelContext) private var context
    @Environment(Account.self) private var account
    @Environment(Pro.self) private var pro

    struct Message: Identifiable, Equatable {
        let id = UUID()
        var coach: Bool
        var text: String
    }

    @State private var messages: [Message] = []
    @State private var draft = CoachChat.Draft()
    @State private var last: CoachChat.Turn?
    @State private var text = ""
    @FocusState private var typing: Bool
    @State private var working = false
    @State private var voice = VoiceCapture()
    @State private var toast: Toast?

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        bubble(Message(coach: true, text: intro))
                        if messages.isEmpty { suggestions }
                        ForEach(messages) { bubble($0) }
                        if working {
                            HStack(spacing: 8) { ProgressView(); Text("Thinking…").foregroundStyle(.secondary) }
                                .font(.subheadline).padding(.leading, 4)
                        }
                        if !draft.isEmpty { draftCard }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: messages) { withAnimation(.snappy) { scroll.scrollTo("end", anchor: .bottom) } }
                .onChange(of: draft) { withAnimation(.snappy) { scroll.scrollTo("end", anchor: .bottom) } }
            }
            inputBar
        }
        .overlay(alignment: .bottom) { ToastView(toast: $toast).padding(.bottom, 70) }
        .overlay {
            if voice.listening { ListeningVeil(voice: voice, working: nil, prompt: suggestionsList.first.map { "“\($0)”" } ?? "") { typing = true } }
        }
        .animation(.snappy, value: messages)
        .animation(.snappy, value: draft)
        .animation(.snappy, value: working)
    }

    private var intro: String {
        scope == .program
            ? "Ask me about your program, or tell me what should change: days, session length, the end date, a trip."
            : "Ask me about this week, or tell me what should change: move a session, less time, a sore spot, a swap."
    }

    private var suggestionsList: [String] {
        scope == .program
            ? ["How is my program built?", "I’m traveling Nov 9 to 20", "Train 4 days a week", "Push my end date back 2 weeks"]
            : ["Why this week’s sessions?", "Move tomorrow to the day after", "I only have 30 minutes Thursday", "My shoulder hurts"]
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(suggestionsList, id: \.self) { item in
                Button { send(item) } label: {
                    Text(item).font(.subheadline)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .overlay(Capsule().strokeBorder(Color(.separator)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 4)
    }

    private func bubble(_ message: Message) -> some View {
        HStack {
            if !message.coach { Spacer(minLength: 48) }
            Text(message.text)
                .font(.body)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .foregroundStyle(message.coach ? Color.primary : Color(.systemBackground))
                .background(message.coach ? Color(.secondarySystemBackground) : Color.primary, in: .rect(cornerRadius: 18))
                .textSelection(.enabled)
            if message.coach { Spacer(minLength: 48) }
        }
    }

    private var draftCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Changes").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            ForEach(Array(draft.lines.enumerated()), id: \.offset) { _, line in
                Label(line, systemImage: "arrow.right").font(.subheadline)
            }
            HStack {
                Button("Discard") { draft = CoachChat.Draft() }.foregroundStyle(.secondary)
                Spacer()
                Button { apply() } label: {
                    Text("Apply").font(.headline).padding(.horizontal, 22).padding(.vertical, 10)
                        .foregroundStyle(Color(.systemBackground)).background(Color.primary, in: .capsule)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
        }
        .padding(16)
        .background(.background, in: .rect(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color(.separator)))
    }

    private var inputBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                // One line, so Return sends.
                TextField("Tell your coach…", text: $text)
                    .focused($typing)
                    .submitLabel(.send)
                    .onSubmit { send(text) }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 20))
                if text.isEmpty {
                    MicButton(voice: voice, compact: true) { send($0) }
                } else {
                    Button { send(text) } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                        .accessibilityLabel("Send")
                }
            }
            if !pro.active {
                Text("Talking with your coach is part of Pro, free for \(Pro.trialDays) days.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .disabled(working)
    }

    // MARK: Acting

    private func send(_ said: String) {
        let said = said.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty, !working else { return }
        guard pro.active else {
            pro.paywall = true
            return
        }
        text = ""
        messages.append(Message(coach: false, text: said))
        guard let coachContext = Planner.coachContext(in: context) else {
            messages.append(Message(coach: true, text: "Finish setting up your program first, then I can help with it."))
            return
        }
        working = true
        Task {
            defer { working = false }
            do {
                let reply = try await CoachChat.respond(said, scope: scope, context: coachContext, draft: draft, last: last,
                                                        model: LanguageModel.programs(signedIn: account.user != nil))
                let answer = reply.text.isEmpty ? (reply.draft.isEmpty ? "Could you say that another way?" : "Here’s the change.") : reply.text
                messages.append(Message(coach: true, text: answer))
                draft = reply.draft
                last = CoachChat.Turn(said: said, reply: answer)
            } catch {
                messages.append(Message(coach: true, text: "I couldn’t answer that just now. Try again in a moment."))
            }
        }
    }

    private func apply() {
        let applying = draft
        guard let undo = try? Planner.applyCoach(applying, in: context) else {
            messages.append(Message(coach: true, text: "That didn’t save. Try Apply again."))
            return
        }
        draft = CoachChat.Draft()
        messages.append(Message(coach: true, text: "Done. " + applying.lines.joined(separator: " ")))
        toast = Toast(text: "Applied") {
            undo()
            draft = applying
        }
        // New program settings: the coach designs the rest of the week again (Today shows it planning).
        if applying.week == nil {
            let model = LanguageModel.programs(signedIn: account.user != nil)
            Task { await Planner.design(in: context, model: model) }
        }
    }
}
