import Foundation
@preconcurrency import Amplify

/// FIT-16: groups on AppSync (FIT-56 schema). The server stores and fans out what the app computed;
/// only goal progress and opted-in live sets leave the phone.
enum Cloud {
    struct GroupSummary: Decodable, Identifiable, Hashable, Sendable {
        var groupId: String
        var name: String
        var role: String
        /// Whether I share live workouts with this group (FIT-53).
        var shareLive: Bool?
        var id: String { groupId }
    }

    struct Group: Decodable, Sendable {
        var id: String
        var name: String
        var createdBy: String
        var inviteCode: String
        var members: [Member]
        var goals: [GroupGoal]
        var progress: [Progress]
        var live: [LiveSet]
        var feed: [FeedItem]
    }

    struct Member: Decodable, Identifiable, Hashable, Sendable {
        var uid: String
        var displayName: String?
        var shareLive: Bool
        var joinedAt: String
        var id: String { uid }
        var name: String { displayName ?? "Someone" }
    }

    struct GroupGoal: Decodable, Identifiable, Sendable {
        var goalId: String
        var metric: String
        var target: Double
        var deadline: String?
        var mode: String
        var createdAt: String
        var id: String { goalId }
        var progressMode: GroupProgress.Mode { GroupProgress.Mode(rawValue: mode) ?? .relative }
        var deadlineDate: Date? { deadline.flatMap { try? Date($0, strategy: .iso8601.year().month().day()) } }
        var title: String { GroupProgress.title(metric: metric, goal: target, mode: progressMode) }
        var unit: String { GoalOption.all.first { $0.metric == metric }?.unit ?? "" }
    }

    struct Progress: Decodable, Sendable {
        var uid: String
        var goalId: String
        var baseline: Double?
        var value: Double?
        var pct: Double?
        var onPace: Bool?
        var updatedAt: String
    }

    struct LiveSet: Decodable, Hashable, Sendable {
        var groupId: String
        var uid: String
        var workout: String?
        var exercise: String?
        var setIndex: Int?
        var setCount: Int?
        var loadLb: Double?
        var reps: Int?
        var seconds: Int?
        var rpe: Double?
        var state: String
        var startedAt: String
        var updatedAt: String
    }

    struct FeedItem: Decodable, Identifiable, Hashable, Sendable {
        var id: String
        var uid: String
        var kind: String
        /// AWSJSON: a JSON string.
        var measurements: String?
        var createdAt: String

        var fields: [String: Any] {
            guard let data = measurements?.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return object
        }
    }

    struct Profile: Decodable, Sendable {
        var displayName: String?
    }

    static func date(_ string: String) -> Date? {
        (try? Date(string, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)))
            ?? (try? Date(string, strategy: .iso8601))
    }

    static func json(_ object: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    static let liveFields = "groupId uid workout exercise setIndex setCount loadLb reps seconds rpe state startedAt updatedAt"
    private static let groupFields = """
        id name createdBy inviteCode
        members { uid displayName shareLive joinedAt }
        goals { goalId metric target deadline mode createdAt }
        progress { uid goalId baseline value pct onPace updatedAt }
        live { \(liveFields) }
        feed(limit: 50) { id uid kind measurements createdAt }
        """

    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    private static func run<R: Decodable & Sendable>(_ document: String, _ variables: sending [String: Any]? = nil, at path: String,
                                          as type: R.Type = R.self, query: Bool = false) async throws -> R {
        let request = GraphQLRequest<R>(document: document, variables: variables, responseType: R.self, decodePath: path)
        let result: GraphQLResponse<R>
        if query {
            result = try await Amplify.API.query(request: request)
        } else {
            result = try await Amplify.API.mutate(request: request)
        }
        switch result {
        case .success(let value): return value
        case .failure(let error): throw Failure(message: error.errorDescription)
        }
    }

    // MARK: Profile

    @MainActor static func profile() async throws -> Profile? {
        try await run("query { me { displayName } }", at: "me", as: Profile?.self, query: true)
    }

    /// Members see this name; it's copied into each membership when joining, so set it first.
    @MainActor static func setDisplayName(_ name: String) async throws {
        _ = try await run("mutation($n: String) { updateProfile(displayName: $n) { uid } }", ["n": name], at: "updateProfile",
                          as: AnyDecodable?.self)
    }

    // MARK: Groups

    @MainActor static func myGroups() async throws -> [GroupSummary] {
        try await run("query { myGroups { groupId name role shareLive } }", at: "myGroups", query: true)
    }

    @MainActor static func group(_ id: String) async throws -> Group? {
        try await run("query($g: ID!) { group(groupId: $g) { \(groupFields) } }", ["g": id], at: "group", as: Group?.self, query: true)
    }

    /// A group starts with its first goal; members can add more (FIT-16).
    @MainActor static func createGroup(name: String, metric: String, target: Double, deadline: Date?) async throws -> GroupSummary {
        let summary: GroupSummary = try await run("mutation($n: String!) { createGroup(name: $n) { groupId name role } }",
                                                  ["n": name], at: "createGroup")
        _ = try await addGoal(to: summary.groupId, metric: metric, target: target, deadline: deadline)
        return summary
    }

    /// Relative only for now ("lose 10 lb"), so members at different starting points compare. Returns the goal's id.
    @MainActor static func addGoal(to groupId: String, metric: String, target: Double, deadline: Date?) async throws -> String {
        var variables: [String: Any] = ["g": groupId, "m": metric, "t": target, "mode": GroupProgress.Mode.relative.rawValue]
        if let deadline { variables["d"] = deadline.formatted(.iso8601.year().month().day()) }
        struct Added: Decodable, Sendable { var goalId: String }
        let added: Added = try await run("""
            mutation($g: ID!, $m: String!, $t: Float!, $d: AWSDate, $mode: String!) {
              addGroupGoal(groupId: $g, metric: $m, target: $t, deadline: $d, mode: $mode) { goalId }
            }
            """, variables, at: "addGroupGoal")
        return added.goalId
    }

    @MainActor static func join(code: String) async throws -> GroupSummary {
        try await run("mutation($c: String!) { joinGroup(inviteCode: $c) { groupId name role } }",
                      ["c": code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()], at: "joinGroup")
    }

    @MainActor static func leave(_ groupId: String) async throws {
        _ = try await run("mutation($g: ID!) { leaveGroup(groupId: $g) }", ["g": groupId], at: "leaveGroup", as: Bool?.self)
    }

    @MainActor static func remove(_ uid: String, from groupId: String) async throws {
        _ = try await run("mutation($g: ID!, $u: ID!) { removeMember(groupId: $g, uid: $u) }", ["g": groupId, "u": uid],
                          at: "removeMember", as: Bool?.self)
    }

    @MainActor static func rotateInvite(_ groupId: String) async throws -> String {
        try await run("mutation($g: ID!) { rotateInvite(groupId: $g) }", ["g": groupId], at: "rotateInvite")
    }

    @MainActor static func setShareLive(_ on: Bool, in groupId: String) async throws {
        _ = try await run("mutation($g: ID!, $s: Boolean!) { setShareLive(groupId: $g, shareLive: $s) { uid } }",
                          ["g": groupId, "s": on], at: "setShareLive", as: AnyDecodable?.self)
    }

    // MARK: Publishing

    @MainActor static func publish(_ mine: GroupProgress.Mine, numbers: Bool, goalId: String, in groupId: String) async throws {
        var variables: [String: Any] = ["g": groupId, "goal": goalId, "pct": mine.pct]
        if let onPace = mine.onPace { variables["pace"] = onPace }
        if numbers {
            variables["b"] = mine.baseline
            variables["v"] = mine.value
        }
        // Subscribers get only the fields selected here (FIT-56 schema note).
        _ = try await run("""
            mutation($g: ID!, $goal: ID!, $b: Float, $v: Float, $pct: Float, $pace: Boolean) {
              publishProgress(groupId: $g, goalId: $goal, baseline: $b, value: $v, pct: $pct, onPace: $pace) {
                groupId uid goalId baseline value pct onPace updatedAt
              }
            }
            """, variables, at: "publishProgress", as: AnyDecodable?.self)
    }

    @MainActor static func post(_ kind: String, _ fields: [String: Any], in groupId: String) async throws {
        _ = try await run("""
            mutation($g: ID!, $k: String!, $m: AWSJSON) {
              postFeed(groupId: $g, kind: $k, measurements: $m) { groupId id uid kind measurements createdAt }
            }
            """, ["g": groupId, "k": kind, "m": json(fields)], at: "postFeed", as: AnyDecodable?.self)
    }

    /// FIT-53: work mode's current set, overwriting my LIVE item. Every LiveSet field is selected so
    /// subscribers get all of it.
    @MainActor static func publishLive(_ live: LiveSnapshot, workout: String, startedAt: Date, in groupId: String) async throws {
        var variables: [String: Any] = ["g": groupId, "w": workout, "e": live.exercise, "i": live.setIndex, "n": live.setCount,
                                        "s": live.state, "t": startedAt.formatted(.iso8601)]
        if let load = live.loadLb { variables["l"] = load }
        if let reps = live.reps { variables["r"] = reps }
        if let seconds = live.seconds { variables["sec"] = seconds }
        if let rpe = live.rpe { variables["rpe"] = rpe }
        _ = try await run("""
            mutation($g: ID!, $w: String, $e: String!, $i: Int!, $n: Int!, $l: Float, $r: Int, $sec: Int, $rpe: Float, $s: String!, $t: AWSDateTime!) {
              publishLiveSet(groupId: $g, workout: $w, exercise: $e, setIndex: $i, setCount: $n, loadLb: $l, reps: $r, seconds: $sec,
                             rpe: $rpe, state: $s, startedAt: $t) { \(liveFields) }
            }
            """, variables, at: "publishLiveSet", as: AnyDecodable?.self)
    }

    @MainActor static func endLive(in groupId: String) async throws {
        _ = try await run("mutation($g: ID!) { endLiveSession(groupId: $g) { \(liveFields) } }", ["g": groupId],
                          at: "endLiveSession", as: AnyDecodable?.self)
    }

    /// FIT-53: this iPhone's APNs token, for "Dad started Push day".
    @MainActor static func registerDevice(_ token: String) async throws {
        _ = try await run("mutation($t: String!) { registerDevice(token: $t, platform: \"ios\") }", ["t": token],
                          at: "registerDevice", as: Bool?.self)
    }

    // MARK: Real time

    @MainActor static func liveSets(in groupId: String) -> AmplifyAsyncThrowingSequence<GraphQLSubscriptionEvent<LiveSet>> {
        Amplify.API.subscribe(request: GraphQLRequest<LiveSet>(
            document: "subscription($g: ID!) { onLiveSet(groupId: $g) { \(liveFields) } }",
            variables: ["g": groupId], responseType: LiveSet.self, decodePath: "onLiveSet"))
    }

    /// Something changed in the group: a member's progress or a feed item. The group screen reloads.
    struct Ping: Decodable, Sendable { var groupId: String }

    /// `field` is onProgress or onFeed.
    @MainActor static func changes(_ field: String, in groupId: String) -> AmplifyAsyncThrowingSequence<GraphQLSubscriptionEvent<Ping>> {
        Amplify.API.subscribe(request: GraphQLRequest<Ping>(
            document: "subscription($g: ID!) { \(field)(groupId: $g) { groupId } }",
            variables: ["g": groupId], responseType: Ping.self, decodePath: field))
    }
}

/// Lets a response be decoded and ignored whatever its shape.
struct AnyDecodable: Decodable, Sendable {
    init(from decoder: Decoder) throws {}
}
