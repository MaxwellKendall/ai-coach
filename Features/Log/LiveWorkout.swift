import ActivityKit
import Foundation
import UIKit

/// TKL-801: where the live workout is (the warm-up step, the card, the running rest) and the moves on it. The workout
/// screen's Done, −30 s, +30 s and Skip and the Live Activity's Done set, −10s, +10s and Skip all go through these.
struct WorkoutCursor: Equatable {
    var warmStep = 0
    var page = 0
    var rest: Rest?

    /// The running rest, on its card.
    struct Rest: Equatable {
        var ends: Date
        var total: TimeInterval
        var page: Int
    }

    /// Done: a warm-up step is done, or the set on screen is logged and its rest starts, or a rest is skipped.
    /// The finish card stays (Save is its own button).
    mutating func forward(_ draft: inout WorkoutDraft, now: Date = .now) {
        if warmStep < draft.warmups.count { warmStep += 1; return }
        let cards = draft.cards
        guard cards.indices.contains(page) else { return }
        switch cards[page] {
        case .set(let line):
            if !line.allSatisfy({ draft.rows[$0].done }) {
                draft.tick(line)
                if cards.indices.contains(page + 1), case .rest(let seconds) = cards[page + 1] {
                    rest = Rest(ends: now + seconds, total: seconds, page: page + 1)
                }
            }
        case .rest:
            if rest?.page == page { rest = nil }
        }
        page += 1
    }

    /// −/+ on the rest card at `index`: the running rest ends sooner (never before now) or later; one not started yet
    /// starts with the change, and one cut to nothing is skipped.
    mutating func shiftRest(by seconds: TimeInterval, on index: Int, in draft: WorkoutDraft, now: Date = .now) {
        if let active = rest, active.page == index {
            if seconds < 0 {
                rest?.ends = max(now, active.ends + seconds)
            } else {
                let left = max(0, active.ends.timeIntervalSince(now))
                rest?.ends += seconds
                rest?.total = max(active.total, left + seconds)
            }
            return
        }
        let cards = draft.cards
        guard cards.indices.contains(index), case .rest(let planned) = cards[index] else { return }
        if planned + seconds > 0 {
            rest = Rest(ends: now + planned + seconds, total: planned + seconds, page: index)
        } else {
            skipRest(on: index)
        }
    }

    /// Skip on the rest card at `index`: the rest ends and the next set is on screen.
    mutating func skipRest(on index: Int) {
        if rest?.page == index { rest = nil }
        if page == index { page = index + 1 }
    }

    /// The rest the Live Activity's buttons act on: the one running, else the rest card on screen.
    func restIndex(in draft: WorkoutDraft) -> Int? {
        if let rest { return rest.page }
        let cards = draft.cards
        guard warmStep >= draft.warmups.count, cards.indices.contains(page), case .rest = cards[page] else { return nil }
        return page
    }

    /// A rest that has run out ends, and its card moves on to the next set. Returns whether one did.
    mutating func restEnded(now: Date = .now) -> Bool {
        guard let rest, rest.ends <= now else { return false }
        self.rest = nil
        if page == rest.page { page = rest.page + 1 }
        return true
    }
}

/// TKL-801: the workout on screen, which the Live Activity's buttons change while the app is in the background. The
/// workout screen reads and writes it; it keeps the Live Activity up to date and ends rests on time.
@Observable @MainActor final class LiveWorkout {
    /// The workout open now, for the Live Activity's intents.
    static weak var current: LiveWorkout?

    var draft: WorkoutDraft
    var cursor = WorkoutCursor() {
        didSet { if cursor.rest != oldValue.rest { watchRest() } }
    }
    var names: [String: String] = [:]
    /// Rests that ran out, for the screen's haptic.
    private(set) var restsFinished = 0
    /// The card a rest that ran out moved on to, until it's done: "Rest over" on the island.
    private var restOverPage: Int?

    enum Action: String { case done, less, more, skip }

    @ObservationIgnored private let activity = WorkoutActivity()
    @ObservationIgnored private var published: WorkoutActivityAttributes.ContentState?
    @ObservationIgnored private var timer: Task<Void, Never>?

    init(draft: WorkoutDraft) {
        self.draft = draft
    }

    /// A Live Activity button. A rest that ran out while the app slept ends first, so Done set does the set after it.
    func handle(_ action: Action, now: Date = .now) {
        _ = finishRest(now: now, alert: false)
        switch action {
        case .done:
            cursor.forward(&draft, now: now)
        case .less, .more:
            guard let index = cursor.restIndex(in: draft) else { break }
            cursor.shiftRest(by: action == .less ? -10 : 10, on: index, in: draft, now: now)
        case .skip:
            guard let index = cursor.restIndex(in: draft) else { break }
            cursor.skipRest(on: index)
        }
        publish(now: now)
    }

    /// Ends a rest that has run out; the island says so. Returns whether one did.
    @discardableResult
    func finishRest(now: Date = .now, alert: Bool = true) -> Bool {
        guard cursor.restEnded(now: now) else { return false }
        restsFinished += 1
        restOverPage = cursor.page
        if alert { publish(now: now, restOver: true) }
        return true
    }

    // MARK: Live Activity

    func start() {
        Self.current = self
        activity.start(content())
        published = content()
    }

    func end() {
        timer?.cancel()
        activity.end()
        if Self.current === self { Self.current = nil }
    }

    /// Sends the island what's on screen now, if it changed; with an alert when a rest has just run out.
    func publish(now: Date = .now, restOver: Bool = false) {
        let state = content(now: now)
        guard restOver || state != published else { return }
        published = state
        let background = UIApplication.shared.applicationState != .active
        activity.update(state, alert: restOver && background
            ? AlertConfiguration(title: "Rest over", body: "\(state.title) · \(state.set)", sound: .default) : nil)
    }

    /// Ends the running rest when it runs out, whether or not the screen is showing.
    private func watchRest() {
        timer?.cancel()
        guard let ends = cursor.rest?.ends else { return }
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, ends.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.finishRest()
        }
    }

    /// FIT-304, TKL-801: the Live Activity: the step on screen; during a rest, the set after it and the rest's end.
    func content(now: Date = .now) -> WorkoutActivityAttributes.ContentState {
        let cards = draft.cards
        let done = draft.rows.filter(\.done).count
        let progress = draft.rows.isEmpty ? 0 : Double(done) / Double(draft.rows.count)
        let blocks = draft.blocks
        if cursor.warmStep < draft.warmups.count {
            let step = draft.warmups[cursor.warmStep]
            let first = cards.lazy.compactMap { if case .set(let line) = $0 { line } else { nil } }.first
            return .init(title: step.exercise.map { names[$0] ?? $0 } ?? "Row, bike or walk, easy",
                         detail: "Warm-up · \(step.dose)", step: "\(cursor.warmStep + 1)/\(draft.warmups.count)", load: nil,
                         restEnds: nil, progress: 0, lift: "Warm-up", set: step.dose,
                         next: first.map { "Next: " + glance($0) } ?? "", liftIndex: 0, lifts: blocks.count,
                         setsDone: cursor.warmStep, sets: draft.warmups.count)
        }
        let line: [Int]? = if cursor.page >= cards.count { nil }
            else if case .set(let line) = cards[cursor.page] { line } else { nextSet(after: cursor.page, in: cards) }
        guard let line else {
            return .init(title: draft.session, detail: "Done · save it in Barbrabell", step: "✓", load: nil, restEnds: nil,
                         progress: progress, liftIndex: blocks.count, lifts: blocks.count, isDone: true)
        }
        let rows = line.map { draft.rows[$0] }
        let first = rows[0]
        let lines = draft.lines(block: first.block)
        let loads = rows.compactMap(\.load).reduce(into: [Double]()) { if !$0.contains($1) { $0.append($1) } }
        let load = first.loadMetric == nil || loads.isEmpty ? nil
            : loads.map(Coach.number).joined(separator: "/") + " " + (SetRow.units[first.loadMetric ?? "load_lb"] ?? "lb")
        let values = rows.map { Coach.number($0.value ?? 0) }.joined(separator: "+")
            + (first.metric == "reps" ? "" : " " + (SetRow.units[first.metric] ?? ""))
        let title = WorkoutModeView.names(rows, names)
        let after = cards.firstIndex(of: .set(line)).flatMap { nextSet(after: $0, in: cards) }
        let rest = cursor.rest.flatMap { $0.ends > now ? $0 : nil }
        return .init(title: title, detail: "Set \(first.round + 1) of \(lines.count) · " + (load.map { "\($0) × " } ?? "") + values,
                     step: "\(first.round + 1)/\(lines.count)", load: load, restEnds: rest?.ends, progress: progress,
                     lift: WorkoutActivityAttributes.short(names[first.exercise] ?? title), set: Self.set(rows),
                     next: after.map { "Next: " + glance($0) } ?? "Last set",
                     liftIndex: (blocks.firstIndex(of: first.block) ?? 0) + 1, lifts: blocks.count,
                     setsDone: lines.filter { $0.allSatisfy { draft.rows[$0].done } }.count, sets: lines.count,
                     restTotal: rest?.total, restOver: rest == nil && restOverPage == cursor.page)
    }

    /// "185×5", "×10", "30 s": the set exactly.
    static func set(_ rows: [SetRow]) -> String {
        let first = rows[0]
        let loads = rows.compactMap(\.load).reduce(into: [Double]()) { if !$0.contains($1) { $0.append($1) } }
        let values = rows.map { Coach.number($0.value ?? 0) }.joined(separator: "+")
            + (first.metric == "reps" ? "" : " " + (SetRow.units[first.metric] ?? ""))
        let weight = loads.isEmpty || first.loadMetric == nil ? (first.metric == "reps" ? "×" : "")
            : loads.map(Coach.number).joined(separator: "/") + "×"
        return weight + values
    }

    /// "Squat 185×5": a set in a glance.
    private func glance(_ line: [Int]) -> String {
        let rows = line.map { draft.rows[$0] }
        return WorkoutActivityAttributes.short(names[rows[0].exercise] ?? rows[0].exercise) + " " + Self.set(rows)
    }

    private func nextSet(after index: Int, in cards: [WorkoutDraft.Card]) -> [Int]? {
        guard index + 1 < cards.count else { return nil }
        return cards[(index + 1)...].lazy.compactMap { if case .set(let line) = $0 { line } else { nil } }.first
    }
}
