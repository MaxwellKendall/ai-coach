import Foundation
import Observation

/// FIT-298: coach mode's clients, each with their units, the replies on their days and this week's triage. Kept for
/// the session; Clients refreshes it when it appears and on a pull.
@MainActor @Observable
final class Roster {
    struct Client: Identifiable, Sendable {
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
    private(set) var loaded = false
    /// The coach `clients` belong to.
    private var loadedFor: String?
    var problem: String?

    /// Signed out, or before the first load, none; `clients` for a preview.
    init(clients: [Client] = []) {
        self.clients = Self.byName(clients)
        loaded = !clients.isEmpty
    }

    var needsYou: [Client] { clients.filter { $0.week.need != nil } }

    /// FIT-331: A–Z, as the author asked; each row's flag still says who needs you.
    static func byName(_ clients: [Client]) -> [Client] {
        clients.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Every client, then their units and replies, A–Z.
    func refresh(coach: String?, names: [String: String]) async {
        #if DEBUG
        if Self.sample { return }
        #endif
        guard let coach else { clients = []; loaded = true; return }
        // Another account's list, or the signed-out one, isn't this coach's: loading, not "Invite your first client".
        if coach != loadedFor { clients = []; loaded = false }
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
    }
}
