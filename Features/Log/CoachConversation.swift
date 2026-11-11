import SwiftUI

/// FIT-340: the client's whole conversation with their coach, every day either of them wrote on, as the coach sees it
/// (DayThread, FIT-331): the date over each day's messages, theirs grey on the left and mine on the right. What's sent
/// goes on today, which the coach sees in the same place.
struct CoachConversation: View {
    @Environment(Account.self) private var account
    @Environment(Pro.self) private var pro
    @State private var comments: [Cloud.Comment] = []
    @State private var loaded = false
    @State private var text = ""
    @State private var sending = false
    @State private var problem: String?

    private var coachName: String { pro.coaches.first?.name ?? "Your coach" }
    private var days: [String] { Array(Set(comments.map(\.day))).sorted() }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                if loaded && comments.isEmpty {
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
        .task {
            comments = (try? await Cloud.comments()) ?? []
            loaded = true
        }
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
                comments.append(try await Cloud.postComment(day: SyncUnits.day(.now), text: words))
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
