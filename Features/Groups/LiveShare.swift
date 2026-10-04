import Foundation

/// FIT-53: what work mode shows right now, the only workout data a group sees: exercise, set, load, reps, RPE.
struct LiveSnapshot: Equatable, Sendable {
    var exercise: String
    var setIndex: Int
    var setCount: Int
    var loadLb: Double?
    var reps: Int?
    var seconds: Int?
    var rpe: Double?
    /// "working" or "resting".
    var state: String
}

extension WorkoutDraft {
    /// On a set card, the set up next (working); on its rest card or once it's logged, that set as logged (resting).
    /// Nil on the finish card.
    func live(at page: Int, names: [String: String]) -> LiveSnapshot? {
        let cards = cards
        guard cards.indices.contains(page) else { return nil }
        let line: [Int]
        switch cards[page] {
        case .set(let set): line = set
        case .rest:
            guard page > 0, case .set(let set) = cards[page - 1] else { return nil }
            line = set
        }
        guard let index = line.first else { return nil }
        let row = rows[index]
        let resting = line.allSatisfy { rows[$0].done }
        return LiveSnapshot(exercise: names[row.exercise] ?? row.exercise, setIndex: row.round + 1,
                            setCount: lines(block: row.block).count,
                            loadLb: row.loadMetric == nil ? nil : row.load,
                            reps: row.metric == "reps" ? row.value.map { Int($0) } : nil,
                            seconds: row.metric == "duration_s" ? row.value.map { Int($0) } : nil,
                            rpe: row.rpe, state: resting ? "resting" : "working")
    }

    /// The finished session for the group feed: the heaviest set, as "Bench Press 185 × 5".
    func top(names: [String: String]) -> String? {
        guard let row = rows.filter({ $0.done && $0.load != nil && $0.loadMetric != nil }).max(by: { ($0.load ?? 0) < ($1.load ?? 0) })
        else { return nil }
        let reps = row.metric == "reps" ? row.value.map { " × \(Int($0))" } ?? "" : ""
        return "\(names[row.exercise] ?? row.exercise) \(Coach.number(row.load ?? 0))\(reps)"
    }
}

/// Sends work mode's live state to every group I opted in to. Fire and forget, one at a time, so logging never
/// waits on the network: offline just isn't live (FIT-53).
@MainActor
final class LiveShare {
    private let workout: String
    private let startedAt: Date
    private var groups: [String]?
    private var latest: LiveSnapshot?
    private var sent: LiveSnapshot?
    private var queue: Task<Void, Never>?

    init(workout: String, startedAt: Date) {
        self.workout = workout
        self.startedAt = startedAt
    }

    /// Looks up which groups to share with. Signed out or opted in nowhere, nothing is ever sent.
    func start() {
        enqueue { [self] in
            groups = ((try? await Cloud.myGroups()) ?? []).filter { $0.shareLive == true }.map(\.groupId)
        }
        flush()
    }

    func update(_ snapshot: LiveSnapshot?) {
        guard let snapshot else { return }
        latest = snapshot
        flush()
    }

    /// Ends the session for viewers, and posts the summary when the workout was saved.
    func end(saved: (sets: Int, top: String?)?) {
        enqueue { [self] in
            for group in groups ?? [] {
                try? await Cloud.endLive(in: group)
                if let saved {
                    var fields: [String: Any] = ["workout": workout, "sets": saved.sets]
                    if let top = saved.top { fields["top"] = top }
                    try? await Cloud.post("session", fields, in: group)
                }
            }
        }
    }

    private func flush() {
        enqueue { [self] in
            guard let groups, let latest, latest != sent else { return }
            sent = latest
            for group in groups {
                try? await Cloud.publishLive(latest, workout: workout, startedAt: startedAt, in: group)
            }
        }
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = queue
        queue = Task {
            await previous?.value
            await work()
        }
    }
}

extension Cloud.LiveSet {
    /// A LIVE item older than about 3 hours is shown as ended (FIT-53).
    func isLive(now: Date = .now) -> Bool {
        guard state != "done", let updated = Cloud.date(updatedAt) else { return false }
        return now.timeIntervalSince(updated) < 3 * 3600
    }

    /// "Bench Press · set 3 of 5".
    var setLine: String {
        [exercise, setIndex.map { i in setCount.map { "set \(i) of \($0)" } ?? "set \(i)" }].compactMap { $0 }.joined(separator: " · ")
    }

    /// "185 lb × 5 · resting 1:12", or "working" while the set is under way.
    func what(now: Date = .now) -> String {
        var parts: [String] = []
        let dose = [loadLb.map { "\(Coach.number($0)) lb" }, reps.map { "\($0)" } ?? seconds.map { "\($0) s" }].compactMap { $0 }
        if !dose.isEmpty { parts.append(dose.joined(separator: " × ")) }
        if state == "resting", let since = Cloud.date(updatedAt) {
            let seconds = max(0, Int(now.timeIntervalSince(since)))
            parts.append("resting \(seconds / 60):\(String(format: "%02d", seconds % 60))")
        } else {
            parts.append(state)
        }
        return parts.joined(separator: " · ")
    }
}
