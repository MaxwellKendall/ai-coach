import SwiftUI

/// FIT-374: what didn't reach a client's phone, and sending it again or going back to what they have. On their week
/// and their progress (FIT-376), since either can make the change.
struct UnsentCard: View {
    let id: String
    let first: String
    let names: [String: String]
    var onRetry: (Roster.Sent) -> Void = { _ in }

    @Environment(Roster.self) private var roster
    @Environment(Account.self) private var account
    @State private var retrying = false

    var body: some View {
        if let changes = roster.unsent[id], !changes.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Label("Not sent to \(first)", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline).foregroundStyle(Color.ink)
                Text("\(ListFormatter.localizedString(byJoining: Self.labels(changes.keys))) didn’t reach their phone, which still has what was there before.")
                    .font(.subheadline).foregroundStyle(Color.inkMuted)
                HStack(spacing: 10) {
                    Button {
                        retrying = true
                        Task {
                            onRetry(await roster.retry(id, coach: account.user?.uid ?? "", names: names))
                            retrying = false
                        }
                    } label: { Text(retrying ? "Sending…" : "Retry").frame(maxWidth: .infinity) }
                        .buttonStyle(.primary).disabled(retrying)
                    Button { roster.discardUnsent(id, coach: account.user?.uid ?? "", names: names) } label: {
                        Text("Discard").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.secondary).disabled(retrying)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground()
        }
    }

    /// "Friday, Nov 13", "their profile", "a goal": each day once, then the rest; the first capitalized.
    static func labels(_ keys: some Collection<String>) -> [String] {
        let sorted = keys.sorted()
        var labels = sorted.filter { $0.hasPrefix("plan#") || $0.hasPrefix("log#") }
            .compactMap { $0.split(separator: "#").last.map { ClientScreen.dayTitle(String($0)) } }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        if sorted.contains("profile") { labels.append("their profile") }
        let goals = sorted.filter { $0.hasPrefix("goal#") }.count
        if goals > 0 { labels.append(goals == 1 ? "a goal" : "\(goals) goals") }
        if sorted.contains("checkin") { labels.append("the check-in day") }
        if let first = labels.first { labels[0] = first.prefix(1).uppercased() + first.dropFirst() }
        return labels
    }
}
