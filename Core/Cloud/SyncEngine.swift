import Foundation
import Observation
import OSLog
import SwiftData
@preconcurrency import Amplify

/// FIT-126: keeps a signed-in account's program and logs in step with the server, both ways. After a save here it
/// pushes what changed; on start, on foreground and when the server says something changed (a web edit), it pulls.
/// Signed out, it doesn't run, and the app works as before.
@Observable @MainActor
final class SyncEngine {
    static let shared = SyncEngine()

    /// What the Account screen shows: when this phone last finished a sync, or why the last one failed.
    private(set) var lastSynced: Date?
    private(set) var failure: String?

    @ObservationIgnored private var uid: String?
    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private var state = SyncState()
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var again = false
    @ObservationIgnored private var listeners: [Task<Void, Never>] = []
    @ObservationIgnored private let log = Logger(subsystem: "AICoach", category: "sync")

    /// This install, so the subscription can skip what it pushed itself.
    @ObservationIgnored private let source: String = {
        if let id = UserDefaults.standard.string(forKey: "sync.source") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "sync.source")
        return id
    }()

    func start(uid: String, context: ModelContext) {
        guard self.uid != uid else { return sync() }
        stop()
        self.uid = uid
        self.context = context
        state = Self.load(uid)
        listeners = [saves(), changes(uid)]
        sync()
    }

    func stop() {
        listeners.forEach { $0.cancel() }
        listeners = []
        uid = nil
        lastSynced = nil
        failure = nil
        context = nil
    }

    /// Runs a sync now, or once more after the one running.
    func sync() {
        guard uid != nil else { return }
        if running != nil {
            again = true
            return
        }
        running = Task {
            repeat {
                again = false
                await once()
            } while again
            running = nil
        }
    }

    private func once() async {
        guard let uid, let context else { return }
        do {
            if !state.pulledOnce {
                try await pull(into: context)
                state.pulledOnce = true
            }
            let local = try SyncUnits.all(in: context)
            state.notice(local, now: .now)
            let outgoing = state.outgoing(local)
            for start in stride(from: 0, to: outgoing.count, by: 25) {
                let chunk = Array(outgoing[start..<min(start + 25, outgoing.count)])
                let rejected = try await Self.push(chunk, source: source)
                let kept = Set(rejected.map(\.key))
                state.pushed(chunk.filter { !kept.contains($0.key) })
                // The server has a newer copy: it wins here.
                try apply(rejected, into: context, force: true)
            }
            try await pull(into: context)
            Self.save(state, uid)
            lastSynced = .now
            failure = nil
        } catch {
            log.error("sync failed: \(error.localizedDescription, privacy: .public)")
            failure = error.localizedDescription
            Self.save(state, uid)
        }
    }

    /// Everything stored since the cursor, a minute back: the index the server pulls from can lag a write by a moment,
    /// and a unit already here is skipped.
    private func pull(into context: ModelContext) async throws {
        var since = state.cursor.map(Self.rewound)
        while true {
            let page = try await Self.pull(since: since)
            try apply(page.units, into: context, force: false)
            if let cursor = page.cursor { state.cursor = cursor }
            since = page.cursor
            if !page.more { break }
        }
    }

    private func apply(_ units: [SyncState.Unit], into context: ModelContext, force: Bool) throws {
        let wanted = units.filter { force || state.shouldApply($0) }
        guard !wanted.isEmpty else { return }
        for unit in wanted {
            try SyncUnits.apply(unit.key, body: unit.body, in: context)
        }
        try context.save()
        let local = try SyncUnits.all(in: context)
        for unit in wanted { state.applied(unit.key, local: local[unit.key]) }
        Self.save(state, uid ?? "")
    }

    // MARK: Triggers

    /// A save anywhere in the app: push after a moment, so a burst of saves is one push.
    private func saves() -> Task<Void, Never> {
        Task { [weak self] in
            let saves = NotificationCenter.default.notifications(named: ModelContext.didSave).map { _ in () }
            var pending: Task<Void, Never>?
            for await _ in saves {
                pending?.cancel()
                pending = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    self?.sync()
                }
            }
        }
    }

    /// The server says my data changed somewhere else (the web, another phone): pull.
    private func changes(_ uid: String) -> Task<Void, Never> {
        Task { [weak self, source] in
            let request = GraphQLRequest<Pushed>(document: "subscription($u: ID!) { onSync(uid: $u) { uid source changedAt } }",
                                                 variables: ["u": uid], responseType: Pushed.self, decodePath: "onSync")
            do {
                for try await event in Amplify.API.subscribe(request: request) {
                    if case .data(.success(let pushed)) = event, pushed.source != source { self?.sync() }
                }
            } catch {
                self?.log.error("onSync ended: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Server

    private struct Pushed: Decodable, Sendable {
        var uid: String
        var source: String?
        var changedAt: String
    }

    private struct Stored: Decodable, Sendable {
        var key: String
        var updatedAt: String
        var deleted: Bool
        var body: String?

        var unit: SyncState.Unit {
            SyncState.Unit(key: key, updatedAt: Cloud.date(updatedAt) ?? .distantPast, body: deleted ? nil : body)
        }
    }

    private struct PushResult: Decodable, Sendable {
        var rejected: [Stored]
    }

    private struct Page: Decodable, Sendable {
        var units: [Stored]
        var cursor: String?
        var more: Bool
    }

    private static let unitFields = "key updatedAt deleted body"
    /// As the server writes times: "2026-10-16T12:00:00.000Z".
    private static let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private static func push(_ units: [SyncState.Unit], source: String) async throws -> [SyncState.Unit] {
        let input: [[String: Any]] = units.map { unit in
            var fields: [String: Any] = ["key": unit.key, "updatedAt": unit.updatedAt.formatted(iso), "deleted": unit.deleted]
            if let body = unit.body { fields["body"] = body }
            return fields
        }
        // Subscribers get only the fields selected here.
        let result: PushResult = try await Cloud.run("""
            mutation($u: [SyncUnitInput!]!, $s: String) {
              syncPush(units: $u, source: $s) { uid source changedAt rejected { \(unitFields) } }
            }
            """, ["u": input, "s": source], at: "syncPush")
        return result.rejected.map(\.unit)
    }

    private static func pull(since: String?) async throws -> (units: [SyncState.Unit], cursor: String?, more: Bool) {
        var variables: [String: Any] = [:]
        if let since { variables["s"] = since }
        let page: Page = try await Cloud.run("query($s: String) { syncPull(since: $s) { units { \(unitFields) } cursor more } }",
                                             variables, at: "syncPull", query: true)
        return (page.units.map(\.unit), page.cursor, page.more)
    }

    /// A cursor ("2026-10-16T12:00:00.000Z#plan#2026-10-16") a minute earlier, before any key.
    static func rewound(_ cursor: String) -> String {
        guard let time = cursor.split(separator: "#").first, let date = Cloud.date(String(time)) else { return cursor }
        return (date - 60).formatted(iso)
    }

    // MARK: State, per account on this iPhone

    private static func url(_ uid: String) -> URL {
        URL.applicationSupportDirectory.appending(path: "sync-\(uid).json")
    }

    private static func load(_ uid: String) -> SyncState {
        (try? Data(contentsOf: url(uid))).flatMap { try? JSONDecoder().decode(SyncState.self, from: $0) } ?? SyncState()
    }

    private static func save(_ state: SyncState, _ uid: String) {
        guard !uid.isEmpty, let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        try? data.write(to: url(uid), options: .atomic)
    }
}
