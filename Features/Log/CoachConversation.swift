import SwiftUI

/// FIT-340: the client's whole conversation with their coach, every day either of them wrote on, as the coach sees it
/// (DayThread, FIT-331): the date over each day's messages, theirs grey on the left and mine on the right. What's sent
/// goes on today, which the coach sees in the same place.
struct CoachConversation: View {
    @Environment(Account.self) private var account
    @Environment(Pro.self) private var pro
    @Environment(\.scenePhase) private var scenePhase
    private var messages: CoachMessages { .shared }
    private var comments: [Cloud.Comment] { messages.comments }
    @State private var text = ""
    @State private var sending = false
    @State private var problem: String?

    private var coachName: String { pro.coaches.first?.name ?? "Your coach" }
    private var days: [String] { Array(Set(comments.map(\.day))).sorted() }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                // FIT-373: a failed load isn't an empty conversation.
                if messages.failed && comments.isEmpty {
                    ContentUnavailableView {
                        Label("Couldn’t load your messages", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text("Check your connection and try again.")
                    } actions: {
                        Button("Retry") { Task { await messages.refresh() } }.buttonStyle(.bordered)
                    }
                    .padding(.top, 40)
                } else if !messages.loaded && comments.isEmpty {
                    ProgressView().padding(.top, 40)
                } else if comments.isEmpty {
                    Text("Ask \(coachName) anything: a lift that felt off, a week that won’t fit, how a session went.")
                        .font(.subheadline).foregroundStyle(Color.inkMuted).multilineTextAlignment(.center).padding(.top, 40)
                }
                ForEach(days, id: \.self) { day in
                    VStack(spacing: 4) {
                        Text(Self.title(day)).font(.caption.weight(.semibold)).foregroundStyle(Color.inkMuted).padding(.bottom, 6)
                        ForEach(comments.filter { $0.day == day }.sorted { $0.at < $1.at }) { comment in
                            bubble(comment.text, mine: comment.by == account.user?.uid)
                        }
                    }
                }
                if messages.failed && !comments.isEmpty {
                    Text("Couldn’t check for new messages. Pull to try again.").font(.footnote).foregroundStyle(Color.inkMuted)
                }
                if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
            }
            .padding(.horizontal, 16).padding(.vertical, 16)
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .screenBackground()
        .safeAreaBar(edge: .bottom) { composer }
        .navigationTitle(coachName)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await messages.refresh() }
        .task { await messages.refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await messages.refresh() } } }
        // FIT-372: what's on screen has been read, a reply that arrives while it's open too (FIT-373: Push refreshes).
        .onChange(of: comments.count, initial: true) { messages.markRead() }
    }

    private func bubble(_ text: String, mine: Bool) -> some View {
        HStack {
            if mine { Spacer(minLength: 56) }
            Text(text).font(.body)
                .foregroundStyle(mine ? Plate.current.onAccent : Color.ink)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(mine ? Plate.current.accent : Color.fill, in: .rect(cornerRadius: 18))
            if !mine { Spacer(minLength: 56) }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message \(coachName)", text: $text, axis: .vertical).lineLimit(1...5).padding(.vertical, 8)
            let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            Button(action: send) {
                Image(systemName: "arrow.up").font(.body.weight(.bold)).foregroundStyle(Plate.current.onAccent)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge) // FIT-367: the arrow stays inside its 36 pt circle
                    .frame(width: 36, height: 36).background(Plate.current.accent.opacity(empty || sending ? 0.35 : 1), in: .circle)
            }
            .disabled(empty || sending)
            .accessibilityLabel("Send")
        }
        .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 6)
        .background(Color.surface, in: .rect(cornerRadius: 24))
        .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    private func send() {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        sending = true
        Task {
            do {
                messages.append(try await Cloud.postComment(day: SyncUnits.day(.now), text: words))
                text = ""
                problem = nil
            } catch {
                problem = "Couldn’t send. Check your connection and try again."
            }
            sending = false
        }
    }

    /// "Today", "Yesterday", "Sunday, Nov 8".
    static func title(_ day: String) -> String {
        guard let date = SyncUnits.date(ofKey: "log#\(day)") else { return day }
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }
}
