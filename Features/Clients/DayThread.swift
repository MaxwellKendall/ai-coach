import SwiftUI
import SwiftData

/// FIT-298: one of a client's days to talk about: what they logged, their own words, the replies, and one to send
/// (FIT-132's replies, the dashboard's; a reply clears the note's flag).
struct DayThread: View {
    struct Ref: Hashable { var client: String, day: String }

    let ref: Ref
    @Environment(Account.self) private var account
    @Environment(Roster.self) private var roster
    @Query private var templates: [Template]
    @State private var text = ""
    @State private var sending = false
    @State private var problem: String?
    @FocusState private var focused: Bool

    private var names: [String: String] { Dictionary(templates.map { ($0.slug, $0.name) }, uniquingKeysWith: { a, _ in a }) }
    private var client: Roster.Client? { roster.clients.first { $0.id == ref.client } }
    private var date: Date { (try? Date.ISO8601FormatStyle().year().month().day().parse(ref.day)).map { $0 + 12 * 3600 } ?? .now }

    /// Laid out as a Messages conversation (author, 2026-11-10: "the message page looks really bad"): who it's with at
    /// the top, the day and its session as the conversation's first item, then bubbles, theirs left and yours right.
    var body: some View {
        ScrollView {
            if let client {
                let log = ClientDay.log(client.units, ref.day)
                let comments = client.comments.filter { $0.day == ref.day }
                let notes = ClientDay.notes(log)
                VStack(spacing: 0) {
                    Text(date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                        .font(.caption.weight(.semibold)).foregroundStyle(Color.inkMuted)
                        .padding(.bottom, 10)
                    session(log)
                    VStack(spacing: 4) {
                        ForEach(notes, id: \.self) { note in bubble(note, mine: false) }
                        ForEach(comments, id: \.at) { comment in bubble(comment.text, mine: comment.by == account.user?.uid) }
                    }
                    .padding(.top, 16)
                    if notes.isEmpty && comments.isEmpty {
                        Text("Write to \(first(client)) about \(date.formatted(.dateTime.weekday(.wide))). It shows on their Today and as a notification.")
                            .font(.subheadline).foregroundStyle(Color.inkMuted).multilineTextAlignment(.center)
                            .padding(.horizontal, 24).padding(.top, 8)
                    }
                    if let problem { Text(problem).font(.footnote).foregroundStyle(.red).padding(.top, 8) }
                }
                .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 16)
            }
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .screenBackground()
        .safeAreaBar(edge: .bottom) { composer }
        // The conversation has the whole screen, as in Messages: the composer sits where the tab bar was, and who it's
        // with is at the top, beside Back.
        .toolbarVisibility(.hidden, for: .tabBar)
        .toolbar {
            if let client {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        Avatar(client: client, size: 36)
                        Text(client.name).font(.caption.weight(.semibold))
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func first(_ client: Roster.Client) -> String { client.name.split(separator: " ").first.map(String.init) ?? client.name }

    /// The day's session as a compact card, like a link shared in a conversation: its name, then a line per lift; or
    /// what was planned, or a rest day.
    @ViewBuilder private func session(_ log: [SyncUnits.LogRow]) -> some View {
        let lifts = ClientDay.lifts(log, names: names)
        let plan = client.map { ClientDay.plan($0.units, ref.day).filter { $0.kind == .workout } } ?? []
        VStack(alignment: .leading, spacing: 8) {
            if !lifts.isEmpty {
                Label(ClientDay.sessionName(log) ?? "Logged", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Color.inkMuted)
                ForEach(Array(lifts.enumerated()), id: \.offset) { _, lift in
                    HStack(alignment: .firstTextBaseline) {
                        Text(lift.name).font(.subheadline.weight(.semibold))
                        Spacer(minLength: 8)
                        Text(lift.sets).font(.subheadline).foregroundStyle(Color.inkMuted).monospacedDigit()
                    }
                }
            } else if !plan.isEmpty {
                Label(ref.day < SyncUnits.day(.now) ? "Planned, not logged" : "Planned", systemImage: "calendar")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Color.inkMuted)
                // Each exercise once, in the plan's order.
                let slugs = plan.compactMap(\.template).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                Text(slugs.map { names[$0] ?? $0 }.joined(separator: ", ")).font(.subheadline.weight(.semibold))
            } else {
                Label("Rest day", systemImage: "moon").font(.subheadline.weight(.semibold)).foregroundStyle(Color.inkMuted)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surface, in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.inkFaint.opacity(0.4), lineWidth: 0.5))
    }

    /// A Messages bubble: no wider than three quarters of the screen, theirs grey on the left, yours in the accent.
    private func bubble(_ text: String, mine: Bool) -> some View {
        HStack {
            if mine { Spacer(minLength: 56) }
            Text(text).font(.body)
                .foregroundStyle(mine ? Plate.current.onAccent : Color.ink)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(mine ? Plate.current.accent : Color.fill, in: .rect(cornerRadius: 20))
            if !mine { Spacer(minLength: 56) }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message \(client?.name.split(separator: " ").first.map(String.init) ?? "them")", text: $text, axis: .vertical)
                .lineLimit(1...5).focused($focused)
                .padding(.vertical, 8)
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
        guard var client, let coach = account.user?.uid else { return }
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        sending = true
        Task {
            do {
                let comment = try await Cloud.postComment(words, day: ref.day, client: ref.client)
                client.comments.append(comment)
                roster.update(client, coach: coach, names: names)
                text = ""
                problem = nil
            } catch {
                problem = "Couldn’t send that. Try again."
            }
            sending = false
        }
    }
}
