import Foundation
import Observation

/// FIT-298: coach mode's clients, each with their units, the replies on their days and this week's triage. Kept for
/// the session; Clients refreshes it when it appears and on a pull.
@MainActor @Observable
final class Roster {
    struct Client: Codable, Identifiable, Sendable {
        var person: Cloud.Person
        /// Every unit they have, key → body (FIT-126).
        var units: [String: String]
        var comments: [Triage.Comment]
        var week: Triage.Week

        var id: String { person.uid }
        /// When they last logged anything, from their log units' rows.
        var lastLogged: Date? {
            units.keys.filter { $0.hasPrefix("log#") }.max().flatMap { key in
                ClientDay.log(units, String(key.dropFirst(4))).map(\.at).max()
            }
        }
        var name: String { person.name ?? "Client" }
        var initials: String {
            let words = (person.name ?? "?").split(separator: " ").prefix(2)
            return words.compactMap(\.first).map(String.init).joined().uppercased()
        }
    }

    /// FIT-298: someone who came in by "I'm a coach", or has clients: the Clients tab shows.
    static let coachingKey = "coaching"

    private(set) var clients: [Client] = []
    /// FIT-339: invites sent and not used yet.
    private(set) var invites: [Cloud.ClientInvite] = []
    private(set) var loaded = false
    /// The coach `clients` belong to.
    private var loadedFor: String?
    var problem: String?

    /// Signed out, or before the first load, none; `clients` for a preview.
    init(clients: [Client] = [], invites: [Cloud.ClientInvite] = []) {
        self.invites = invites
        self.clients = Self.byName(clients)
        loaded = !clients.isEmpty
    }

    // MARK: The last list, shown at once while a fresh one loads

    struct Saved: Codable {
        var coach: String
        var clients: [Client]
        var invites: [Cloud.ClientInvite]
    }

    /// In Caches: the system may clear it, and it's only ever a head start.
    static let savedURL = URL.cachesDirectory.appending(path: "roster.json")

    /// The roster as last loaded, for the coach who loaded it; none if there's nothing saved.
    static func restored(from url: URL = savedURL) -> Roster {
        let roster = Roster()
        guard let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return roster }
        roster.clients = byName(saved.clients)
        roster.invites = saved.invites
        roster.loadedFor = saved.coach
        roster.loaded = true
        return roster
    }

    private func save(to url: URL = savedURL) {
        guard let coach = loadedFor else { return }
        try? JSONEncoder().encode(Saved(coach: coach, clients: clients, invites: invites)).write(to: url, options: [.atomic, .completeFileProtection])
    }

    var needsYou: [Client] { clients.filter { $0.week.need != nil } }

    // MARK: FIT-338: unread

    /// When the coach last opened each client's conversation, on this phone; a client seen for the first time starts
    /// now, so only what comes after counts.
    private var seen: [String: Date] = (UserDefaults.standard.dictionary(forKey: "coachSeen") as? [String: Double] ?? [:])
        .mapValues { Date(timeIntervalSince1970: $0) }

    /// Clients with something new from them.
    var unread: Int { clients.filter { unread($0) > 0 }.count }

    func unread(_ client: Client) -> Int {
        Self.unread(client.units, comments: client.comments, from: client.id, since: seen[client.id] ?? .now)
    }

    /// FIT-339: a client gone from the list, once the coach has removed them.
    func remove(_ id: String) {
        clients.removeAll { $0.id == id }
        save()
    }

    func cancel(_ code: String) async throws {
        try await Cloud.cancelInvite(code)
        invites.removeAll { $0.code == code }
        save()
    }

    func markSeen(_ id: String, at date: Date = .now) {
        seen[id] = date
        UserDefaults.standard.set(seen.mapValues(\.timeIntervalSince1970), forKey: "coachSeen")
    }

    /// What a client wrote after `since`: their replies, their sessions' notes and their check-ins' notes. FIT-344: a
    /// weekly check-in counts, words or not.
    static func unread(_ units: [String: String], comments: [Triage.Comment], from client: String, since: Date) -> Int {
        var count = 0
        for comment in comments where comment.by == client && date(comment.at) > since { count += 1 }
        for key in units.keys where key.hasPrefix("log#") {
            for row in ClientDay.log(units, String(key.dropFirst(4))) where row.at > since {
                let said = !row.note.trimmingCharacters(in: .whitespaces).isEmpty
                let summary = row.kind == .workout && row.template == nil
                if (said && (summary || row.kind == .bodyweight || row.kind == .sleep)) || row.kind == .checkin { count += 1 }
            }
        }
        return count
    }

    /// A reply's time, with or without fractional seconds.
    private static func date(_ at: String) -> Date {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(at) { return date }
        return (try? Date.ISO8601FormatStyle().parse(at)) ?? .distantPast
    }

    /// FIT-331: A–Z, as the author asked; each row's flag still says who needs you.
    static func byName(_ clients: [Client]) -> [Client] {
        clients.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Every client, then their units and replies, A–Z.
    func refresh(coach: String?, names: [String: String]) async {
        #if DEBUG
        if Self.sample { return }
        #endif
        guard let coach else {
            clients = []
            invites = []
            loadedFor = nil
            loaded = true
            try? FileManager.default.removeItem(at: Self.savedURL)
            return
        }
        // Another account's list, or the signed-out one, isn't this coach's: loading, not "Invite your first client".
        if coach != loadedFor { clients = []; invites = []; loaded = false }
        do {
            let people = try await Cloud.myClients()
            if !people.isEmpty { UserDefaults.standard.set(true, forKey: Self.coachingKey) }
            let today = SyncUnits.day(.now)
            // All at once: one after another, ten clients took 13 s on prod.
            let fetched = try await withThrowingTaskGroup(of: (Int, [String: String], [Triage.Comment]).self) { group in
                for (index, person) in people.enumerated() {
                    group.addTask { (index, try await Cloud.units(of: person.uid), try await Cloud.comments(of: person.uid)) }
                }
                var fetched: [Int: ([String: String], [Triage.Comment])] = [:]
                for try await (index, units, comments) in group { fetched[index] = (units, comments) }
                return fetched
            }
            let loaded = people.enumerated().map { index, person in
                let (units, comments) = fetched[index]!
                return Client(person: person, units: units, comments: comments,
                              week: Triage.week(units, comments: comments, names: names, coach: coach, today: today))
            }
            clients = Self.byName(loaded)
            loadedFor = coach
            // A server without myInvites yet (before FIT-339's deploy) just shows none.
            invites = (try? await Cloud.myInvites()) ?? []
            for client in loaded where seen[client.id] == nil { markSeen(client.id) }
            save()
            problem = nil
        } catch {
            problem = "Couldn’t load your clients. Pull to try again."
        }
        self.loaded = true
    }

    /// A client as just changed here (a reply, an edited day), without fetching everyone again.
    func update(_ client: Client, coach: String, names: [String: String]) {
        var client = client
        client.week = Triage.week(client.units, comments: client.comments, names: names, coach: coach, today: SyncUnits.day(.now))
        if let index = clients.firstIndex(where: { $0.id == client.id }) { clients[index] = client }
        clients = Self.byName(clients)
        save()
    }
}
