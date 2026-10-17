import SwiftUI

/// FIT-132: a logged session's thread with the coach, under the session's totals: their replies (which also arrive as
/// a notification) and the client's answers. Shown when coached, or when the day already has a thread.
struct CoachThread: View {
    @Environment(Account.self) private var account
    @Environment(Pro.self) private var pro
    let date: Date

    @State private var comments: [Cloud.Comment] = []
    @State private var text = ""
    @State private var sending = false
    @State private var failure: String?

    var body: some View {
        Group {
            if account.user != nil, !pro.coaches.isEmpty || !comments.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(comments) { comment in
                        let mine = comment.by == account.user?.uid
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mine ? "You" : comment.byName ?? "Your coach").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(comment.text)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(mine ? Color(.secondarySystemBackground) : Color(.systemBackground), in: .rect(cornerRadius: 12))
                    }
                    if !pro.coaches.isEmpty {
                        HStack(spacing: 8) {
                            TextField(comments.isEmpty ? "Tell your coach how it went" : "Reply", text: $text, axis: .vertical)
                                .lineLimit(1...4)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(.background, in: .rect(cornerRadius: 12))
                            Button { send() } label: {
                                if sending { ProgressView() } else { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                            }
                            .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityLabel("Send")
                        }
                    }
                    if let failure { Text(failure).font(.footnote).foregroundStyle(.red) }
                }
                .padding(.horizontal, 16)
            }
        }
        .task(id: account.user?.uid) {
            guard account.user != nil else { return }
            comments = (try? await Cloud.comments(day: SyncUnits.day(date))) ?? []
        }
    }

    private func send() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        sending = true
        failure = nil
        Task {
            defer { sending = false }
            do {
                comments.append(try await Cloud.postComment(day: SyncUnits.day(date), text: body))
                text = ""
            } catch {
                failure = "Couldn't send. Check your connection and try again."
            }
        }
    }
}
