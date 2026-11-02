import Foundation

/// FIT-298: which clients need their coach, as the dashboard and the MCP's roster tools judge it (shared/triage.ts,
/// FIT-132/FIT-196). A port, so the three agree: change one, change all three. Days are "yyyy-MM-dd" strings, as the
/// sync units' keys have them.
enum Triage {
    struct Flag: Equatable, Sendable {
        enum Kind: String, CaseIterable, Sendable { case pain, missed, hard, plateau, behind, quiet, note }
        var kind: Kind
        var text: String
        /// The day a note was left on, so the phone can open it to reply (not in shared/triage.ts).
        var day: String?
    }

    /// A reply on a session (FIT-132).
    struct Comment: Codable, Equatable, Sendable {
        var day: String
        var at: String
        var by: String
        var byName: String?
        var text: String
    }

    /// One client's week: sessions done of planned (Sunday to Saturday), the last session, and the flags.
    struct Week: Equatable, Sendable {
        var done: Int
        var planned: Int
        var lastSession: String?
        var flags: [Flag]

        /// Nil on track; else the most pressing flag's place in `Flag.Kind`'s order, for `byNeed`.
        var need: Int? { flags.map { Flag.Kind.allCases.firstIndex(of: $0.kind)! }.min() }
    }

    /// A unit's rows, read leniently: plan and log rows share these fields.
    private struct Row: Decodable {
        var id: String
        var kind: String
        var template: String?
        var plannedRef: String?
        var main: Bool?
        var note: String?
        var measurements: [Measurement]?

        func value(_ metric: String) -> Double? { measurements?.first { $0.metric == metric }?.value }
    }

    /// WeeklyReview.hurts: the words that mean something hurts.
    static func hurts(_ text: String) -> Bool {
        let text = text.lowercased()
        return ["pain", "sore", "hurt", "ache", "tight", "tweak", "twinge", "strain", "sharp", "niggle"].contains { text.contains($0) }
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private static let format = Date.ISO8601FormatStyle(timeZone: TimeZone(identifier: "UTC")!).year().month().day()

    private static func date(_ day: String) -> Date { (try? format.parse(day)) ?? .distantPast }
    static func add(_ days: Int, to day: String) -> String { utc.date(byAdding: .day, value: days, to: date(day))!.formatted(format) }
    /// The Sunday on or before a day (FIT-82's weeks).
    static func sunday(of day: String) -> String { add(-(utc.component(.weekday, from: date(day)) - 1), to: day) }
    private static let days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    private static func weekday(_ day: String) -> String { days[utc.component(.weekday, from: date(day)) - 1] }

    private static func rows(_ units: [String: String], _ key: String) -> [Row] {
        units[key].flatMap { try? JSONDecoder().decode([Row].self, from: Data($0.utf8)) } ?? []
    }

    /// FIT-223: a day's check-in note, on the sleep row, else the weight row.
    private static func checkInNote(_ log: [Row]) -> String? {
        (log.filter { $0.kind == "sleep" } + log.filter { $0.kind == "bodyweight" })
            .compactMap { $0.note?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }

    /// Brzycki, fitness-planner CLAUDE.md "1RM Estimation": valid for 1–10 reps at RPE ≤ 8.
    private static func estimate(_ row: Row) -> Double? {
        guard let load = row.value("load_lb"), let reps = row.value("reps"), (1...10).contains(reps), (row.value("rpe") ?? 0) <= 8
        else { return nil }
        return load * 36 / (37 - reps)
    }

    /// FIT-140: logged on 3+ days in the 21 before today, none beating the best before them.
    private static func plateaued(_ units: [String: String], _ exercise: String, today: String) -> Bool {
        let start = add(-21, to: today)
        var before = 0.0
        var recent: [String: Double] = [:]
        for key in units.keys where key.hasPrefix("log#") {
            let day = String(key.dropFirst(4))
            for row in rows(units, key) where row.kind == "workout" && row.template == exercise {
                guard let e = estimate(row) else { continue }
                if day < start { before = max(before, e) } else if day < today { recent[day] = max(recent[day] ?? 0, e) }
            }
        }
        return before > 0 && recent.count >= 3 && (recent.values.max() ?? 0) <= before
    }

    private struct GoalBody: Decodable { var metric: String; var target: Double; var deadline: Double?; var baseline: Double?; var status: String }
    private struct ProfileBody: Decodable { var programStart: Double?; var targetDate: Double? }
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    private static func short(_ epoch: Double) -> String {
        let date = Date(timeIntervalSince1970: epoch)
        return "\(months[utc.component(.month, from: date) - 1]) \(utc.component(.day, from: date))"
    }
    /// Coach.number, as shared/triage.ts writes it: at most one decimal.
    private static func number(_ x: Double) -> String {
        let x = (x * 10).rounded() / 10
        return x == x.rounded() ? String(Int(x)) : String(x)
    }

    /// GoalProgress.current for a max, reps or body weight since `since` (a race time isn't flagged here).
    private static func goalNow(_ units: [String: String], _ metric: String, since: String) -> Double? {
        var best: Double?, weighed: String?
        let parts = metric.split(separator: ".").map(String.init)
        for key in units.keys where key.hasPrefix("log#") && String(key.dropFirst(4)) >= since {
            let day = String(key.dropFirst(4))
            for row in rows(units, key) {
                if metric == "weight_lb" {
                    if row.kind == "bodyweight", let w = row.value("weight_lb"), weighed.map({ day > $0 }) ?? true { weighed = day; best = w }
                    continue
                }
                guard parts.count == 2, row.kind == "workout", row.template == parts[0] else { continue }
                let load = row.value("load_lb"), reps = row.value("reps")
                var v: Double?
                if parts[1] == "1rm_lb", let load, let reps, reps <= 12 { v = (load * 36 / (37 - reps)).rounded() }
                if parts[1] == "reps", load == nil { v = reps }
                if let v { best = max(best ?? v, v) }
            }
        }
        return best
    }

    /// FIT-278: GoalProgress.forecast to the goal's own date, else the program's, and how far short of the target it
    /// lands ("12 lb short of 250 by Jan 16"). Not before two weeks of the program; a goal that hasn't moved toward its
    /// target lands where it is.
    private static func behind(_ units: [String: String], names: [String: String], today: String) -> [String] {
        let profile = units["profile"].flatMap { try? JSONDecoder().decode(ProfileBody.self, from: Data($0.utf8)) }
        let now = date(today).addingTimeInterval(12 * 3600).timeIntervalSince1970
        guard let programStart = profile?.programStart, now - programStart >= 14 * 86_400 else { return [] }
        let since = Date(timeIntervalSince1970: programStart).formatted(format)
        var out: [String] = []
        for key in units.keys.sorted() where key.hasPrefix("goal#") {
            guard let g = units[key].flatMap({ try? JSONDecoder().decode(GoalBody.self, from: Data($0.utf8)) }),
                  g.status == "active", let start = g.baseline, let due = g.deadline ?? profile?.targetDate, due > now,
                  g.metric == "weight_lb" || g.metric.hasSuffix(".1rm_lb") || g.metric.hasSuffix(".reps") else { continue }
            let logged = goalNow(units, g.metric, since: since)
            let at = logged.map { g.metric == "weight_lb" ? $0 : max($0, start) } ?? start
            let way: Double = g.metric == "weight_lb" && g.target < start ? -1 : 1
            let lands = (at - start) * way > 0 ? max(0, at + (at - start) / (now - programStart) * (due - now)) : at
            let gap = (g.target - lands) * way
            guard gap > 0 else { continue }
            let slug = String(g.metric.split(separator: ".")[0])
            let name = g.metric == "weight_lb" ? "Weight" : names[slug] ?? slug
            let unit = g.metric.hasSuffix(".reps") ? (gap.rounded() == 1 ? "rep" : "reps") : "lb"
            let amount = g.metric == "weight_lb" ? number(gap) : String(Int(max(1, gap.rounded())))
            out.append("\(name): \(amount) \(unit) short of \(number(g.target)) by \(short(due))")
        }
        return out
    }

    static func week(_ units: [String: String], comments: [Comment], names: [String: String], coach: String, today: String) -> Week {
        var planned: [String] = [], done: [String] = []
        for key in units.keys {
            let parts = key.split(separator: "#", maxSplits: 1)
            guard parts.count == 2, ["plan", "log"].contains(parts[0]), rows(units, key).contains(where: { $0.kind == "workout" }) else { continue }
            if parts[0] == "plan" { planned.append(String(parts[1])) } else { done.append(String(parts[1])) }
        }
        let start = sunday(of: today), end = add(7, to: start)
        let thisWeek = { (day: String) in day >= start && day < end }
        let lastSession = done.max()
        var flags: [Flag] = []

        // A note in the last 7 days the coach hasn't replied to after: the session's summary row, or the check-in.
        let weekAgo = add(-7, to: today)
        let logged = units.keys.filter { $0.hasPrefix("log#") }.map { String($0.dropFirst(4)) }.filter { $0 >= weekAgo }
        for day in logged.sorted(by: >) where !comments.contains(where: { $0.day == day && $0.by == coach }) {
            let log = rows(units, "log#\(day)")
            var notes = log.filter { $0.kind == "workout" && $0.template == nil }.compactMap(\.note).filter { !$0.isEmpty }
            if let note = checkInNote(log) { notes.append(note) }
            var seen = Set<String>()
            let text = notes.filter { seen.insert($0).inserted }.joined(separator: " ")
            guard !text.isEmpty else { continue }
            flags.append(Flag(kind: hurts(text) ? .pain : .note, text: "\(weekday(day)): “\(text)”", day: day))
        }

        let missed = planned.filter { $0 >= weekAgo && $0 < today && !done.contains($0) }
        if missed.count >= 2 { flags.append(Flag(kind: .missed, text: "Missed \(missed.count) sessions this past week")) }

        var main = Set<String>(), mainLifts: [String] = []
        for key in units.keys.sorted() where key.hasPrefix("plan#") {
            for row in rows(units, key) where row.main == true {
                main.insert(row.id)
                if let slug = row.template, !mainLifts.contains(slug) { mainLifts.append(slug) }
            }
        }
        var hard: [String] = []
        for day in done.sorted() where day >= weekAgo {
            for row in rows(units, "log#\(day)") {
                guard let rpe = row.value("rpe"), rpe >= 9, let ref = row.plannedRef, main.contains(ref), let slug = row.template else { continue }
                let name = names[slug] ?? slug
                if !hard.contains(name) { hard.append(name) }
            }
        }
        if !hard.isEmpty { flags.append(Flag(kind: .hard, text: "RPE 9+ on \(hard.joined(separator: ", "))")) }

        let stalled = mainLifts.filter { plateaued(units, $0, today: today) }.map { names[$0] ?? $0 }
        if !stalled.isEmpty { flags.append(Flag(kind: .plateau, text: "No new best on \(stalled.joined(separator: ", ")) in 3 weeks")) }

        flags += behind(units, names: names, today: today).map { Flag(kind: .behind, text: $0) }

        if planned.contains(where: { $0 < today }), lastSession.map({ $0 < add(-14, to: today) }) ?? true {
            flags.append(Flag(kind: .quiet, text: lastSession == nil ? "Nothing logged yet" : "Nothing logged in over two weeks"))
        }

        return Week(done: done.filter(thisWeek).count, planned: planned.filter(thisWeek).count, lastSession: lastSession, flags: flags)
    }

    /// Clients who need the coach first: by their most pressing flag, then by how many.
    static func byNeed<T>(_ clients: [T], _ week: (T) -> Week) -> [T] {
        clients.enumerated().sorted { a, b in
            let (wa, wb) = (week(a.element), week(b.element))
            let (ra, rb) = (wa.need ?? Flag.Kind.allCases.count, wb.need ?? Flag.Kind.allCases.count)
            return ra != rb ? ra < rb : wa.flags.count != wb.flags.count ? wa.flags.count > wb.flags.count : a.offset < b.offset
        }.map(\.element)
    }
}
