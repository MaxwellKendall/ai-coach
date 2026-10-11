import Foundation
import SwiftData

/// FIT-16: keeps my progress in each group current. Computed here from my logs; only the result is sent.
@MainActor
enum GroupSync {
    /// Per group, on this iPhone: share actual numbers, or percent only (the default).
    static func sharesNumbers(_ groupId: String) -> Bool {
        UserDefaults.standard.bool(forKey: "group.\(groupId).numbers")
    }

    static func setSharesNumbers(_ on: Bool, _ groupId: String) {
        UserDefaults.standard.set(on, forKey: "group.\(groupId).numbers")
    }

    /// FIT-114, per group on this iPhone: share my planned days this week (off by default).
    static func sharesWeek(_ groupId: String) -> Bool {
        UserDefaults.standard.bool(forKey: "group.\(groupId).week")
    }

    static func setSharesWeek(_ on: Bool, _ groupId: String) {
        UserDefaults.standard.set(on, forKey: "group.\(groupId).week")
    }

    /// This week's planned workout days, a session name each, as the group sees them.
    static func week(of date: Date = .now, planned: [(date: Date, title: String)], calendar: Calendar = .current)
        -> (weekOf: String, days: [Cloud.PlannedDay]) {
        let monday = Week.start(of: date, calendar: calendar)
        let end = calendar.date(byAdding: .day, value: 7, to: monday)!
        var days: [Date: String] = [:]
        for item in planned where item.date >= monday && item.date < end {
            let day = calendar.startOfDay(for: item.date)
            if days[day] == nil { days[day] = String(item.title.prefix(40)) }
        }
        return (SharedSession.day(monday, calendar: calendar),
                days.keys.sorted().map { Cloud.PlannedDay(day: SharedSession.day($0, calendar: calendar), title: days[$0]!) })
    }

    /// Where I started on a group goal. Kept here because a percent-only member never sends it.
    private static func baseline(_ goalId: String) -> Double? {
        UserDefaults.standard.object(forKey: "group.goal.\(goalId).baseline") as? Double
    }

    struct Logs {
        var sets: [LoggedSet]
        var weighIns: [DatedValue]

        @MainActor init(_ context: ModelContext) {
            let entries = (try? context.fetch(FetchDescriptor<LogEntry>())) ?? []
            let templates = (try? context.fetch(FetchDescriptor<Template>())) ?? []
            sets = Planner.loggedSets(entries, templates: templates)
            weighIns = entries.filter { $0.kind == .bodyweight }.compactMap { entry in
                entry.measurements.first { $0.metric == "weight_lb" }.map { DatedValue(date: entry.timestamp, value: $0.value) }
            }
        }
    }

    /// Publishes what changed and posts a win for each quarter mark crossed. Returns true if anything was sent.
    @discardableResult
    static func publish(_ group: Cloud.Group, me: String, logs: Logs) async -> Bool {
        guard let member = group.members.first(where: { $0.uid == me }) else { return false }
        let joined = Cloud.date(member.joinedAt) ?? .now
        let numbers = sharesNumbers(group.id)
        var sent = false
        for goal in group.goals {
            let previous = group.progress.first { $0.uid == me && $0.goalId == goal.goalId }
            guard let mine = GroupProgress.mine(metric: goal.metric, goal: goal.target, mode: goal.progressMode,
                                                deadline: goal.deadlineDate, baseline: baseline(goal.goalId) ?? previous?.baseline,
                                                joined: joined, sets: logs.sets, weighIns: logs.weighIns) else { continue }
            UserDefaults.standard.set(mine.baseline, forKey: "group.goal.\(goal.goalId).baseline")
            let unchanged = previous.map {
                $0.pct == mine.pct && $0.onPace == mine.onPace && $0.value == (numbers ? mine.value : nil)
            } ?? false
            guard !unchanged else { continue }
            do {
                try await Cloud.publish(mine, numbers: numbers, goalId: goal.goalId, in: group.id)
                if let mark = GroupProgress.milestone(from: previous?.pct, to: mine.pct) {
                    try await Cloud.post("milestone", ["pct": mark, "goalId": goal.goalId], in: group.id)
                }
                sent = true
            } catch {
                // Offline is fine: it goes next time.
            }
        }
        return sent
    }

    /// On launch and coming back to the app, for every group.
    static func all(_ context: ModelContext, me: String) async {
        guard let summaries = try? await Cloud.myGroups(), !summaries.isEmpty else { return }
        let logs = Logs(context)
        for summary in summaries {
            if let group = try? await Cloud.group(summary.groupId) { await publish(group, me: me, logs: logs) }
        }
    }
}
