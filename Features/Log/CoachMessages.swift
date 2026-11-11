import Foundation
import Observation

/// FIT-372, FIT-373: a coached client's conversation with their coach, shared by Today's Messages icon (its unread dot)
/// and Messages itself, so a reply fetched for one shows in the other.
@MainActor @Observable
final class CoachMessages {
    static let shared = CoachMessages()

    private(set) var comments: [Cloud.Comment] = []
    private(set) var loaded = false
    /// The last fetch failed; what was fetched before stays.
    private(set) var failed = false
    /// The newest message read on this phone. Kept here, not on the server, so it clears on the phone it was read on.
    private var readAt: Date? = UserDefaults.standard.object(forKey: readKey) as? Date

    private static let readKey = "messages.readAt"

    func refresh() async {
        #if DEBUG
        // `-coach Sam -unread YES`: a message from Sam not yet read, to look at the dot on a simulator.
        if UserDefaults.standard.bool(forKey: "unread") {
            if comments.isEmpty {
                comments = [Cloud.Comment(day: SyncUnits.day(.now), at: Date.now.formatted(.iso8601), by: "debug-coach", byName: "Sam",
                                          text: "Keep the bar speed up today. Stop the top set at RPE 8.")]
            }
            loaded = true
            return
        }
        #endif
        do {
            comments = try await Cloud.comments()
            failed = false
        } catch {
            failed = true
        }
        loaded = true
    }

    func unread(me: String?) -> Bool { Self.unread(comments, me: me, readAt: readAt) }

    /// Everything fetched so far has been seen.
    func markRead() {
        guard let newest = comments.map({ Self.date($0.at) }).max(), newest > readAt ?? .distantPast else { return }
        readAt = newest
        UserDefaults.standard.set(newest, forKey: Self.readKey)
    }

    func append(_ comment: Cloud.Comment) {
        comments.append(comment)
    }

    /// A message from anyone but me, newer than the last one read here. Never read here, any of theirs is.
    nonisolated static func unread(_ comments: [Cloud.Comment], me: String?, readAt: Date?) -> Bool {
        comments.contains { $0.by != me && date($0.at) > readAt ?? .distantPast }
    }

    /// A message's time, with or without fractional seconds.
    nonisolated static func date(_ at: String) -> Date {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(at) { return date }
        return (try? Date.ISO8601FormatStyle().parse(at)) ?? .distantPast
    }
}
