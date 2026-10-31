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

    var body: some View {
        ScrollView {
            if let client {
                let log = ClientDay.log(client.units, ref.day)
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(date.formatted(.dateTime.weekday(.wide))).font(.display(28))
                        Text([client.name, ClientDay.sessionName(log)].compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(Color.inkMuted)
                    }
                    let lifts = ClientDay.lifts(log, names: names)
                    if !lifts.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(Array(lifts.enumerated()), id: \.offset) { index, lift in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(lift.name).font(.headline)
                                    Spacer(minLength: 8)
                                    Text(lift.sets).font(.subheadline).foregroundStyle(Color.inkMuted).monospacedDigit()
                                }
                                .padding(.vertical, 14)
                                if index < lifts.count - 1 { Divider() }
                            }
                        }
                        .padding(.horizontal, 20)
                        .cardBackground()
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(ClientDay.notes(log), id: \.self) { note in bubble(note, by: client.name, mine: false) }
                        ForEach(client.comments.filter { $0.day == ref.day }, id: \.at) { comment in
                            bubble(comment.text, by: comment.by == account.user?.uid ? "You" : comment.byName ?? client.name,
                                   mine: comment.by == account.user?.uid)
                        }
                    }
                    if let problem { Text(problem).font(.subheadline).foregroundStyle(Color.inkMuted) }
                }
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 24)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .screenBackground()
        .safeAreaBar(edge: .bottom) { composer }
    }

    private func bubble(_ text: String, by: String, mine: Bool) -> some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
            Text(text).font(.body)
                .foregroundStyle(mine ? Plate.current.onAccent : Color.ink)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(mine ? Plate.current.accent : Color.surface, in: .rect(cornerRadius: 18))
            Text(by).font(.footnote).foregroundStyle(Color.inkMuted).padding(.horizontal, 4)
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Reply to \(client?.name.split(separator: " ").first.map(String.init) ?? "them")", text: $text, axis: .vertical)
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
