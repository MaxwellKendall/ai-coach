import Foundation

/// FIT-298: coach mode's calls, the dashboard's own (web/src/sync.ts, FIT-130/132): a coach's clients, an invite, a
/// client's units and the replies on their days, and a changed day written back to them.
extension Cloud {
    struct ClientInvite: Decodable, Equatable, Sendable {
        var code: String
        var url: String
    }

    private struct ClientUnit: Decodable, Sendable {
        var key: String
        var deleted: Bool
        var body: String?
    }

    private struct ClientPage: Decodable, Sendable {
        var units: [ClientUnit]
        var cursor: String?
        var more: Bool
    }

    private struct Pushed: Decodable, Sendable {
        struct Key: Decodable, Sendable { var key: String }
        var rejected: [Key]
    }

    @MainActor static func myClients() async throws -> [Person] {
        try await run("query { myClients { uid name since } }", at: "myClients", query: true)
    }

    @MainActor static func createClientInvite() async throws -> ClientInvite {
        try await run("mutation { createClientInvite { code url } }", at: "createClientInvite")
    }

    /// Every unit the client has, newest copy of each, key → body; deleted ones left out.
    @MainActor static func units(of client: String) async throws -> [String: String] {
        var units: [String: String] = [:]
        var since: String?
        while true {
            let page = try await page(of: client, since: since)
            for unit in page.units { units[unit.key] = unit.deleted ? nil : unit.body }
            since = page.cursor
            if !page.more { return units }
        }
    }

    @MainActor private static func page(of client: String, since: String?) async throws -> ClientPage {
        var variables: [String: Any] = ["u": client]
        if let since { variables["s"] = since }
        return try await run("query($s: String, $u: ID) { syncPull(since: $s, uid: $u) { units { key deleted body } cursor more } }",
                             variables, at: "syncPull", query: true)
    }

    @MainActor static func comments(of client: String) async throws -> [Triage.Comment] {
        try await run("query($u: ID) { comments(uid: $u) { day at by byName text } }", ["u": client], at: "comments", query: true)
    }

    @MainActor static func postComment(_ text: String, day: String, client: String) async throws -> Triage.Comment {
        try await run("mutation($u: ID, $d: String!, $t: String!) { postComment(uid: $u, day: $d, text: $t) { day at by byName text } }",
                      ["u": client, "d": day, "t": text], at: "postComment")
    }

    /// A client's unit, as changed here; false when the server kept a newer copy (their phone's).
    @MainActor static func push(_ key: String, body: String?, client: String) async throws -> Bool {
        var unit: [String: Any] = ["key": key, "updatedAt": Date.now.formatted(.iso8601), "deleted": body == nil]
        if let body { unit["body"] = body }
        let result: Pushed = try await run("mutation($u: [SyncUnitInput!]!, $o: ID) { syncPush(units: $u, source: \"app\", uid: $o) { rejected { key } } }",
                                           ["u": [unit], "o": client], at: "syncPush")
        return result.rejected.isEmpty
    }
}
